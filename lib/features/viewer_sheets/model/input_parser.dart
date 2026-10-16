import '../formula/evaluator.dart' show parseNumberText;
import '../formula/functions.dart' show parseDateText;
import '../formula/parser.dart';
import '../formula/tokenizer.dart';
import 'number_format.dart';
import 'workbook.dart';

final _timeRe = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?$');

/// Converts what the user typed into a cell. Returns null for "empty".
Cell? parseCellInput(String text, CellStyle style, {bool date1904 = false}) {
  if (text.isEmpty) {
    return style.isDefaultLook && style.baseXf == null ? null : Cell(style: style);
  }
  if (text.startsWith("'")) return Cell(value: text.substring(1), style: style);
  if (text.startsWith('=') && text.trim().length > 1) {
    final f = normalizeFormula(text.substring(1).trim());
    var s = style;
    if (s.numFmt == 'General') {
      try {
        final node = parseFormula(f);
        if (node is FuncNode) {
          if (node.name == 'TODAY' || node.name == 'DATE' || node.name == 'EDATE' ||
              node.name == 'EOMONTH' || node.name == 'DATEVALUE') {
            s = s.copyWith(numFmt: 'yyyy-mm-dd');
          } else if (node.name == 'NOW') {
            s = s.copyWith(numFmt: 'yyyy-mm-dd h:mm');
          }
        }
      } catch (_) {}
    }
    return Cell(formula: f, style: s);
  }
  if (NumberFormats.isTextFormat(style.numFmt)) return Cell(value: text, style: style);
  final t = text.trim();
  final upper = t.toUpperCase();
  if (upper == 'TRUE' || upper == 'FALSE') return Cell(value: upper == 'TRUE', style: style);
  final err = CellError.tryParse(t);
  if (err != null && err.isStandard) return Cell(value: err, style: style);

  final n = parseNumberText(t);
  if (n != null) {
    var s = style;
    if (s.numFmt == 'General') {
      final dot = t.indexOf('.');
      final decimals = dot < 0 ? 0 : t.replaceAll('%', '').length - dot - 1;
      final dec = decimals > 0 ? '.${'0' * decimals.clamp(0, 10)}' : '';
      if (t.endsWith('%')) {
        s = s.copyWith(numFmt: '0$dec%');
      } else if (t.contains(r'$')) {
        s = s.copyWith(numFmt: '"\$"#,##0${dec.isEmpty ? '' : dec}');
      } else if (t.contains(',')) {
        s = s.copyWith(numFmt: '#,##0$dec');
      }
    }
    return Cell(value: n, style: s);
  }
  final tm = _timeRe.firstMatch(t);
  if (tm != null) {
    var h = int.parse(tm[1]!);
    final m = int.parse(tm[2]!);
    final sec = int.tryParse(tm[3] ?? '') ?? 0;
    final ampm = tm[4]?.toUpperCase();
    if (ampm == 'PM' && h < 12) h += 12;
    if (ampm == 'AM' && h == 12) h = 0;
    if (h < 24 && m < 60 && sec < 60) {
      var s = style;
      if (s.numFmt == 'General') {
        s = s.copyWith(
            numFmt: ampm != null
                ? (tm[3] != null ? 'h:mm:ss AM/PM' : 'h:mm AM/PM')
                : (tm[3] != null ? 'h:mm:ss' : 'h:mm'));
      }
      return Cell(value: (h * 3600 + m * 60 + sec) / 86400, style: s);
    }
  }
  final d = parseDateText(t);
  if (d != null) {
    var s = style;
    final hasTime = d.hour != 0 || d.minute != 0 || d.second != 0;
    if (s.numFmt == 'General') {
      final iso = RegExp(r'^\d{4}-').hasMatch(t);
      final datePart = iso ? 'yyyy-mm-dd' : (t.contains('/') ? 'm/d/yyyy' : 'd-mmm-yyyy');
      s = s.copyWith(numFmt: hasTime ? '$datePart h:mm' : datePart);
    }
    return Cell(value: NumberFormats.dateTimeToSerial(d, date1904: date1904), style: s);
  }
  return Cell(value: text, style: style);
}

