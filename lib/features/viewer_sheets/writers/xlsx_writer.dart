import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../formula/ref_rewriter.dart';
import '../formula/tokenizer.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import '../readers/csv_codec.dart';
import '../readers/xlsx_reader.dart';
import '../readers/xlsx_styles.dart';

const _nsMain = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _nsRel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsPkgRel = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _nsCt = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _relWorksheet = '$_nsRel/worksheet';
const _relStyles = '$_nsRel/styles';
const _relSst = '$_nsRel/sharedStrings';
const _ctWorksheet = 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml';
const _ctSst = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml';
const _ctStyles = 'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml';

String _workbookContentType(SpreadsheetFormat f) => switch (f) {
      SpreadsheetFormat.xlsm => 'application/vnd.ms-excel.sheet.macroEnabled.main+xml',
      SpreadsheetFormat.xltx =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.template.main+xml',
      SpreadsheetFormat.xltm => 'application/vnd.ms-excel.template.macroEnabled.main+xml',
      _ => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml',
    };

const _templateStyles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<styleSheet xmlns="$_nsMain">'
    '<fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/>'
    '<family val="2"/><scheme val="minor"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '<dxfs count="0"/>'
    '<tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>'
    '</styleSheet>';

final Map<String, String> _templateParts = {
  '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Types xmlns="$_nsCt">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="${_workbookContentType(SpreadsheetFormat.xlsx)}"/>'
      '<Override PartName="/xl/styles.xml" ContentType="$_ctStyles"/>'
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
      '</Types>',
  '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="$_nsPkgRel">'
      '<Relationship Id="rId1" Type="$_nsRel/officeDocument" Target="xl/workbook.xml"/>'
      '<Relationship Id="rId2" Type="$_nsRel/extended-properties" Target="docProps/app.xml"/>'
      '</Relationships>',
  'docProps/app.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Microsoft Excel</Application></Properties>',
  'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<workbook xmlns="$_nsMain" xmlns:r="$_nsRel">'
      '<workbookPr/><bookViews><workbookView/></bookViews><sheets/><calcPr calcId="191029"/>'
      '</workbook>',
  'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="$_nsPkgRel">'
      '<Relationship Id="rId1" Type="$_relStyles" Target="styles.xml"/>'
      '</Relationships>',
  'xl/styles.xml': _templateStyles,
};

final _needsEscape = RegExp(r'[&<>"\x00-\x08\x0B\x0C\x0E-\x1F]');

String _esc(String s) {
  if (!_needsEscape.hasMatch(s)) return s;
  final b = StringBuffer();
  for (final u in s.codeUnits) {
    switch (u) {
      case 0x26:
        b.write('&amp;');
      case 0x3C:
        b.write('&lt;');
      case 0x3E:
        b.write('&gt;');
      case 0x22:
        b.write('&quot;');
      default:
        if (u < 0x20 && u != 0x09 && u != 0x0A && u != 0x0D) {
          b.write('_x${u.toRadixString(16).padLeft(4, '0').toUpperCase()}_');
        } else {
          b.writeCharCode(u);
        }
    }
  }
  return b.toString();
}

