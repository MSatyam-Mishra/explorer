import 'dart:convert';
import 'dart:io' show RawZLibFilter;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/workbook.dart';
import 'xlsx_sheet_scanner.dart';
import 'xlsx_styles.dart';

export 'xlsx_sheet_scanner.dart' show decodeOoxmlEscapes;

/// Friendly error for files we can't open.
class SpreadsheetReadException implements Exception {
  SpreadsheetReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Case-insensitive view over a zip package.
class XlsxPackage {
  XlsxPackage(this.archive) {
    for (final f in archive.files) {
      if (f.isFile) _byLower[f.name.toLowerCase()] = f;
    }
  }

  factory XlsxPackage.decode(Uint8List bytes) {
    try {
      return XlsxPackage(ZipDecoder().decodeBytes(bytes));
    } catch (_) {
      throw SpreadsheetReadException('This file is damaged or isn\'t a valid workbook.');
    }
  }

  final Archive archive;
  final Map<String, ArchiveFile> _byLower = {};

  ArchiveFile? file(String path) => _byLower[_normalize(path).toLowerCase()];

  bool has(String path) => file(path) != null;

  Uint8List? bytes(String path) {
    final f = file(path);
    if (f == null) return null;
    final c = f.content;
    if (c is Uint8List) return c;
    if (c is List<int>) return Uint8List.fromList(c);
    return null;
  }

  /// At least the first [maxBytes] bytes of [path] (all of it when it's
  /// shorter), inflating only what's needed; the flag tells whether the
  /// whole part was read.
  (Uint8List, bool)? prefixBytes(String path, int maxBytes) {
    final f = file(path);
    if (f == null) return null;
    final raw = f.isCompressed && f.compressionType == ArchiveFile.DEFLATE ? f.rawContent?.toUint8List() : null;
    if (raw == null) {
      final all = bytes(path);
      return all == null ? null : (all, true);
    }
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final out = BytesBuilder(copy: false);
    var pos = 0;
    while (pos < raw.length && out.length < maxBytes) {
      final end = math.min(pos + 65536, raw.length);
      filter.process(raw, pos, end);
      pos = end;
      for (var chunk = filter.processed(flush: false); chunk != null; chunk = filter.processed(flush: false)) {
        out.add(chunk);
      }
    }
    final complete = pos >= raw.length;
    if (complete) {
      for (var chunk = filter.processed(end: true); chunk != null; chunk = filter.processed(end: true)) {
        out.add(chunk);
      }
    }
    return (out.takeBytes(), complete);
  }

  String? text(String path) {
    final b = bytes(path);
    if (b == null) return null;
    var s = utf8.decode(b, allowMalformed: true);
    if (s.startsWith('﻿')) s = s.substring(1);
    return s;
  }

  static String _normalize(String p) {
    var s = p.replaceAll('\\', '/');
    if (s.startsWith('/')) s = s.substring(1);
    return s;
  }

  /// Resolves a relationship target relative to the part [from].
  static String resolve(String from, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final dir = from.contains('/') ? from.substring(0, from.lastIndexOf('/')) : '';
    final parts = <String>[if (dir.isNotEmpty) ...dir.split('/')];
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.' && seg.isNotEmpty) {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static String relsPathFor(String part) {
    final i = part.lastIndexOf('/');
    final dir = i < 0 ? '' : part.substring(0, i + 1);
    final name = i < 0 ? part : part.substring(i + 1);
    return '${dir}_rels/$name.rels';
  }

  /// Relationships of [part]: id -> (type, target path resolved).
  Map<String, (String, String)> rels(String part) {
    final xml = text(relsPathFor(part));
    final out = <String, (String, String)>{};
    if (xml == null) return out;
    try {
      final doc = XmlDocument.parse(xml);
      for (final r in doc.rootElement.childElements) {
        if (r.name.local != 'Relationship') continue;
        final id = r.getAttribute('Id');
        final type = r.getAttribute('Type') ?? '';
        final target = r.getAttribute('Target');
        if (id == null || target == null) continue;
        if (r.getAttribute('TargetMode') == 'External') continue;
        out[id] = (type, resolve(part, target));
      }
    } catch (_) {}
    return out;
  }

  /// Path of the main workbook part.
  String workbookPath() {
    final root = rels('');
    for (final r in root.values) {
      if (r.$1.endsWith('/officeDocument')) return r.$2;
    }
    return 'xl/workbook.xml';
  }
}

bool _truthy(String? v) => v == '1' || v == 'true';

class _SheetRef {
  _SheetRef(this.name, this.path, this.state, this.index);
  final String name;
  final String path;
  final String? state;
  final int index;
}

/// Reads .xlsx / .xlsm / .xltx / .xltm packages.
abstract final class XlsxReader {
  /// Reads a workbook; pass [package] when the zip was already decoded.
  static Workbook read(Uint8List bytes, SpreadsheetFormat format, {XlsxPackage? package}) =>
      _read(package ?? XlsxPackage.decode(bytes), format, previewRows: null);

  /// A quick look at the active sheet: only its first [rows] rows are read
  /// (other sheets are empty placeholders). For showing something while
  /// [read] runs; never edit or save it.
  static Workbook readPreview(Uint8List bytes, SpreadsheetFormat format,
          {XlsxPackage? package, int rows = 300}) =>
      _read(package ?? XlsxPackage.decode(bytes), format, previewRows: rows);

