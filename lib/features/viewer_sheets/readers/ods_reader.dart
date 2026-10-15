import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../formula/parser.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import 'xlsx_reader.dart' show SpreadsheetReadException, XlsxPackage;
import 'xlsx_styles.dart' show localName;

class _OdsCellStyle {
  _OdsCellStyle({this.parent, this.dataStyle});
  String? parent;
  String? dataStyle;
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  int? color;
  int? fill;
  double? size;
  HAlign? align;
  VAlign? valign;
  bool? wrap;
}

class _PendingCell {
  _PendingCell(this.col, this.cell, this.repeat, this.colSpan, this.rowSpan);
  final int col;
  final Cell cell;
  final int repeat;
  final int colSpan;
  final int rowSpan;
}

/// Reads OpenDocument spreadsheets (.ods / .ots).
abstract final class OdsReader {
  static const _maxRepeatWithContent = 2000;

  static Workbook read(Uint8List bytes) {
    final pkg = XlsxPackage.decode(bytes);
    final manifest = pkg.text('META-INF/manifest.xml');
    if (manifest != null && manifest.contains('encryption-data')) {
      throw SpreadsheetReadException('This spreadsheet is password-protected and can\'t be opened here.');
    }
    final content = pkg.text('content.xml');
    if (content == null) {
      throw SpreadsheetReadException('This file doesn\'t contain spreadsheet content.');
    }
    final dataStyles = <String, String>{};
    final cellStyles = <String, _OdsCellStyle>{};
    final colWidths = <String, double>{};
    final rowHeights = <String, double>{};
    final stylesXml = pkg.text('styles.xml');
    if (stylesXml != null) {
      _readStyles(stylesXml, dataStyles, cellStyles, colWidths, rowHeights);
    }
    final reader = _OdsBody(dataStyles, cellStyles, colWidths, rowHeights);
    reader.parse(content);
    if (reader.sheets.isEmpty) throw SpreadsheetReadException('This spreadsheet has no sheets.');
    _applySettings(pkg.text('settings.xml'), reader.sheets);
    for (final s in reader.sheets) {
      s.invalidateBounds();
    }
    return Workbook(sheets: reader.sheets, format: SpreadsheetFormat.ods, warnings: reader.warnings);
  }

  static void _applySettings(String? xml, List<SheetData> sheets) {
    if (xml == null) return;
    try {
      final doc = XmlDocument.parse(xml);
      for (final map in doc.descendantElements) {
        if (map.name.local != 'config-item-map-named' ||
            map.getAttribute('config:name') != 'Tables') {
          continue;
        }
        for (final entry in map.childElements) {
          final name = entry.getAttribute('config:name');
          final sheet = sheets.where((s) => s.name == name).firstOrNull;
          if (sheet == null) continue;
          final items = <String, String>{};
          for (final item in entry.childElements) {
            if (item.name.local == 'config-item') {
              items[item.getAttribute('config:name') ?? ''] = item.innerText.trim();
            }
          }
          if (items['HorizontalSplitMode'] == '2') {
            sheet.frozenCols = int.tryParse(items['HorizontalSplitPosition'] ?? '') ?? 0;
          }
          if (items['VerticalSplitMode'] == '2') {
            sheet.frozenRows = int.tryParse(items['VerticalSplitPosition'] ?? '') ?? 0;
          }
        }
      }
    } catch (_) {}
  }

  static void _readStyles(String xml, Map<String, String> dataStyles,
      Map<String, _OdsCellStyle> cellStyles, Map<String, double> colWidths,
      Map<String, double> rowHeights) {
    final body = _OdsBody(dataStyles, cellStyles, colWidths, rowHeights);
    body.parse(xml, stylesOnly: true);
  }
}

/// Length like `2.258cm` / `12pt` / `0.5in` to logical pixels.
double? odsLengthToPx(String? v) {
  if (v == null) return null;
  final m = RegExp(r'^(-?[\d.]+)\s*([a-z%]*)$').firstMatch(v.trim());
  if (m == null) return null;
  final n = double.tryParse(m[1]!);
  if (n == null) return null;
  return switch (m[2]) {
    'cm' => n * 37.7953,
    'mm' => n * 3.77953,
    'in' => n * 96,
    'pt' => n * 4 / 3,
    'pc' => n * 16,
    'px' || '' => n,
    _ => null,
  };
}