String _num(double v) {
  if (v == v.truncateToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return v.toString();
}

/// Builds `cellXfs` entries for [CellStyle]s on top of an existing styles
/// part, so borders, fonts and other untracked attributes survive.
class _StyleTable {
  _StyleTable(String xml, List<int> theme) {
    doc = XmlDocument.parse(xml);
    root = doc.rootElement;
    prefix = root.name.prefix;
    final parsed = XlsxStyles.parse(xml, theme);
    original = parsed.cellStyles;
    defaultFontSize = parsed.defaultFontSize;
    fontsEl = _ensure('fonts', before: const ['fills', 'borders', 'cellStyleXfs', 'cellXfs']);
    fillsEl = _ensure('fills', before: const ['borders', 'cellStyleXfs', 'cellXfs']);
    xfsEl = _ensure('cellXfs', before: const ['cellStyles', 'dxfs', 'tableStyles', 'colors', 'extLst']);
    fonts = childElements(fontsEl, 'font').toList();
    fills = childElements(fillsEl, 'fill').toList();
    xfs = childElements(xfsEl, 'xf').toList();
    if (fonts.isEmpty) {
      final f = _el('font')..children.add(_el('sz')..setAttribute('val', '11'));
      fontsEl.children.add(f);
      fonts.add(f);
    }
    while (fills.length < 2) {
      final f = _el('fill')
        ..children.add(_el('patternFill')
          ..setAttribute('patternType', fills.isEmpty ? 'none' : 'gray125'));
      fillsEl.children.add(f);
      fills.add(f);
    }
    if (xfs.isEmpty) {
      final x = _el('xf')
        ..setAttribute('numFmtId', '0')
        ..setAttribute('fontId', '0')
        ..setAttribute('fillId', '0')
        ..setAttribute('borderId', '0');
      xfsEl.children.add(x);
      xfs.add(x);
      original = [const CellStyle(baseXf: 0)];
    }
    final nf = firstChild(root, 'numFmts');
    if (nf != null) {
      for (final f in childElements(nf, 'numFmt')) {
        final id = int.tryParse(f.getAttribute('numFmtId') ?? '');
        final code = f.getAttribute('formatCode');
        if (id != null && code != null) {
          _customFmt.putIfAbsent(code, () => id);
          if (id > _maxFmtId) _maxFmtId = id;
        }
      }
    }
    for (var i = 0; i < fonts.length; i++) {
      _fontIndex.putIfAbsent(fonts[i].toXmlString(), () => i);
    }
  }

  late final XmlDocument doc;
  late final XmlElement root;
  late final String? prefix;
  late List<CellStyle> original;
  late final double defaultFontSize;
  late final XmlElement fontsEl;
  late final XmlElement fillsEl;
  late final XmlElement xfsEl;
  late final List<XmlElement> fonts;
  late final List<XmlElement> fills;
  late final List<XmlElement> xfs;
  final _customFmt = <String, int>{};
  var _maxFmtId = 163;
  final _fontIndex = <String, int>{};
  final _fillIndex = <int, int>{};
  final _cache = <CellStyle, int>{};

  XmlElement _el(String local) => XmlElement(XmlName(local, prefix));

  XmlElement _ensure(String local, {required List<String> before}) {
    final existing = firstChild(root, local);
    if (existing != null) return existing;
    final el = _el(local)..setAttribute('count', '0');
    final idx = root.children.indexWhere(
        (n) => n is XmlElement && before.contains(n.name.local));
    if (idx < 0) {
      root.children.add(el);
    } else {
      root.children.insert(idx, el);
    }
    return el;
  }

  int indexOf(CellStyle s) {
    final cached = _cache[s];
    if (cached != null) return cached;
    int idx;
    final base = s.baseXf;
    if (base != null && base < original.length && original[base].sameLook(s)) {
      idx = base;
    } else if (base == null && original.isNotEmpty && original[0].sameLook(s)) {
      idx = 0;
    } else {
      idx = _create(s);
    }
    _cache[s] = idx;
    return idx;
  }

  int _create(CellStyle s) {
    final baseIdx = s.baseXf != null && s.baseXf! < xfs.length ? s.baseXf! : 0;
    final b = original[baseIdx < original.length ? baseIdx : 0];
    final xf = xfs[baseIdx].copy();

    final fontChanged = s.bold != b.bold ||
        s.italic != b.italic ||
        s.underline != b.underline ||
        s.strike != b.strike ||
        s.fontColor != b.fontColor ||
        s.fontSize != b.fontSize;
    if (fontChanged) {
      final baseFontId = int.tryParse(xf.getAttribute('fontId') ?? '0') ?? 0;
      final font = (baseFontId < fonts.length ? fonts[baseFontId] : fonts[0]).copy();
      void flag(String name, bool on) {
        font.children.removeWhere((n) => n is XmlElement && n.name.local == name);
        if (on) {
          final el = _el(name);
          if (name == 'u') el.setAttribute('val', 'single');
          font.children.insert(0, el);
        }
      }

      flag('strike', s.strike);
      flag('u', s.underline);
      flag('i', s.italic);
      flag('b', s.bold);
      if (s.fontColor != b.fontColor) {
        font.children.removeWhere((n) => n is XmlElement && n.name.local == 'color');
        final c = _el('color');
        if (s.fontColor == null) {
          c.setAttribute('theme', '1');
        } else {
          c.setAttribute('rgb', _argb(s.fontColor!));
        }
        font.children.add(c);
      }
      if (s.fontSize != b.fontSize) {
        font.children.removeWhere((n) => n is XmlElement && n.name.local == 'sz');
        font.children.add(_el('sz')..setAttribute('val', _num(s.fontSize ?? defaultFontSize)));
      }
      final key = font.toXmlString();
      var id = _fontIndex[key];
      if (id == null) {
        fontsEl.children.add(font);
        fonts.add(font);
        id = fonts.length - 1;
        _fontIndex[key] = id;
      }
      xf.setAttribute('fontId', '$id');
      xf.setAttribute('applyFont', '1');
    }
    if (s.fillColor != b.fillColor) {
      int id;
      if (s.fillColor == null) {
        id = 0;
      } else {
        final existing = _fillIndex[s.fillColor!];
        if (existing != null) {
          id = existing;
        } else {
          final fill = _el('fill')
            ..children.add(_el('patternFill')
              ..setAttribute('patternType', 'solid')
              ..children.add(_el('fgColor')..setAttribute('rgb', _argb(s.fillColor!)))
              ..children.add(_el('bgColor')..setAttribute('indexed', '64')));
          fillsEl.children.add(fill);
          fills.add(fill);
          id = fills.length - 1;
          _fillIndex[s.fillColor!] = id;
        }
      }
      xf.setAttribute('fillId', '$id');
      xf.setAttribute('applyFill', '1');
    }
    if (s.numFmt != b.numFmt) {
      xf.setAttribute('numFmtId', '${_numFmtId(s.numFmt)}');
      xf.setAttribute('applyNumberFormat', '1');
    }
    if (s.hAlign != b.hAlign || s.vAlign != b.vAlign || s.wrap != b.wrap) {
      var align = firstChild(xf, 'alignment');
      if (align == null) {
        align = _el('alignment');
        xf.children.insert(0, align);
      }
      align.setAttribute('horizontal', s.hAlign == HAlign.general ? null : hAlignName(s.hAlign));
      align.setAttribute('vertical', s.vAlign == VAlign.bottom ? null : vAlignName(s.vAlign));
      align.setAttribute('wrapText', s.wrap ? '1' : null);
      xf.setAttribute('applyAlignment', '1');
    }
    xfsEl.children.add(xf);
    xfs.add(xf);
    original = [...original, s.copyWith(baseXf: xfs.length - 1)];
    return xfs.length - 1;
  }

  static String _argb(int c) => (c | 0xFF000000).toRadixString(16).toUpperCase().padLeft(8, '0');

  int _numFmtId(String code) {
    final builtin = NumberFormats.builtinIdForCode(code);
    if (builtin != null) return builtin;
    final custom = _customFmt[code];
    if (custom != null) return custom;
    final id = ++_maxFmtId;
    _customFmt[code] = id;
    var nf = firstChild(root, 'numFmts');
    if (nf == null) {
      nf = _el('numFmts');
      root.children.insert(root.children.indexWhere((n) => n is XmlElement), nf);
    }
    nf.children.add(_el('numFmt')
      ..setAttribute('numFmtId', '$id')
      ..setAttribute('formatCode', code));
    return id;
  }

  String finish() {
    fontsEl.setAttribute('count', '${fonts.length}');
    fillsEl.setAttribute('count', '${fills.length}');
    xfsEl.setAttribute('count', '${xfs.length}');
    final nf = firstChild(root, 'numFmts');
    if (nf != null) {
      final n = childElements(nf, 'numFmt').length;
      if (n == 0) {
        root.children.remove(nf);
      } else {
        nf.setAttribute('count', '$n');
      }
    }
    return doc.toXmlString();
  }
}

class _SharedStrings {
  final _index = <String, int>{};
  final _list = <String>[];
  var count = 0;

  int add(String s) {
    count++;
    final i = _index[s];
    if (i != null) return i;
    _list.add(s);
    return _index[s] = _list.length - 1;
  }

  String build() {
    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n')
      ..write('<sst xmlns="$_nsMain" count="$count" uniqueCount="${_list.length}">');
    for (final s in _list) {
      final preserve = s.isNotEmpty &&
          (s.startsWith(' ') || s.endsWith(' ') || s.contains('\n') || s.contains('\t'));
      b.write(preserve ? '<si><t xml:space="preserve">' : '<si><t>');
      b.write(_esc(s));
      b.write('</t></si>');
    }
    b.write('</sst>');
    return b.toString();
  }
}

/// Raw XML pieces of an original worksheet that this app doesn't model.
class _SheetExtras {
  final rootAttrs = <(String, String)>[];
  final top = <String, String>{}; // first occurrence per element name
  final ordered = <(String, String)>[];
  final sheetViewAttrs = <(String, String)>[];
}

_SheetExtras _extractExtras(String xml) {
  final ex = _SheetExtras();
  var depth = 0;
  String? capturing;
  var capStart = 0;
  var inSheetViews = false;
  for (final e in parseEvents(xml, withLocation: true)) {
    if (e is XmlStartElementEvent) {
      final name = localName(e.name);
      if (depth == 0) {
        for (final a in e.attributes) {
          ex.rootAttrs.add((a.name, a.value));
        }
      } else if (depth == 1) {
        if (name == 'sheetViews') inSheetViews = true;
        if (e.isSelfClosing) {
          final raw = xml.substring(e.start!, e.stop!);
          ex.ordered.add((name, raw));
          ex.top.putIfAbsent(name, () => raw);
        } else {
          capturing = name;
          capStart = e.start!;
        }
      } else if (depth == 2 && inSheetViews && name == 'sheetView' && ex.sheetViewAttrs.isEmpty) {
        for (final a in e.attributes) {
          ex.sheetViewAttrs.add((a.name, a.value));
        }
      }
      if (!e.isSelfClosing) depth++;
    } else if (e is XmlEndElementEvent) {
      depth--;
      if (depth == 1 && capturing != null) {
        final raw = xml.substring(capStart, e.stop!);
        ex.ordered.add((capturing, raw));
        ex.top.putIfAbsent(capturing, () => raw);
        if (capturing == 'sheetViews') inSheetViews = false;
        capturing = null;
      }
    }
  }
  return ex;
}

const _preMergeKeep = [
  'sheetCalcPr', 'sheetProtection', 'protectedRanges', 'scenarios', 'autoFilter', //
  'sortState', 'dataConsolidate', 'customSheetViews',
];
const _postMergeKeep = [
  'phoneticPr', 'conditionalFormatting', 'dataValidations', 'hyperlinks', //
  'printOptions', 'pageMargins', 'pageSetup', 'headerFooter', 'rowBreaks',
  'colBreaks', 'customProperties', 'cellWatches', 'ignoredErrors', 'smartTags',
  'drawing', 'legacyDrawing', 'legacyDrawingHF', 'drawingHF', 'picture',
  'oleObjects', 'controls', 'webPublishItems', 'tableParts', 'extLst',
];
const _structureSafe = {
  'sheetProtection', 'printOptions', 'pageMargins', 'pageSetup', 'headerFooter', //
  'drawing', 'legacyDrawing', 'legacyDrawingHF', 'drawingHF', 'picture',
};

/// Output of [XlsxWriter.writePackage].
class XlsxWriteResult {
  const XlsxWriteResult(this.bytes, this.sheetPaths);
  final Uint8List bytes;

  /// Worksheet part path used for each sheet, in workbook order.
  final List<String> sheetPaths;
}

/// Writes .xlsx packages. When [original] package bytes are given, every
/// part this app doesn't understand (themes, drawings, VBA, pivot caches...)
/// is copied over unchanged.
abstract final class XlsxWriter {
  static Uint8List write(Workbook wb, {Uint8List? original, SpreadsheetFormat? target}) =>
      writePackage(wb, original: original, target: target).bytes;

  static XlsxWriteResult writePackage(Workbook wb, {Uint8List? original, SpreadsheetFormat? target}) {
    final fmt = target ?? (wb.format.isXlsxFamily ? wb.format : SpreadsheetFormat.xlsx);
    XlsxPackage? orig;
    if (original != null) {
      try {
        orig = XlsxPackage.decode(original);
        final wbXml = orig.text(orig.workbookPath()) ?? '';
        if (wbXml.contains('purl.oclc.org/ooxml')) orig = null; // strict
        if (wbXml.isEmpty) orig = null;
      } catch (_) {
        orig = null;
      }
    }
    final fromTemplate = orig == null;
    final parts = <String, Uint8List>{};
    final keepOrder = <String>[];
    if (orig != null) {
      for (final f in orig.archive.files) {
        if (f.isFile) keepOrder.add(f.name);
      }
    }
    String? partText(String path) {
      if (orig != null) return orig.text(path);
      return _templateParts[path];
    }

    final wbPath = orig?.workbookPath() ?? 'xl/workbook.xml';
    final wbRelsPath = XlsxPackage.relsPathFor(wbPath);
    final wbDoc = XmlDocument.parse(partText(wbPath)!);
    final relsDoc = XmlDocument.parse(partText(wbRelsPath) ??
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="$_nsPkgRel"/>');
    final ctDoc = XmlDocument.parse(partText('[Content_Types].xml')!);
    final wbRoot = wbDoc.rootElement;
    final relsRoot = relsDoc.rootElement;
    final ctRoot = ctDoc.rootElement;
    final mainPrefix = wbRoot.name.prefix;
    XmlElement el(String local) => XmlElement(XmlName(local, mainPrefix));

    // Relationship-namespace prefix used for r:id.
    var relPrefix = 'r';
    var foundRel = false;
    for (final a in wbRoot.attributes) {
      if (a.name.prefix == 'xmlns' && a.value == _nsRel) {
        relPrefix = a.name.local;
        foundRel = true;
      }
    }
    if (!foundRel) wbRoot.setAttribute('xmlns:r', _nsRel);

    // Existing relationships.
    final rels = <String, (String, String, XmlElement)>{};
    for (final r in relsRoot.childElements) {
      final id = r.getAttribute('Id');
      if (id == null) continue;
      final type = r.getAttribute('Type') ?? '';
      final target = r.getAttribute('Target') ?? '';
      final external = r.getAttribute('TargetMode') == 'External';
      rels[id] = (type, external ? target : XlsxPackage.resolve(wbPath, target), r);
    }
    var relSeq = 1;
    String newRelId() {
      while (rels.containsKey('rId$relSeq')) {
        relSeq++;
      }
      return 'rId${relSeq++}';
    }

    // Original <sheet> entries.
    final sheetsEl = firstChild(wbRoot, 'sheets') ?? (el('sheets'));
    if (sheetsEl.parent == null) wbRoot.children.add(sheetsEl);
    final origSheetEls = childElements(sheetsEl, 'sheet').toList();
    String? ridOf(XmlElement s) {
      for (final a in s.attributes) {
        if (a.name.local == 'id' && a.name.prefix != null) return a.value;
      }
      return null;
    }

    var maxSheetId = 0;
    final pathToEl = <String, XmlElement>{};
    final nonWorksheetEls = <XmlElement>[];
    for (final s in origSheetEls) {
      final id = int.tryParse(s.getAttribute('sheetId') ?? '') ?? 0;
      if (id > maxSheetId) maxSheetId = id;
      final rid = ridOf(s);
      final rel = rid == null ? null : rels[rid];
      if (rel != null && rel.$1.endsWith('/worksheet')) {
        pathToEl[rel.$2.toLowerCase()] = s;
      } else {
        nonWorksheetEls.add(s);
      }
    }

    // Plan output sheets.
    final usedPaths = <String>{};
    final plans = <(SheetData, String path, String rid, int sheetId, bool reused)>[];
    var sheetNo = 1;
    String newSheetPath() {
      while (true) {
        final p = 'xl/worksheets/sheet${sheetNo++}.xml';
        if (orig?.has(p) == true || usedPaths.contains(p.toLowerCase())) continue;
        return p;
      }
    }

    for (final s in wb.sheets) {
      final src = s.sourcePath;
      final existing = src == null || fromTemplate ? null : pathToEl[src.toLowerCase()];
      if (existing != null && !usedPaths.contains(src!.toLowerCase())) {
        usedPaths.add(src.toLowerCase());
        plans.add((
          s,
          src,
          ridOf(existing)!,
          int.tryParse(existing.getAttribute('sheetId') ?? '') ?? ++maxSheetId,
          true,
        ));
      } else {
        final p = newSheetPath();
        usedPaths.add(p.toLowerCase());
        final rid = newRelId();
        rels[rid] = (_relWorksheet, p, XmlElement(XmlName('Relationship')));
        relsRoot.children.add(XmlElement(XmlName('Relationship'), [
          XmlAttribute(XmlName('Id'), rid),
          XmlAttribute(XmlName('Type'), _relWorksheet),
          XmlAttribute(XmlName('Target'), _relTarget(wbPath, p)),
        ]));
        plans.add((s, p, rid, ++maxSheetId, false));
      }
    }

    // Deleted original worksheets.
    final removedParts = <String>{};
    for (final entry in pathToEl.entries) {
      if (usedPaths.contains(entry.key)) continue;
      final rid = ridOf(entry.value);
      if (rid != null) {
        rels[rid]?.$3.parent?.children.remove(rels[rid]!.$3);
        rels.remove(rid);
      }
      removedParts.add(entry.key);
      removedParts.add(XlsxPackage.relsPathFor(entry.key).toLowerCase());
    }

    // Shared strings / styles / calcChain / VBA relationships.
    String? sstPath;
    String? stylesPath;
    String? themePath;
    for (final entry in rels.entries.toList()) {
      final type = entry.value.$1;
      final path = entry.value.$2;
      if (type.endsWith('/sharedStrings')) sstPath = path;
      if (type.endsWith('/styles')) stylesPath = path;
      if (type.endsWith('/theme')) themePath = path;
      if (type.endsWith('/calcChain')) {
        entry.value.$3.parent?.children.remove(entry.value.$3);
        rels.remove(entry.key);
        removedParts.add(path.toLowerCase());
      }
      if (type.endsWith('/vbaProject') && !fmt.isMacroEnabled) {
        entry.value.$3.parent?.children.remove(entry.value.$3);
        rels.remove(entry.key);
        removedParts.add(path.toLowerCase());
        removedParts.add(XlsxPackage.relsPathFor(path).toLowerCase());
      }
    }
    if (sstPath == null) {
      sstPath = XlsxPackage.resolve(wbPath, 'sharedStrings.xml');
      relsRoot.children.add(XmlElement(XmlName('Relationship'), [
        XmlAttribute(XmlName('Id'), newRelId()),
        XmlAttribute(XmlName('Type'), _relSst),
        XmlAttribute(XmlName('Target'), _relTarget(wbPath, sstPath)),
      ]));
    }
    if (stylesPath == null) {
      stylesPath = XlsxPackage.resolve(wbPath, 'styles.xml');
      relsRoot.children.add(XmlElement(XmlName('Relationship'), [
        XmlAttribute(XmlName('Id'), newRelId()),
        XmlAttribute(XmlName('Type'), _relStyles),
        XmlAttribute(XmlName('Target'), _relTarget(wbPath, stylesPath)),
      ]));
    }

    // Styles + shared strings + worksheets.
    final theme = parseThemeColors(themePath == null ? null : partText(themePath));
    final styles = _StyleTable(partText(stylesPath) ?? _templateStyles, theme);
    final sst = _SharedStrings();
    for (var i = 0; i < plans.length; i++) {
      final (sheet, path, _, _, reused) = plans[i];
      _SheetExtras? extras;
      if (reused && orig != null) {
        final xml = orig.text(path);
        if (xml != null) {
          try {
            extras = _extractExtras(xml);
          } catch (_) {
            extras = null;
          }
        }
        if (extras != null &&
            !sheet.structureChanged &&
            extras.top.containsKey('tableParts')) {
          _updateTables(orig, path, sheet, parts, wb.date1904);
        }
      }
      parts[path] = _utf8(_sheetXml(sheet, styles, sst, extras,
          selected: i == wb.activeSheet, date1904: wb.date1904));
    }
    parts[stylesPath] = _utf8(styles.finish());
    parts[sstPath] = _utf8(sst.build());

    // workbook.xml
    sheetsEl.children.clear();
    final renames = <String, String>{};
    final deletedNames = <String>[];
    for (final s in wb.sheets) {
      if (s.sourceName != null && s.sourcePath != null && s.sourceName != s.name) {
        renames[s.sourceName!] = s.name;
      }
    }
    for (final entry in pathToEl.entries) {
      if (!usedPaths.contains(entry.key)) {
        final n = entry.value.getAttribute('name');
        if (n != null) deletedNames.add(n);
      }
    }
    final oldIndexToNew = <int, int>{};
    for (var i = 0; i < plans.length; i++) {
      final (sheet, _, rid, sheetId, reused) = plans[i];
      final e = el('sheet')
        ..setAttribute('name', sheet.name)
        ..setAttribute('sheetId', '$sheetId');
      if (sheet.visibility == SheetVisibility.hidden) e.setAttribute('state', 'hidden');
      if (sheet.visibility == SheetVisibility.veryHidden) e.setAttribute('state', 'veryHidden');
      e.attributes.add(XmlAttribute(XmlName('id', relPrefix), rid));
      sheetsEl.children.add(e);
      if (reused && sheet.sourceIndex != null) oldIndexToNew[sheet.sourceIndex!] = i;
    }
    for (final n in nonWorksheetEls) {
      final oldIndex = origSheetEls.indexOf(n);
      oldIndexToNew[oldIndex] = sheetsEl.children.whereType<XmlElement>().length;
      sheetsEl.children.add(n.copy());
    }
    final views = firstChild(wbRoot, 'bookViews');
    final view = views == null ? null : firstChild(views, 'workbookView');
    if (view != null) {
      view.setAttribute('activeTab', wb.activeSheet == 0 ? null : '${wb.activeSheet}');
      view.setAttribute('firstSheet', null);
    }
    var wbPr = firstChild(wbRoot, 'workbookPr');
    if (wbPr == null) {
      wbPr = el('workbookPr');
      final idx = wbRoot.children.indexWhere((n) =>
          n is XmlElement &&
          !const ['fileVersion', 'fileSharing'].contains(n.name.local));
      wbRoot.children.insert(idx < 0 ? 0 : idx, wbPr);
    }
    wbPr.setAttribute('date1904', wb.date1904 ? '1' : null);
    final names = firstChild(wbRoot, 'definedNames');
    if (names != null) {
      for (final dn in childElements(names, 'definedName').toList()) {
        final local = dn.getAttribute('localSheetId');
        if (local != null) {
          final mapped = oldIndexToNew[int.tryParse(local) ?? -1];
          if (mapped == null) {
            names.children.remove(dn);
            continue;
          }
          dn.setAttribute('localSheetId', '$mapped');
        }
        var text = dn.innerText;
        var changed = false;
        renames.forEach((from, to) {
          final t = FormulaRefs.renameSheet(text, from, to);
          if (t != text) {
            text = t;
            changed = true;
          }
        });
        for (final d in deletedNames) {
          final t = FormulaRefs.deleteSheet(text, d);
          if (t != text) {
            text = t;
            changed = true;
          }
        }
        if (changed) dn.innerText = text;
      }
      if (childElements(names, 'definedName').isEmpty) wbRoot.children.remove(names);
    }
    var calcPr = firstChild(wbRoot, 'calcPr');
    if (calcPr == null) {
      calcPr = el('calcPr')..setAttribute('calcId', '191029');
      var insertAt = -1;
      for (var i = 0; i < wbRoot.children.length; i++) {
        final n = wbRoot.children[i];
        if (n is XmlElement &&
            const ['sheets', 'functionGroups', 'externalReferences', 'definedNames']
                .contains(n.name.local)) {
          insertAt = i + 1;
        }
      }
      wbRoot.children.insert(insertAt < 0 ? wbRoot.children.length : insertAt, calcPr);
    }
    calcPr.setAttribute('fullCalcOnLoad', '1');
    parts[wbPath] = _utf8(wbDoc.toXmlString());
    parts[wbRelsPath] = _utf8(relsDoc.toXmlString());

    // [Content_Types].xml
    final overrides = <String, XmlElement>{};
    for (final o in ctRoot.childElements.toList()) {
      if (o.name.local != 'Override') continue;
      final pn = (o.getAttribute('PartName') ?? '').replaceFirst('/', '').toLowerCase();
      if (removedParts.contains(pn)) {
        ctRoot.children.remove(o);
        continue;
      }
      overrides[pn] = o;
    }
    void override(String path, String type) {
      final existing = overrides[path.toLowerCase()];
      if (existing != null) {
        existing.setAttribute('ContentType', type);
        return;
      }
      final o = XmlElement(XmlName('Override', ctRoot.name.prefix), [
        XmlAttribute(XmlName('PartName'), '/$path'),
        XmlAttribute(XmlName('ContentType'), type),
      ]);
      ctRoot.children.add(o);
      overrides[path.toLowerCase()] = o;
    }

    override(wbPath, _workbookContentType(fmt));
    override(stylesPath, _ctStyles);
    override(sstPath, _ctSst);
    for (final p in plans) {
      override(p.$2, _ctWorksheet);
    }
    var hasRelsDefault = false;
    var hasXmlDefault = false;
    for (final d in ctRoot.childElements) {
      if (d.name.local != 'Default') continue;
      final ext = d.getAttribute('Extension')?.toLowerCase();
      if (ext == 'rels') hasRelsDefault = true;
      if (ext == 'xml') hasXmlDefault = true;
    }
    if (!hasRelsDefault) {
      ctRoot.children.insert(0, XmlElement(XmlName('Default', ctRoot.name.prefix), [
        XmlAttribute(XmlName('Extension'), 'rels'),
        XmlAttribute(XmlName('ContentType'), 'application/vnd.openxmlformats-package.relationships+xml'),
      ]));
    }
    if (!hasXmlDefault) {
      ctRoot.children.insert(0, XmlElement(XmlName('Default', ctRoot.name.prefix), [
        XmlAttribute(XmlName('Extension'), 'xml'),
        XmlAttribute(XmlName('ContentType'), 'application/xml'),
      ]));
    }
    parts['[Content_Types].xml'] = _utf8(ctDoc.toXmlString());

    // Assemble.
    final archive = Archive();
    void add(String name, Uint8List data) {
      archive.addFile(ArchiveFile(name, data.length, data));
    }

    add('[Content_Types].xml', parts.remove('[Content_Types].xml')!);
    final written = <String>{'[content_types].xml'};
    final partsLower = {for (final k in parts.keys) k.toLowerCase(): k};
    if (orig != null) {
      for (final name in keepOrder) {
        final lower = name.toLowerCase();
        if (written.contains(lower) || removedParts.contains(lower)) continue;
        final replacement = partsLower[lower];
        if (replacement != null) {
          add(replacement, parts[replacement]!);
          written.add(lower);
          continue;
        }
        final f = orig.file(name);
        if (f == null) continue;
        archive.addFile(f);
        written.add(lower);
      }
    } else {
      for (final entry in _templateParts.entries) {
        final lower = entry.key.toLowerCase();
        if (written.contains(lower) || partsLower.containsKey(lower)) continue;
        add(entry.key, _utf8(entry.value));
        written.add(lower);
      }
    }
    for (final entry in parts.entries) {
      if (written.contains(entry.key.toLowerCase())) continue;
      add(entry.key, entry.value);
      written.add(entry.key.toLowerCase());
    }
    final out = ZipEncoder().encode(archive);
    if (out == null) throw StateError('Zip encoding failed');
    return XlsxWriteResult(Uint8List.fromList(out), [for (final p in plans) p.$2]);
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  /// Relationship target for [path] relative to [from]'s folder.
  static String _relTarget(String from, String path) {
    final dir = from.contains('/') ? from.substring(0, from.lastIndexOf('/') + 1) : '';
    if (dir.isNotEmpty && path.startsWith(dir)) return path.substring(dir.length);
    return '/$path';
  }

  /// Keeps table header names in sync with the header cells (Excel repairs
  /// the file otherwise).
  static void _updateTables(XlsxPackage pkg, String sheetPath, SheetData sheet,
      Map<String, Uint8List> parts, bool date1904) {
    for (final rel in pkg.rels(sheetPath).values) {
      if (!rel.$1.endsWith('/table')) continue;
      final xml = pkg.text(rel.$2);
      if (xml == null) continue;
      try {
        final doc = XmlDocument.parse(xml);
        final root = doc.rootElement;
        final range = CellRange.parse(root.getAttribute('ref') ?? '');
        if (range == null || root.getAttribute('headerRowCount') == '0') continue;
        final cols = firstChild(root, 'tableColumns');
        if (cols == null) continue;
        final used = <String>{};
        var i = 0;
        var changed = false;
        for (final tc in childElements(cols, 'tableColumn')) {
          final cell = sheet.cell(range.r1, range.c1 + i);
          var name = CsvCodec.cellText(cell, date1904: date1904).trim();
          if (name.isEmpty) name = 'Column${i + 1}';
          var unique = name;
          var n = 2;
          while (used.contains(unique.toLowerCase())) {
            unique = '$name$n';
            n++;
          }
          used.add(unique.toLowerCase());
          if (tc.getAttribute('name') != unique) {
            tc.setAttribute('name', unique);
            changed = true;
          }
          i++;
        }
        if (changed) parts[rel.$2] = _utf8(doc.toXmlString());
      } catch (_) {}
    }
  }

  static String _sheetXml(SheetData sheet, _StyleTable styles, _SharedStrings sst,
      _SheetExtras? extras, {required bool selected, required bool date1904}) {
    final b = StringBuffer();
    b.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet');
    final declared = <String>{};
    b.write(' xmlns="$_nsMain"');
    declared.add('xmlns');
    if (extras != null) {
      for (final (name, value) in extras.rootAttrs) {
        if (declared.contains(name)) continue;
        declared.add(name);
        b.write(' $name="${_esc(value)}"');
      }
    }
    if (!declared.contains('xmlns:r')) b.write(' xmlns:r="$_nsRel"');
    b.write('>');

    final keep = extras == null
        ? const <String, String>{}
        : {
            for (final (name, raw) in extras.ordered)
              if (!sheet.structureChanged || _structureSafe.contains(name) || name == 'sheetPr')
                name: raw,
          };
    if (keep.containsKey('sheetPr')) b.write(keep['sheetPr']);

    final rows = sheet.usedRows;
    final cols = sheet.usedCols;
    b.write('<dimension ref="${rows == 0 || cols == 0 ? 'A1' : 'A1:${cellName(rows - 1, cols - 1)}'}"/>');

    // sheetViews
    b.write('<sheetViews><sheetView');
    final viewAttrs = extras?.sheetViewAttrs ?? const <(String, String)>[];
    var hasWbView = false;
    for (final (name, value) in viewAttrs) {
      if (name == 'tabSelected' || name == 'topLeftCell') continue;
      if (name == 'workbookViewId') hasWbView = true;
      b.write(' $name="${_esc(value)}"');
    }
    if (selected) b.write(' tabSelected="1"');
    if (!hasWbView) b.write(' workbookViewId="0"');
    final fr = sheet.frozenRows;
    final fc = sheet.frozenCols;
    if (fr > 0 || fc > 0) {
      final pane = fr > 0 && fc > 0 ? 'bottomRight' : (fr > 0 ? 'bottomLeft' : 'topRight');
      b.write('><pane');
      if (fc > 0) b.write(' xSplit="$fc"');
      if (fr > 0) b.write(' ySplit="$fr"');
      b.write(' topLeftCell="${cellName(fr, fc)}" activePane="$pane" state="frozen"/>');
      b.write('<selection pane="$pane"/></sheetView>');
    } else {
      b.write('/>');
    }
    b.write('</sheetViews>');

    final defRowPt = sheet.defaultRowHeight * 0.75;
    b.write('<sheetFormatPr');
    if ((sheet.defaultColWidth - kDefaultColWidth).abs() > 0.5) {
      b.write(' defaultColWidth="${_num((sheet.defaultColWidth / 7 * 100).round() / 100)}"');
    }
    b.write(' defaultRowHeight="${_num((defRowPt * 100).round() / 100)}"');
    if ((sheet.defaultRowHeight - kDefaultRowHeight).abs() > 0.5) b.write(' customHeight="1"');
    b.write('/>');

    // cols
    final colKeys = <int>{...sheet.colWidths.keys, ...sheet.hiddenCols}.toList()..sort();
    if (colKeys.isNotEmpty) {
      b.write('<cols>');
      var i = 0;
      while (i < colKeys.length) {
        final start = colKeys[i];
        final w = sheet.colWidths[start] ?? sheet.defaultColWidth;
        final hidden = sheet.hiddenCols.contains(start);
        var end = start;
        while (i + 1 < colKeys.length &&
            colKeys[i + 1] == end + 1 &&
            (sheet.colWidths[colKeys[i + 1]] ?? sheet.defaultColWidth) == w &&
            sheet.hiddenCols.contains(colKeys[i + 1]) == hidden) {
          i++;
          end++;
        }
        final chars = (w / 7 * 256).round() / 256;
        b.write('<col min="${start + 1}" max="${end + 1}" width="${_num(chars)}" customWidth="1"');
        if (hidden) b.write(' hidden="1"');
        b.write('/>');
        i++;
      }
      b.write('</cols>');
    }

    // sheetData
    b.write('<sheetData>');
    final keys = sheet.cells.keys.toList()..sort();
    final rowAttrRows = <int>{...sheet.rowHeights.keys, ...sheet.hiddenRows}.toList()..sort();
    var ki = 0;
    var ai = 0;
    while (ki < keys.length || ai < rowAttrRows.length) {
      final nextCellRow = ki < keys.length ? keyRow(keys[ki]) : kMaxRows;
      final nextAttrRow = ai < rowAttrRows.length ? rowAttrRows[ai] : kMaxRows;
      final r = nextCellRow < nextAttrRow ? nextCellRow : nextAttrRow;
      if (r >= kMaxRows) break;
      if (nextAttrRow == r) ai++;
      b.write('<row r="${r + 1}"');
      final h = sheet.rowHeights[r];
      if (h != null) b.write(' ht="${_num((h * 0.75 * 100).round() / 100)}" customHeight="1"');
      if (sheet.hiddenRows.contains(r)) b.write(' hidden="1"');
      var any = false;
      while (ki < keys.length && keyRow(keys[ki]) == r) {
        if (!any) {
          b.write('>');
          any = true;
        }
        final k = keys[ki++];
        final c = keyCol(k);
        final cell = sheet.cells[k]!;
        _writeCell(b, r, c, cell, styles, sst);
      }
      b.write(any ? '</row>' : '/>');
    }
    b.write('</sheetData>');

    for (final name in _preMergeKeep) {
      final raw = keep[name];
      if (raw != null) b.write(raw);
    }
    if (sheet.merges.isNotEmpty) {
      b.write('<mergeCells count="${sheet.merges.length}">');
      for (final m in sheet.merges) {
        b.write('<mergeCell ref="${m.toA1()}"/>');
      }
      b.write('</mergeCells>');
    }
    for (final name in _postMergeKeep) {
      if (extras == null) break;
      for (final (n, raw) in extras.ordered) {
        if (n != name || !keep.containsKey(n)) continue;
        b.write(raw);
      }
    }
    if (extras == null || !keep.containsKey('pageMargins')) {
      if (extras == null) {
        b.write('<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>');
      }
    }
    b.write('</worksheet>');
    return b.toString();
  }

  static void _writeCell(StringBuffer b, int r, int c, Cell cell, _StyleTable styles,
      _SharedStrings sst) {
    final ref = cellName(r, c);
    final s = styles.indexOf(cell.style);
    final v = cell.value;
    final f = cell.formula;
    b.write('<c r="$ref"');
    if (s != 0) b.write(' s="$s"');
    if (f != null) {
      String? t;
      String? val;
      if (v is String) {
        t = 'str';
        val = _esc(v);
      } else if (v is double) {
        if (v.isFinite) val = _num(v);
      } else if (v is bool) {
        t = 'b';
        val = v ? '1' : '0';
      } else if (v is CellError && v.isStandard) {
        t = 'e';
        val = v.code;
      }
      if (t != null) b.write(' t="$t"');
      b.write('>');
      final ftext = _esc(addFunctionPrefixes(f));
      if (cell.arrayRef != null) {
        b.write('<f t="array" ref="${cell.arrayRef}">$ftext</f>');
      } else {
        b.write('<f>$ftext</f>');
      }
      if (val != null) b.write('<v>$val</v>');
      b.write('</c>');
      return;
    }
    if (v == null) {
      b.write('/>');
    } else if (v is String) {
      b.write(' t="s"><v>${sst.add(v)}</v></c>');
    } else if (v is double) {
      if (v.isFinite) {
        b.write('><v>${_num(v)}</v></c>');
      } else {
        b.write(' t="e"><v>#NUM!</v></c>');
      }
    } else if (v is bool) {
      b.write(' t="b"><v>${v ? 1 : 0}</v></c>');
    } else if (v is CellError) {
      b.write(' t="e"><v>${v.isStandard ? v.code : '#N/A'}</v></c>');
    } else {
      b.write(' t="s"><v>${sst.add(v.toString())}</v></c>');
    }
  }
}
