import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../formula/ref_rewriter.dart';
import '../formula/tokenizer.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import 'xlsx_styles.dart';

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

final _escapedChar = RegExp(r'_x([0-9A-Fa-f]{4})_');

/// Decodes OOXML `_xHHHH_` escapes.
String decodeOoxmlEscapes(String s) {
  if (!s.contains('_x')) return s;
  return s.replaceAllMapped(_escapedChar, (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
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
  static Workbook read(Uint8List bytes, SpreadsheetFormat format) {
    final pkg = XlsxPackage.decode(bytes);
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
    final sst = _readSharedStrings(pkg.text(sstPath));

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

    final sheets = <SheetData>[];
    for (final ref in refs) {
      final xml = pkg.text(ref.path);
      final sheet = SheetData(
        name: ref.name,
        visibility: ref.state == 'hidden'
            ? SheetVisibility.hidden
            : ref.state == 'veryHidden'
                ? SheetVisibility.veryHidden
                : SheetVisibility.visible,
        sourcePath: ref.path,
        sourceIndex: ref.index,
        sourceName: ref.name,
      );
      if (xml != null) {
        _readSheet(xml, sheet, sst, styles.cellStyles, styles.defaultFontSize);
      }
      sheet.invalidateBounds();
      sheets.add(sheet);
    }
    // activeTab counts all sheets including chart sheets.
    var active = refs.indexWhere((r) => r.index == activeTab);
    if (active < 0) active = 0;
    if (sheets[active].visibility != SheetVisibility.visible) {
      final v = sheets.indexWhere((s) => s.visibility == SheetVisibility.visible);
      active = v < 0 ? 0 : v;
    }
    return Workbook(
      sheets: sheets,
      format: format,
      date1904: date1904,
      activeSheet: active,
      warnings: warnings,
    );
  }

  static List<String> _readSharedStrings(String? xml) {
    final out = <String>[];
    if (xml == null) return out;
    StringBuffer? cur;
    var inT = false;
    var phonetic = 0;
    for (final e in parseEvents(xml)) {
      if (e is XmlStartElementEvent) {
        final n = localName(e.name);
        if (n == 'si') {
          cur = StringBuffer();
          if (e.isSelfClosing) {
            out.add('');
            cur = null;
          }
        } else if (n == 'rPh') {
          if (!e.isSelfClosing) phonetic++;
        } else if (n == 't' && phonetic == 0 && !e.isSelfClosing) {
          inT = true;
        }
      } else if (e is XmlEndElementEvent) {
        final n = localName(e.name);
        if (n == 'si') {
          out.add(decodeOoxmlEscapes(cur?.toString() ?? ''));
          cur = null;
        } else if (n == 't') {
          inT = false;
        } else if (n == 'rPh') {
          phonetic--;
        }
      } else if (inT && cur != null) {
        if (e is XmlTextEvent) {
          cur.write(e.value);
        } else if (e is XmlCDATAEvent) {
          cur.write(e.value);
        }
      }
    }
    return out;
  }

  /// Column width in Excel character units -> pixels.
  static double widthToPx(double w) => (w * 7).roundToDouble().clamp(0, 2000).toDouble();

  static int _parseRow(String s) {
    var v = 0;
    for (var i = 0; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      if (u >= 48 && u <= 57) v = v * 10 + (u - 48);
    }
    return v - 1;
  }

  /// Parses `B12` quickly into (row, col).
  static (int, int)? _parseRef(String s) {
    var col = 0;
    var i = 0;
    while (i < s.length) {
      final u = s.codeUnitAt(i);
      if (u >= 65 && u <= 90) {
        col = col * 26 + (u - 64);
      } else if (u >= 97 && u <= 122) {
        col = col * 26 + (u - 96);
      } else if (u != 36) {
        break;
      }
      i++;
    }
    if (col == 0 || i >= s.length) return null;
    var row = 0;
    for (; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      if (u >= 48 && u <= 57) {
        row = row * 10 + (u - 48);
      } else if (u != 36) {
        return null;
      }
    }
    if (row == 0) return null;
    return (row - 1, col - 1);
  }

  static void _readSheet(String xml, SheetData sheet, List<String> sst,
      List<CellStyle> styles, double defaultFontSize) {
    var curRow = -1;
    var curCol = -1;
    // cell state
    var inCell = false;
    var cr = 0;
    var cc = 0;
    String? ct;
    var cs = 0;
    final vBuf = StringBuffer();
    final fBuf = StringBuffer();
    final isBuf = StringBuffer();
    var hasV = false;
    var hasF = false;
    String? fType;
    String? fRef;
    String? fSi;
    var inV = false;
    var inF = false;
    var inIs = false;
    var inT = false;
    var phonetic = 0;
    final shared = <String, (String, int, int)>{};
    double? defaultRowPt;

    void finishCell() {
      Object? value;
      final v = vBuf.toString();
      switch (ct) {
        case 's':
          final idx = int.tryParse(v.trim());
          value = idx != null && idx >= 0 && idx < sst.length ? sst[idx] : '';
        case 'str':
          value = hasV ? decodeOoxmlEscapes(v) : null;
        case 'inlineStr':
          value = decodeOoxmlEscapes(isBuf.toString());
        case 'b':
          value = v.trim() == '1' || v.trim() == 'true';
        case 'e':
          final t = v.trim();
          value = t.isEmpty ? null : (CellError.tryParse(t) ?? CellError(t));
        case 'd':
          final dt = DateTime.tryParse(v.trim());
          value = dt == null
              ? null
              : NumberFormats.dateTimeToSerial(DateTime.utc(dt.year, dt.month,
                  dt.day, dt.hour, dt.minute, dt.second, dt.millisecond));
        default:
          final t = v.trim();
          value = t.isEmpty ? null : double.tryParse(t);
      }
      String? formula;
      String? arrayRef;
      if (hasF && fType != 'dataTable') {
        final text = fBuf.toString();
        if (fType == 'shared' && fSi != null) {
          if (text.trim().isNotEmpty) {
            formula = stripFunctionPrefixes(text);
            shared[fSi] = (formula, cr, cc);
          } else {
            final master = shared[fSi];
            if (master != null) {
              formula = FormulaRefs.shift(master.$1, cr - master.$2, cc - master.$3);
            }
          }
        } else if (text.trim().isNotEmpty) {
          formula = stripFunctionPrefixes(text);
          if (fType == 'array') arrayRef = fRef;
        }
      }
      final style = cs >= 0 && cs < styles.length ? styles[cs] : styles.first;
      if (value == null && formula == null && cs == 0) return;
      if (value is double && value == 0) value = 0.0;
      sheet.cells[cellKey(cr, cc)] =
          Cell(value: value, formula: formula, style: style, arrayRef: arrayRef);
    }

    for (final e in parseEvents(xml)) {
      if (e is XmlStartElementEvent) {
        final name = localName(e.name);
        switch (name) {
          case 'c':
            String? r;
            ct = null;
            cs = 0;
            for (final a in e.attributes) {
              switch (a.localName) {
                case 'r':
                  r = a.value;
                case 't':
                  ct = a.value;
                case 's':
                  cs = int.tryParse(a.value) ?? 0;
              }
            }
            final p = r == null ? null : _parseRef(r);
            if (p != null) {
              cr = p.$1;
              cc = p.$2;
              if (curRow < 0) curRow = cr;
            } else {
              cr = curRow < 0 ? 0 : curRow;
              cc = curCol + 1;
            }
            curCol = cc;
            vBuf.clear();
            fBuf.clear();
            isBuf.clear();
            hasV = false;
            hasF = false;
            fType = null;
            fRef = null;
            fSi = null;
            if (cr >= kMaxRows || cc >= kMaxCols) {
              inCell = false;
              continue;
            }
            inCell = true;
            if (e.isSelfClosing) {
              finishCell();
              inCell = false;
            }
          case 'v':
            if (inCell) {
              hasV = true;
              inV = !e.isSelfClosing;
            }
          case 'f':
            if (inCell) {
              hasF = true;
              for (final a in e.attributes) {
                switch (a.localName) {
                  case 't':
                    fType = a.value;
                  case 'ref':
                    fRef = a.value;
                  case 'si':
                    fSi = a.value;
                }
              }
              inF = !e.isSelfClosing;
            }
          case 'is':
            if (inCell) inIs = !e.isSelfClosing;
          case 'rPh':
            if (!e.isSelfClosing) phonetic++;
          case 't':
            if (inIs && phonetic == 0 && !e.isSelfClosing) inT = true;
          case 'row':
            String? r;
            String? ht;
            var custom = false;
            var hidden = false;
            for (final a in e.attributes) {
              switch (a.localName) {
                case 'r':
                  r = a.value;
                case 'ht':
                  ht = a.value;
                case 'customHeight':
                  custom = _truthy(a.value);
                case 'hidden':
                  hidden = _truthy(a.value);
              }
            }
            curRow = r == null ? curRow + 1 : _parseRow(r);
            curCol = -1;
            if (curRow >= 0 && curRow < kMaxRows) {
              final h = double.tryParse(ht ?? '');
              if (h != null && (custom || defaultRowPt == null || (h - defaultRowPt).abs() > 0.01)) {
                sheet.rowHeights[curRow] = (h * 4 / 3).roundToDouble();
              }
              if (hidden) sheet.hiddenRows.add(curRow);
            }
          case 'col':
            int? min;
            int? max;
            double? w;
            var hidden = false;
            for (final a in e.attributes) {
              switch (a.localName) {
                case 'min':
                  min = int.tryParse(a.value);
                case 'max':
                  max = int.tryParse(a.value);
                case 'width':
                  w = double.tryParse(a.value);
                case 'hidden':
                  hidden = _truthy(a.value);
              }
            }
            if (min != null && max != null && min >= 1) {
              final px = w == null ? null : widthToPx(w);
              final last = max > 2048 ? 2048 : max;
              for (var c = min - 1; c < last && c < kMaxCols; c++) {
                if (px != null) sheet.colWidths[c] = px;
                if (hidden) sheet.hiddenCols.add(c);
              }
              if (max >= kMaxCols && px != null && !hidden) sheet.defaultColWidth = px;
            }
          case 'sheetFormatPr':
            final dh = double.tryParse(e.attributes
                    .where((a) => a.localName == 'defaultRowHeight')
                    .map((a) => a.value)
                    .firstOrNull ??
                '');
            if (dh != null && dh > 0) {
              defaultRowPt = dh;
              sheet.defaultRowHeight = (dh * 4 / 3).roundToDouble();
            }
            final dw = double.tryParse(e.attributes
                    .where((a) => a.localName == 'defaultColWidth')
                    .map((a) => a.value)
                    .firstOrNull ??
                '');
            if (dw != null && dw > 0) {
              sheet.defaultColWidth = widthToPx(dw);
            } else {
              final base = double.tryParse(e.attributes
                      .where((a) => a.localName == 'baseColWidth')
                      .map((a) => a.value)
                      .firstOrNull ??
                  '');
              if (base != null && base > 0) sheet.defaultColWidth = widthToPx(base + 1.14);
            }
          case 'pane':
            String? state;
            double? xs;
            double? ys;
            for (final a in e.attributes) {
              switch (a.localName) {
                case 'state':
                  state = a.value;
                case 'xSplit':
                  xs = double.tryParse(a.value);
                case 'ySplit':
                  ys = double.tryParse(a.value);
              }
            }
            if (state == 'frozen' || state == 'frozenSplit') {
              sheet.frozenCols = (xs ?? 0).round().clamp(0, 1000);
              sheet.frozenRows = (ys ?? 0).round().clamp(0, 10000);
            }
          case 'mergeCell':
            for (final a in e.attributes) {
              if (a.localName == 'ref') {
                final range = CellRange.parse(a.value);
                if (range != null && !range.isSingle) sheet.merges.add(range);
              }
            }
        }
      } else if (e is XmlEndElementEvent) {
        switch (localName(e.name)) {
          case 'c':
            if (inCell) finishCell();
            inCell = false;
            inV = false;
            inF = false;
            inIs = false;
          case 'v':
            inV = false;
          case 'f':
            inF = false;
          case 'is':
            inIs = false;
          case 't':
            inT = false;
          case 'rPh':
            phonetic--;
          case 'row':
            curCol = -1;
        }
      } else if (inV || inF || inT) {
        String? text;
        if (e is XmlTextEvent) {
          text = e.value;
        } else if (e is XmlCDATAEvent) {
          text = e.value;
        }
        if (text != null) {
          if (inV) vBuf.write(text);
          if (inF) fBuf.write(text);
          if (inT) isBuf.write(text);
        }
      }
    }
  }
}