int? _parseHexColor(String? v) {
  if (v == null || !v.startsWith('#') || v.length != 7) return null;
  final n = int.tryParse(v.substring(1), radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

final _durationRe = RegExp(r'^-?P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?$');

double? _parseDuration(String v) {
  final m = _durationRe.firstMatch(v.trim());
  if (m == null) return null;
  final d = double.tryParse(m[1] ?? '0') ?? 0;
  final h = double.tryParse(m[2] ?? '0') ?? 0;
  final mi = double.tryParse(m[3] ?? '0') ?? 0;
  final s = double.tryParse(m[4] ?? '0') ?? 0;
  final total = d + (h * 3600 + mi * 60 + s) / 86400;
  return v.trim().startsWith('-') ? -total : total;
}

/// Converts OpenFormula (`of:=SUM([.A1:.B2])`) to Excel syntax.
String? convertOpenFormula(String f) {
  var s = f;
  final eq = s.indexOf('=');
  if (eq < 0) return null;
  final prefix = s.substring(0, eq);
  if (prefix.isNotEmpty && !RegExp(r'^[a-zA-Z]+:$').hasMatch(prefix)) return null;
  s = s.substring(eq + 1);
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '"') {
      final end = s.indexOf('"', i + 1);
      var j = end;
      while (j >= 0 && j + 1 < s.length && s[j + 1] == '"') {
        j = s.indexOf('"', j + 2);
      }
      if (j < 0) return null;
      b.write(s.substring(i, j + 1));
      i = j + 1;
      continue;
    }
    if (ch == '[') {
      final end = s.indexOf(']', i);
      if (end < 0) return null;
      final inner = s.substring(i + 1, end);
      final conv = _convertRef(inner);
      if (conv == null) return null;
      b.write(conv);
      i = end + 1;
      continue;
    }
    if (ch == ';') {
      b.write(',');
      i++;
      continue;
    }
    b.write(ch);
    i++;
  }
  var out = b.toString().replaceAll(RegExp(r'COM\.MICROSOFT\.', caseSensitive: false), '');
  out = out.replaceAll(RegExp(r'_xlfn\.', caseSensitive: false), '');
  try {
    parseFormula(out);
  } catch (_) {
    return null;
  }
  return out;
}