final _prefixRe = RegExp(r'^(_xlfn\.|_xlws\.|_xlpm\.)+', caseSensitive: false);

/// Turns typed formula text into the form stored in files: upper-cases
/// function names and references (`sum(a1)` -> `SUM(A1)`), accepts `;` as an
/// argument separator (written as `,`), drops the `@` implicit-intersection
/// marker and adds the `_xlfn.` prefixes Excel needs for newer functions.
String normalizeFormula(String f) {
  List<FToken> toks;
  try {
    toks = tokenizeFormula(f);
  } on FormulaSyntaxError {
    return f;
  }
  final b = StringBuffer();
  var pos = 0;
  var prevEnd = 0;
  var braces = 0;
  // Text between tokens is whitespace or `@` (which the tokenizer skips).
  void writeGap(int from, int to) {
    b.write(f.substring(pos, from));
    b.write(f.substring(from, to).replaceAll('@', ''));
    pos = to;
  }

  for (final t in toks) {
    final gapStart = prevEnd;
    prevEnd = t.end;
    String? rep;
    if (t.type == FTokType.func) {
      // Keep any file prefix lower-case like Excel writes it.
      final m = _prefixRe.firstMatch(t.text);
      rep = m == null
          ? t.text.toUpperCase()
          : '${m[0]!.toLowerCase()}${t.text.substring(m.end).toUpperCase()}';
    } else if (t.type == FTokType.ref) {
      rep = t.ref!.format();
    } else if (t.type == FTokType.boolean) {
      rep = t.text.toUpperCase();
    } else if (t.type == FTokType.lbrace) {
      braces++;
    } else if (t.type == FTokType.rbrace) {
      braces--;
    } else if (t.type == FTokType.comma && t.text == ';' && braces <= 0) {
      rep = ',';
    }
    final at = f.substring(gapStart, t.start).contains('@');
    if ((rep == null || rep == f.substring(t.start, t.end)) && !at) continue;
    writeGap(gapStart, t.start);
    b.write(rep ?? f.substring(t.start, t.end));
    pos = t.end;
  }
  if (f.substring(prevEnd).contains('@')) writeGap(prevEnd, f.length);
  var out = f;
  if (pos > 0) {
    b.write(f.substring(pos));
    out = b.toString();
  }
  return addFunctionPrefixes(out);
}

/// Formula text for the editor/formula bar (without file-only prefixes).
String formulaDisplayText(String formula) => '=${stripFunctionPrefixes(formula)}';

/// Text shown in the editor/formula bar for a cell.
String cellEditText(Cell? cell, {bool date1904 = false}) {
  if (cell == null) return '';
  if (cell.formula != null) return formulaDisplayText(cell.formula!);
  final v = cell.value;
  if (v == null) return '';
  if (v is String) {
    // Keep text that would otherwise be re-parsed as something else.
    if (v.isEmpty) return '';
    final probe = parseCellInput(v, CellStyle.plain, date1904: date1904);
    if (probe?.value is! String || v.startsWith('=') || v.startsWith("'")) return "'$v";
    return v;
  }
  if (v is bool) return v ? 'TRUE' : 'FALSE';
  if (v is CellError) return v.code;
  if (v is double) {
    final fmt = cell.style.numFmt;
    if (NumberFormats.isDateFormat(fmt)) {
      final dt = NumberFormats.serialToDateTime(v, date1904: date1904);
      if (dt != null) {
        final timeOnly = NumberFormats.isTimeOnlyFormat(fmt);
        final hasTime = dt.hour != 0 || dt.minute != 0 || dt.second != 0;
        String two(int n) => n.toString().padLeft(2, '0');
        final time = '${dt.hour}:${two(dt.minute)}${dt.second != 0 ? ':${two(dt.second)}' : ''}';
        if (timeOnly && v < 1) return time;
        final date = '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}';
        return hasTime ? '$date $time' : date;
      }
    }
    if (NumberFormats.isPercentFormat(fmt)) {
      return '${NumberFormats.numberToPlainString(double.parse((v * 100).toStringAsPrecision(15)))}%';
    }
    return NumberFormats.numberToPlainString(v);
  }
  return v.toString();
}