  static Workbook _read(XlsxPackage pkg, SpreadsheetFormat format, {required int? previewRows}) {
    if (pkg.has('EncryptedPackage') || pkg.has('EncryptionInfo')) {
      throw SpreadsheetReadException('This workbook is password-protected and can\'t be opened here.');
    }
    final wbPath = pkg.workbookPath();
    final wbXml = pkg.text(wbPath);
    if (wbXml == null) {
      throw SpreadsheetReadException('This file doesn\'t contain a workbook.');
    }
    final wbDoc = XmlDocument.parse(wbXml);
    final wbRoot = wbDoc.rootElement;
    final rels = pkg.rels(wbPath);

    final wbPr = firstChild(wbRoot, 'workbookPr');
    final date1904 = _truthy(wbPr?.getAttribute('date1904'));
    var activeTab = 0;
    final views = firstChild(wbRoot, 'bookViews');
    final view = views == null ? null : firstChild(views, 'workbookView');
    activeTab = int.tryParse(view?.getAttribute('activeTab') ?? '0') ?? 0;

    String? stylesPath;
    String? sstPath;
    String? themePath;
    for (final r in rels.values) {
      if (r.$1.endsWith('/styles')) stylesPath = r.$2;
      if (r.$1.endsWith('/sharedStrings')) sstPath = r.$2;
      if (r.$1.endsWith('/theme')) themePath = r.$2;
    }
    stylesPath ??= 'xl/styles.xml';
    sstPath ??= 'xl/sharedStrings.xml';

    final theme = parseThemeColors(themePath == null ? null : pkg.text(themePath));
    final styles = XlsxStyles.parse(pkg.text(stylesPath), theme);
    // Strings are numbered in order of first use, so the first rows of a
    // sheet rarely need more than the first few thousand.
    final sst = scanSharedStrings(pkg.bytes(sstPath), limit: previewRows == null ? null : 50000);

    final warnings = <String>[];
    final refs = <_SheetRef>[];
    final sheetsEl = firstChild(wbRoot, 'sheets');
    var index = 0;
    if (sheetsEl != null) {
      for (final s in childElements(sheetsEl, 'sheet')) {
        final name = s.getAttribute('name') ?? 'Sheet${index + 1}';
        String? rid;
        for (final a in s.attributes) {
          if (a.name.local == 'id') rid = a.value;
        }
        final rel = rid == null ? null : rels[rid];
        final i = index++;
        if (rel == null) continue;
        if (!rel.$1.endsWith('/worksheet')) {
          warnings.add('"$name" is a chart or macro sheet and isn\'t shown.');
          continue;
        }
        refs.add(_SheetRef(name, rel.$2, s.getAttribute('state'), i));
      }
    }
    if (refs.isEmpty) throw SpreadsheetReadException('This workbook has no worksheets.');

    SheetVisibility visibility(_SheetRef r) => r.state == 'hidden'
        ? SheetVisibility.hidden
        : r.state == 'veryHidden'
            ? SheetVisibility.veryHidden
            : SheetVisibility.visible;
    // activeTab counts all sheets including chart sheets.
    var active = refs.indexWhere((r) => r.index == activeTab);
    if (active < 0) active = 0;
    if (visibility(refs[active]) != SheetVisibility.visible) {
      final v = refs.indexWhere((r) => visibility(r) == SheetVisibility.visible);
      active = v < 0 ? 0 : v;
    }

    final sheets = <SheetData>[];
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      final sheet = SheetData(
        name: ref.name,
        visibility: visibility(ref),
        sourcePath: ref.path,
        sourceIndex: ref.index,
        sourceName: ref.name,
      );
      if (previewRows == null) {
        final xml = pkg.bytes(ref.path);
        if (xml != null) scanWorksheet(xml, sheet, sst, styles.cellStyles);
      } else if (i == active) {
        _scanPreview(pkg, ref.path, sheet, sst, styles.cellStyles, previewRows);
      }
      sheet.invalidateBounds();
      sheets.add(sheet);
    }
    return Workbook(
      sheets: sheets,
      format: format,
      date1904: date1904,
      activeSheet: active,
      warnings: warnings,
    );
  }

  /// Inflates just enough of a worksheet for its first [rows] rows.
  static void _scanPreview(XlsxPackage pkg, String path, SheetData sheet, List<String> sst,
      List<CellStyle> styles, int rows) {
    var budget = 256 * 1024;
    while (true) {
      final part = pkg.prefixBytes(path, budget);
      if (part == null) return;
      final (bytes, complete) = part;
      final probe = sheet.clone();
      final stopped = scanWorksheet(complete ? bytes : _upToLastRowEnd(bytes), probe, sst, styles,
          maxRows: rows);
      if (stopped || complete || budget >= 32 * 1024 * 1024) {
        sheet.restoreFrom(probe);
        return;
      }
      budget *= 4;
    }
  }

  /// Cuts a truncated worksheet prefix after its last complete `</row>`.
  static Uint8List _upToLastRowEnd(Uint8List b) {
    for (var i = b.length - 4; i > 0; i--) {
      // "row>" preceded by "/" (</row>) or ":" (</x:row>)
      if (b[i] == 0x72 && b[i + 1] == 0x6F && b[i + 2] == 0x77 && b[i + 3] == 0x3E &&
          (b[i - 1] == 0x2F || b[i - 1] == 0x3A)) {
        return Uint8List.sublistView(b, 0, i + 4);
      }
    }
    return Uint8List(0);
  }

  /// Column width in Excel character units -> pixels.
  static double widthToPx(double w) => xlsxWidthToPx(w);
}