String? _convertRef(String inner) {
  if (inner.contains('#REF!')) return '#REF!';
  final parts = inner.split(':');
  final out = <String>[];
  for (final p in parts) {
    var part = p.trim();
    // Find the separator dot that isn't inside quotes.
    var inQuote = false;
    var dot = -1;
    for (var k = 0; k < part.length; k++) {
      final c = part[k];
      if (c == "'") inQuote = !inQuote;
      if (c == '.' && !inQuote) dot = k;
    }
    if (dot < 0) return null;
    var sheet = part.substring(0, dot);
    final ref = part.substring(dot + 1);
    if (sheet.startsWith(r'$')) sheet = sheet.substring(1);
    if (sheet.isEmpty) {
      out.add(ref);
    } else {
      if (sheet.startsWith("'") && sheet.endsWith("'")) {
        out.add('$sheet!$ref');
      } else {
        final needsQuote = !RegExp(r'^[A-Za-z_][A-Za-z0-9_.]*$').hasMatch(sheet);
        out.add(needsQuote ? "'${sheet.replaceAll("'", "''")}'!$ref" : '$sheet!$ref');
      }
    }
  }
  if (out.length == 2 && out[1].contains('!')) {
    out[1] = out[1].substring(out[1].indexOf('!') + 1);
  }
  return out.join(':');
}

class _OdsBody {
  _OdsBody(this.dataStyles, this.cellStyles, this.colWidths, this.rowHeights);

  final Map<String, String> dataStyles;
  final Map<String, _OdsCellStyle> cellStyles;
  final Map<String, double> colWidths;
  final Map<String, double> rowHeights;
  final sheets = <SheetData>[];
  final warnings = <String>[];
  final _resolved = <String, CellStyle>{};

  CellStyle _resolve(String? name) {
    if (name == null) return CellStyle.plain;
    final cached = _resolved[name];
    if (cached != null) return cached;
    final chain = <_OdsCellStyle>[];
    var cur = cellStyles[name];
    var guard = 0;
    while (cur != null && guard++ < 10) {
      chain.add(cur);
      cur = cur.parent == null ? null : cellStyles[cur.parent];
    }
    bool? bold, italic, underline, strike, wrap;
    int? color, fill;
    double? size;
    HAlign? align;
    VAlign? valign;
    String? data;
    for (final s in chain) {
      bold ??= s.bold;
      italic ??= s.italic;
      underline ??= s.underline;
      strike ??= s.strike;
      wrap ??= s.wrap;
      color ??= s.color;
      fill ??= s.fill;
      size ??= s.size;
      align ??= s.align;
      valign ??= s.valign;
      data ??= s.dataStyle;
    }
    final style = CellStyle(
      bold: bold ?? false,
      italic: italic ?? false,
      underline: underline ?? false,
      strike: strike ?? false,
      wrap: wrap ?? false,
      fontColor: color == 0xFF000000 ? null : color,
      fillColor: fill,
      fontSize: size == null || (size - 10).abs() < 0.01 ? null : size * 11 / 10,
      hAlign: align ?? HAlign.general,
      vAlign: valign ?? VAlign.bottom,
      numFmt: data == null ? 'General' : (dataStyles[data] ?? 'General'),
    );
    _resolved[name] = style;
    return style;
  }

  // --- number styles ---------------------------------------------------------
  String? _dsName;
  String? _dsKind;
  final _dsParts = StringBuffer();
  int _dsDecimals = 0;
  bool _dsGrouping = false;
  bool _inDsText = false;
  String? _dsCurrency;
  bool _inCurrencySymbol = false;

  void _numberPart(XmlStartElementEvent e) {
    String? attr(String n) =>
        e.attributes.where((a) => a.localName == n).map((a) => a.value).firstOrNull;
    final long = attr('style') == 'long';
    switch (localName(e.name)) {
      case 'number':
        _dsDecimals = int.tryParse(attr('decimal-places') ?? '') ?? 0;
        _dsGrouping = attr('grouping') == 'true';
        final minInt = int.tryParse(attr('min-integer-digits') ?? '1') ?? 1;
        final intPart = _dsGrouping ? '#,##${minInt > 0 ? '0' : '#'}' : (minInt > 0 ? '0' : '#');
        _dsParts.write(intPart);
        if (_dsDecimals > 0) _dsParts.write('.${'0' * _dsDecimals}');
      case 'scientific-number':
        final dec = int.tryParse(attr('decimal-places') ?? '') ?? 2;
        _dsParts.write('0${dec > 0 ? '.${'0' * dec}' : ''}E+00');
      case 'fraction':
        _dsParts.write('# ?/?');
      case 'year':
        _dsParts.write(long ? 'yyyy' : 'yy');
      case 'month':
        final textual = attr('textual') == 'true';
        _dsParts.write(textual ? (long ? 'mmmm' : 'mmm') : (long ? 'mm' : 'm'));
      case 'day':
        _dsParts.write(long ? 'dd' : 'd');
      case 'day-of-week':
        _dsParts.write(long ? 'dddd' : 'ddd');
      case 'hours':
        _dsParts.write(long ? 'hh' : 'h');
      case 'minutes':
        _dsParts.write(long ? 'mm' : 'm');
      case 'seconds':
        _dsParts.write(long ? 'ss' : 's');
        final dec = int.tryParse(attr('decimal-places') ?? '') ?? 0;
        if (dec > 0) _dsParts.write('.${'0' * dec}');
      case 'am-pm':
        _dsParts.write('AM/PM');
      case 'text':
        _inDsText = true;
      case 'currency-symbol':
        _inCurrencySymbol = true;
      case 'text-content':
        _dsParts.write('@');
    }
  }

  void _endDataStyle() {
    final name = _dsName;
    if (name == null) return;
    var code = _dsParts.toString();
    switch (_dsKind) {
      case 'percentage-style':
        if (!code.contains('%')) code = '${code.isEmpty ? '0' : code}%';
      case 'currency-style':
        if (code.isEmpty) code = '#,##0.00';
        if (_dsCurrency != null && !code.contains(_dsCurrency!)) {
          code = '"$_dsCurrency"$code';
        }
      case 'boolean-style':
        code = 'General';
    }
    if (code.isEmpty) code = 'General';
    dataStyles[name] = code;
    _dsName = null;
    _dsKind = null;
  }

  // --- body -------------------------------------------------------------------
  void parse(String xml, {bool stylesOnly = false}) {
    SheetData? sheet;
    var row = 0;
    var col = 0;
    var rowRepeat = 1;
    String? rowStyle;
    var rowCells = <_PendingCell>[];
    final colDefaults = <int, String>{};
    String? styleName;
    _OdsCellStyle? curStyle;
    String? curStyleFamily;

    // current cell
    var inCell = false;
    var cellRepeat = 1;
    var colSpan = 1;
    var rowSpan = 1;
    String? valueType;
    String? value;
    String? formula;
    String? cellStyleName;
    final text = StringBuffer();
    var paragraphs = 0;
    var inP = 0;
    var inAnnotation = 0;

    for (final e in parseEvents(xml)) {
      if (e is XmlStartElementEvent) {
        final name = localName(e.name);
        String? attr(String n) =>
            e.attributes.where((a) => a.localName == n).map((a) => a.value).firstOrNull;
        if (_dsName != null) {
          _numberPart(e);
          if (e.isSelfClosing && (name == 'text' || name == 'currency-symbol')) {
            _inDsText = false;
            _inCurrencySymbol = false;
          }
          continue;
        }
        switch (name) {
          case 'number-style':
          case 'percentage-style':
          case 'currency-style':
          case 'date-style':
          case 'time-style':
          case 'boolean-style':
          case 'text-style':
            _dsName = attr('name');
            _dsKind = name;
            _dsParts.clear();
            _dsCurrency = null;
            if (e.isSelfClosing) _endDataStyle();
          case 'style':
            styleName = attr('name');
            curStyleFamily = attr('family');
            if (curStyleFamily == 'table-cell' && styleName != null) {
              curStyle = _OdsCellStyle(parent: attr('parent-style-name'), dataStyle: attr('data-style-name'));
              cellStyles[styleName] = curStyle;
            } else {
              curStyle = null;
            }
            if (e.isSelfClosing) {
              curStyle = null;
              styleName = null;
            }
          case 'default-style':
            if (attr('family') == 'table-cell') {
              curStyle = _OdsCellStyle();
              cellStyles['__default'] = curStyle;
              styleName = '__default';
              curStyleFamily = 'table-cell';
            }
          case 'text-properties':
            final s = curStyle;
            if (s != null) {
              final w = attr('font-weight');
              if (w != null) s.bold = w == 'bold' || (int.tryParse(w) ?? 400) >= 600;
              final st = attr('font-style');
              if (st != null) s.italic = st == 'italic' || st == 'oblique';
              final u = attr('text-underline-style');
              if (u != null) s.underline = u != 'none';
              final lt = attr('text-line-through-style');
              if (lt != null) s.strike = lt != 'none';
              final c = _parseHexColor(attr('color'));
              if (c != null) s.color = c;
              final fs = attr('font-size');
              if (fs != null && fs.endsWith('pt')) s.size = double.tryParse(fs.replaceAll('pt', ''));
            }
          case 'table-cell-properties':
            final s = curStyle;
            if (s != null) {
              final bg = attr('background-color');
              if (bg != null && bg != 'transparent') s.fill = _parseHexColor(bg);
              final wrap = attr('wrap-option');
              if (wrap != null) s.wrap = wrap == 'wrap';
              final va = attr('vertical-align');
              if (va != null) {
                s.valign = va == 'top' ? VAlign.top : (va == 'middle' ? VAlign.center : VAlign.bottom);
              }
            }
          case 'paragraph-properties':
            final s = curStyle;
            final ta = attr('text-align');
            if (s != null && ta != null) {
              s.align = switch (ta) {
                'center' => HAlign.center,
                'end' || 'right' => HAlign.right,
                'start' || 'left' => HAlign.left,
                'justify' => HAlign.justify,
                _ => null,
              };
            }
          case 'table-column-properties':
            final w = odsLengthToPx(attr('column-width'));
            if (w != null && styleName != null) colWidths[styleName] = w;
          case 'table-row-properties':
            final h = odsLengthToPx(attr('row-height'));
            if (h != null && styleName != null) rowHeights[styleName] = h;
          case 'table':
            if (stylesOnly) break;
            sheet = SheetData(name: attr('name') ?? 'Sheet${sheets.length + 1}');
            sheets.add(sheet);
            row = 0;
            col = 0;
            colDefaults.clear();
          case 'table-column':
            if (sheet == null) break;
            final rep = (int.tryParse(attr('number-columns-repeated') ?? '1') ?? 1).clamp(1, kMaxCols);
            final w = colWidths[attr('style-name') ?? ''];
            final def = attr('default-cell-style-name');
            final hidden = attr('visibility') == 'collapse';
            final end = (col + rep).clamp(0, 2048);
            for (var c = col; c < end; c++) {
              if (w != null) sheet.colWidths[c] = w.roundToDouble();
              if (def != null && def != 'Default') colDefaults[c] = def;
              if (hidden) sheet.hiddenCols.add(c);
            }
            col += rep;
          case 'table-row':
            if (sheet == null) break;
            col = 0;
            rowRepeat = (int.tryParse(attr('number-rows-repeated') ?? '1') ?? 1).clamp(1, kMaxRows);
            rowStyle = attr('style-name');
            rowCells = <_PendingCell>[];
            final hidden = attr('visibility') == 'collapse';
            if (hidden && rowRepeat < 1000) {
              for (var r = row; r < row + rowRepeat; r++) {
                sheet.hiddenRows.add(r);
              }
            }
            if (e.isSelfClosing) {
              row += rowRepeat;
            }
          case 'table-cell':
          case 'covered-table-cell':
            if (sheet == null) break;
            cellRepeat = (int.tryParse(attr('number-columns-repeated') ?? '1') ?? 1).clamp(1, kMaxCols);
            if (name == 'covered-table-cell') {
              col += cellRepeat;
              inCell = false;
              break;
            }
            colSpan = int.tryParse(attr('number-columns-spanned') ?? '1') ?? 1;
            rowSpan = int.tryParse(attr('number-rows-spanned') ?? '1') ?? 1;
            valueType = attr('value-type');
            cellStyleName = attr('style-name');
            formula = attr('formula');
            switch (valueType) {
              case 'float':
              case 'percentage':
              case 'currency':
                value = attr('value');
              case 'date':
                value = attr('date-value');
              case 'time':
                value = attr('time-value');
              case 'boolean':
                value = attr('boolean-value');
              default:
                value = attr('string-value');
            }
            text.clear();
            paragraphs = 0;
            inCell = true;
            if (e.isSelfClosing) {
              _finishCell(sheet, rowCells, col, cellRepeat, colSpan, rowSpan, valueType, value,
                  formula, cellStyleName ?? colDefaults[col], text.toString());
              col += cellRepeat;
              inCell = false;
            }
          case 'p':
            if (inCell && inAnnotation == 0) {
              if (paragraphs > 0) text.write('\n');
              paragraphs++;
              if (!e.isSelfClosing) inP++;
            }
          case 's':
            if (inP > 0 && inAnnotation == 0) {
              text.write(' ' * (int.tryParse(attr('c') ?? '1') ?? 1));
            }
          case 'tab':
            if (inP > 0 && inAnnotation == 0) text.write('\t');
          case 'line-break':
            if (inP > 0 && inAnnotation == 0) text.write('\n');
          case 'annotation':
            if (!e.isSelfClosing) inAnnotation++;
        }
      } else if (e is XmlEndElementEvent) {
        final name = localName(e.name);
        if (_dsName != null) {
          if (name == 'text') _inDsText = false;
          if (name == 'currency-symbol') _inCurrencySymbol = false;
          if (name == _dsKind) _endDataStyle();
          continue;
        }
        switch (name) {
          case 'style':
          case 'default-style':
            curStyle = null;
            styleName = null;
          case 'p':
            if (inP > 0) inP--;
          case 'annotation':
            if (inAnnotation > 0) inAnnotation--;
          case 'table-cell':
            if (sheet != null && inCell) {
              _finishCell(sheet, rowCells, col, cellRepeat, colSpan, rowSpan, valueType, value,
                  formula, cellStyleName ?? colDefaults[col], text.toString());
              col += cellRepeat;
            }
            inCell = false;
          case 'table-row':
            if (sheet == null) break;
            final h = rowHeights[rowStyle ?? ''];
            if (rowCells.isEmpty) {
              if (h != null && rowRepeat < 1000) {
                for (var r = row; r < row + rowRepeat && r < kMaxRows; r++) {
                  if ((h - sheet.defaultRowHeight).abs() > 1) sheet.rowHeights[r] = h.roundToDouble();
                }
              }
              row += rowRepeat;
              break;
            }
            final reps = rowRepeat.clamp(1, OdsReader._maxRepeatWithContent);
            for (var k = 0; k < reps && row < kMaxRows; k++) {
              if (h != null && (h - sheet.defaultRowHeight).abs() > 1) {
                sheet.rowHeights[row] = h.roundToDouble();
              }
              for (final pc in rowCells) {
                final reps2 = pc.repeat.clamp(1, OdsReader._maxRepeatWithContent);
                for (var j = 0; j < reps2; j++) {
                  final c = pc.col + j;
                  if (c >= kMaxCols) break;
                  sheet.cells[cellKey(row, c)] = pc.cell;
                }
                if (k == 0 && (pc.colSpan > 1 || pc.rowSpan > 1)) {
                  sheet.merges.add(CellRange(row, pc.col, row + pc.rowSpan - 1, pc.col + pc.colSpan - 1));
                }
              }
              row++;
            }
            if (rowRepeat > reps) row += rowRepeat - reps;
            rowCells = <_PendingCell>[];
        }
      } else if (e is XmlTextEvent) {
        if (_dsName != null) {
          if (_inDsText) {
            final t = e.value;
            if (t.trim() == '%') {
              _dsParts.write('%');
            } else if (t.isNotEmpty) {
              _dsParts.write('"${t.replaceAll('"', '')}"');
            }
          } else if (_inCurrencySymbol) {
            _dsCurrency = e.value;
            _dsParts.write('"${e.value}"');
          }
        } else if (inP > 0 && inAnnotation == 0) {
          text.write(e.value);
        }
      }
    }
  }

  void _finishCell(SheetData sheet, List<_PendingCell> rowCells, int col, int repeat,
      int colSpan, int rowSpan, String? valueType, String? value, String? formula,
      String? styleName, String text) {
    var style = _resolve(styleName);
    Object? v;
    switch (valueType) {
      case 'float':
      case 'percentage':
      case 'currency':
        v = double.tryParse(value ?? '');
        if (valueType == 'percentage' && style.numFmt == 'General') {
          style = style.copyWith(numFmt: '0%');
        } else if (valueType == 'currency' && style.numFmt == 'General') {
          style = style.copyWith(numFmt: '#,##0.00');
        }
      case 'date':
        final s = value ?? '';
        final dt = DateTime.tryParse(s.length == 10 ? '${s}T00:00:00Z' : (s.endsWith('Z') ? s : '${s}Z'));
        if (dt != null) {
          v = NumberFormats.dateTimeToSerial(dt);
          if (style.numFmt == 'General') {
            style = style.copyWith(numFmt: s.length > 10 ? 'yyyy-mm-dd hh:mm:ss' : 'yyyy-mm-dd');
          }
        } else {
          v = text;
        }
      case 'time':
        v = _parseDuration(value ?? '');
        if (v != null && style.numFmt == 'General') {
          style = style.copyWith(numFmt: 'h:mm:ss');
        }
        v ??= text;
      case 'boolean':
        v = value == 'true';
      case 'string':
        v = value ?? text;
      default:
        v = text.isEmpty ? null : text;
    }
    String? f;
    if (formula != null) {
      f = convertOpenFormula(formula);
      if (f != null && v is String && v.startsWith('Err:')) v = CellError.value;
    }
    if (v == null && f == null && style.isDefaultLook) return;
    if (v == null && f == null && repeat > 64) return; // style-only runs
    if (v is double && v == 0) v = 0.0;
    rowCells.add(_PendingCell(col, Cell(value: v, formula: f, style: style), repeat, colSpan, rowSpan));
  }
}
