import '../model/cell.dart';

enum FTokType {
  number,
  string,
  boolean,
  error,
  ref,
  func,
  name,
  op,
  lparen,
  rparen,
  comma,
  lbrace,
  rbrace,
  unknown,
}

enum RefKind { cell, area, cols, rows }

/// A parsed reference (`A1`, `$A$1:B2`, `A:C`, `1:3`, with optional sheet).
class RefInfo {
  RefInfo({
    required this.kind,
    this.sheet,
    this.r1 = 0,
    this.c1 = 0,
    this.r2 = 0,
    this.c2 = 0,
    this.absR1 = false,
    this.absC1 = false,
    this.absR2 = false,
    this.absC2 = false,
  });

  RefKind kind;

  /// Unquoted sheet name or null for the formula's own sheet.
  String? sheet;
  int r1;
  int c1;
  int r2;
  int c2;
  bool absR1;
  bool absC1;
  bool absR2;
  bool absC2;

  RefInfo copy() => RefInfo(
        kind: kind,
        sheet: sheet,
        r1: r1,
        c1: c1,
        r2: r2,
        c2: c2,
        absR1: absR1,
        absC1: absC1,
        absR2: absR2,
        absC2: absC2,
      );

  /// Resolved bounds (whole rows/columns expand to the sheet limits).
  int get top => kind == RefKind.cols ? 0 : r1;
  int get bottom => kind == RefKind.cols ? kMaxRows - 1 : (kind == RefKind.cell ? r1 : r2);
  int get left => kind == RefKind.rows ? 0 : c1;
  int get right => kind == RefKind.rows ? kMaxCols - 1 : (kind == RefKind.cell ? c1 : c2);

  String format() {
    final prefix = sheet == null ? '' : '${quoteSheetName(sheet!)}!';
    String cellPart(int r, int c, bool ar, bool ac) =>
        '${ac ? r'$' : ''}${columnName(c)}${ar ? r'$' : ''}${r + 1}';
    switch (kind) {
      case RefKind.cell:
        return '$prefix${cellPart(r1, c1, absR1, absC1)}';
      case RefKind.area:
        return '$prefix${cellPart(r1, c1, absR1, absC1)}:${cellPart(r2, c2, absR2, absC2)}';
      case RefKind.cols:
        return '$prefix${absC1 ? r'$' : ''}${columnName(c1)}:${absC2 ? r'$' : ''}${columnName(c2)}';
      case RefKind.rows:
        return '$prefix${absR1 ? r'$' : ''}${r1 + 1}:${absR2 ? r'$' : ''}${r2 + 1}';
    }
  }
}

final _plainSheetName = RegExp(r'^[A-Za-z_À-￿][A-Za-z0-9_.À-￿]*$');
final _looksLikeRef = RegExp(r'^(\$?[A-Za-z]{1,3}\$?\d+|R\d*C\d*|[A-Za-z]{1,3}|\d+)$', caseSensitive: false);

/// Quotes a sheet name for use in a formula when needed.
String quoteSheetName(String name) {
  if (_plainSheetName.hasMatch(name) &&
      !_looksLikeRef.hasMatch(name) &&
      name.toUpperCase() != 'TRUE' &&
      name.toUpperCase() != 'FALSE') {
    return name;
  }
  return "'${name.replaceAll("'", "''")}'";
}

class FToken {
  FToken(this.type, this.text, this.start, this.end, {this.ref});

  final FTokType type;
  final String text;
  final int start;
  final int end;
  final RefInfo? ref;

  bool isOp(String s) => type == FTokType.op && text == s;

  @override
  String toString() => '$type($text)';
}

class FormulaSyntaxError implements Exception {
  FormulaSyntaxError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _errorLiterals = [
  '#DIV/0!',
  '#N/A',
  '#NAME?',
  '#NULL!',
  '#NUM!',
  '#REF!',
  '#VALUE!',
  '#GETTING_DATA',
  '#CIRC!',
];

final _cellRe = RegExp(r'^(\$?)([A-Za-z]{1,3})(\$?)(\d+)$');
final _colRe = RegExp(r'^(\$?)([A-Za-z]{1,3})$');
final _rowRe = RegExp(r'^(\$?)(\d+)$');
final _numRe = RegExp(r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?');

bool _isDelimiter(int u) {
  // whitespace and operator characters end a word
  const delims = ' \t\r\n+-*/^&=<>%(),;:{}!"\'#@[]';
  return delims.codeUnits.contains(u);
}

/// Splits a formula (without the leading `=`) into tokens.
List<FToken> tokenizeFormula(String src) {
  final out = <FToken>[];
  var i = 0;
  final n = src.length;

  String readWord(int from) {
    var j = from;
    while (j < n && !_isDelimiter(src.codeUnitAt(j))) {
      j++;
    }
    return src.substring(from, j);
  }

  // Parses a reference starting at [pos]; returns (RefInfo, endPos) or null.
  (RefInfo, int)? parseRefAt(int pos, String? sheet) {
    final w1 = readWord(pos);
    if (w1.isEmpty) return null;
    var p = pos + w1.length;
    final cm = _cellRe.firstMatch(w1);
    if (cm != null) {
      final c = columnIndex(cm.group(2)!);
      final r = int.tryParse(cm.group(4)!);
      if (c == null || r == null || r < 1 || r > kMaxRows) return null;
      if (p < n && src[p] == '(') return null; // function like LOG10(
      final info = RefInfo(
        kind: RefKind.cell,
        sheet: sheet,
        r1: r - 1,
        c1: c,
        absC1: cm.group(1)!.isNotEmpty,
        absR1: cm.group(3)!.isNotEmpty,
      );
      if (p < n && src[p] == ':') {
        final w2 = readWord(p + 1);
        final cm2 = _cellRe.firstMatch(w2);
        if (cm2 != null) {
          final c2 = columnIndex(cm2.group(2)!);
          final r2 = int.tryParse(cm2.group(4)!);
          if (c2 != null && r2 != null && r2 >= 1 && r2 <= kMaxRows) {
            info
              ..kind = RefKind.area
              ..r2 = r2 - 1
              ..c2 = c2
              ..absC2 = cm2.group(1)!.isNotEmpty
              ..absR2 = cm2.group(3)!.isNotEmpty;
            p = p + 1 + w2.length;
          }
        }
      }
      return (info, p);
    }
    if (p < n && src[p] == ':') {
      final w2 = readWord(p + 1);
      final col1 = _colRe.firstMatch(w1);
      final col2 = _colRe.firstMatch(w2);
      if (col1 != null && col2 != null) {
        final a = columnIndex(col1.group(2)!);
        final b = columnIndex(col2.group(2)!);
        if (a != null && b != null) {
          return (
            RefInfo(
              kind: RefKind.cols,
              sheet: sheet,
              c1: a,
              c2: b,
              absC1: col1.group(1)!.isNotEmpty,
              absC2: col2.group(1)!.isNotEmpty,
            ),
            p + 1 + w2.length
          );
        }
      }
      final row1 = _rowRe.firstMatch(w1);
      final row2 = _rowRe.firstMatch(w2);
      if (row1 != null && row2 != null) {
        final a = int.parse(row1.group(2)!);
        final b = int.parse(row2.group(2)!);
        if (a >= 1 && b >= 1 && a <= kMaxRows && b <= kMaxRows) {
          return (
            RefInfo(
              kind: RefKind.rows,
              sheet: sheet,
              r1: a - 1,
              r2: b - 1,
              absR1: row1.group(1)!.isNotEmpty,
              absR2: row2.group(1)!.isNotEmpty,
            ),
            p + 1 + w2.length
          );
        }
      }
    }
    return null;
  }

  while (i < n) {
    final ch = src[i];
    final u = src.codeUnitAt(i);
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '@') {
      i++;
      continue;
    }
    if (ch == '"') {
      final b = StringBuffer();
      var j = i + 1;
      var closed = false;
      while (j < n) {
        if (src[j] == '"') {
          if (j + 1 < n && src[j + 1] == '"') {
            b.write('"');
            j += 2;
            continue;
          }
          closed = true;
          j++;
          break;
        }
        b.write(src[j]);
        j++;
      }
      if (!closed) throw FormulaSyntaxError('Missing closing quote');
      out.add(FToken(FTokType.string, b.toString(), i, j));
      i = j;
      continue;
    }
    if (ch == '#') {
      final upper = src.substring(i).toUpperCase();
      String? lit;
      for (final e in _errorLiterals) {
        if (upper.startsWith(e)) {
          lit = e;
          break;
        }
      }
      if (lit == null) throw FormulaSyntaxError('Unknown error literal');
      out.add(FToken(FTokType.error, lit, i, i + lit.length));
      i += lit.length;
      continue;
    }
    if (ch == "'") {
      // Quoted sheet name.
      final b = StringBuffer();
      var j = i + 1;
      var closed = false;
      while (j < n) {
        if (src[j] == "'") {
          if (j + 1 < n && src[j + 1] == "'") {
            b.write("'");
            j += 2;
            continue;
          }
          closed = true;
          j++;
          break;
        }
        b.write(src[j]);
        j++;
      }
      if (!closed || j >= n || src[j] != '!') {
        throw FormulaSyntaxError('Invalid sheet reference');
      }
      final r = parseRefAt(j + 1, b.toString());
      if (r == null) {
        // Sheet-scoped name or invalid ref.
        final w = readWord(j + 1);
        out.add(FToken(FTokType.name, src.substring(i, j + 1 + w.length), i, j + 1 + w.length));
        i = j + 1 + w.length;
        continue;
      }
      out.add(FToken(FTokType.ref, src.substring(i, r.$2), i, r.$2, ref: r.$1));
      i = r.$2;
      continue;
    }
    if (ch == '[') {
      // External workbook reference: [1]Sheet1!A1 -> unsupported name.
      final close = src.indexOf(']', i);
      if (close < 0) throw FormulaSyntaxError('Invalid reference');
      var j = close + 1;
      while (j < n && !_isDelimiter(src.codeUnitAt(j))) {
        j++;
      }
      if (j < n && src[j] == '!') {
        j++;
        while (j < n && (!_isDelimiter(src.codeUnitAt(j)) || src[j] == ':')) {
          j++;
        }
      }
      out.add(FToken(FTokType.name, src.substring(i, j), i, j));
      i = j;
      continue;
    }
    // Numbers (or row ranges like 1:3).
    if ((u >= 48 && u <= 57) || (ch == '.' && i + 1 < n && RegExp(r'\d').hasMatch(src[i + 1]))) {
      final r = parseRefAt(i, null);
      if (r != null && r.$1.kind == RefKind.rows) {
        out.add(FToken(FTokType.ref, src.substring(i, r.$2), i, r.$2, ref: r.$1));
        i = r.$2;
        continue;
      }
      final m = _numRe.matchAsPrefix(src, i);
      if (m == null) throw FormulaSyntaxError('Invalid number');
      out.add(FToken(FTokType.number, m.group(0)!, i, m.end));
      i = m.end;
      continue;
    }
    if (ch == r'$' || !_isDelimiter(u)) {
      final word = readWord(i);
      final end = i + word.length;
      if (end < n && src[end] == '!') {
        final r = parseRefAt(end + 1, word);
        if (r != null) {
          out.add(FToken(FTokType.ref, src.substring(i, r.$2), i, r.$2, ref: r.$1));
          i = r.$2;
          continue;
        }
        final w2 = readWord(end + 1);
        out.add(FToken(FTokType.name, src.substring(i, end + 1 + w2.length), i, end + 1 + w2.length));
        i = end + 1 + w2.length;
        continue;
      }
      if (end < n && src[end] == '(') {
        out.add(FToken(FTokType.func, word, i, end));
        i = end;
        continue;
      }
      final r = parseRefAt(i, null);
      if (r != null) {
        out.add(FToken(FTokType.ref, src.substring(i, r.$2), i, r.$2, ref: r.$1));
        i = r.$2;
        continue;
      }
      final upper = word.toUpperCase();
      if (upper == 'TRUE' || upper == 'FALSE') {
        out.add(FToken(FTokType.boolean, upper, i, end));
      } else {
        out.add(FToken(FTokType.name, word, i, end));
      }
      i = end;
      continue;
    }
    // Operators and punctuation.
    if (i + 1 < n) {
      final two = src.substring(i, i + 2);
      if (two == '<=' || two == '>=' || two == '<>') {
        out.add(FToken(FTokType.op, two, i, i + 2));
        i += 2;
        continue;
      }
    }
    switch (ch) {
      case '+':
      case '-':
      case '*':
      case '/':
      case '^':
      case '&':
      case '=':
      case '<':
      case '>':
      case '%':
      case ':':
        out.add(FToken(FTokType.op, ch, i, i + 1));
      case '(':
        out.add(FToken(FTokType.lparen, ch, i, i + 1));
      case ')':
        out.add(FToken(FTokType.rparen, ch, i, i + 1));
      case ',':
      case ';':
        out.add(FToken(FTokType.comma, ch, i, i + 1));
      case '{':
        out.add(FToken(FTokType.lbrace, ch, i, i + 1));
      case '}':
        out.add(FToken(FTokType.rbrace, ch, i, i + 1));
      default:
        throw FormulaSyntaxError('Unexpected "$ch"');
    }
    i++;
  }
  return out;
}

/// Function names as written in files may carry `_xlfn.` style prefixes.
String normalizeFunctionName(String name) {
  var n = name.toUpperCase();
  for (final p in const ['_XLFN._XLWS.', '_XLFN.', '_XLWS.', '_XLL.', 'COM.MICROSOFT.']) {
    if (n.startsWith(p)) n = n.substring(p.length);
  }
  return n;
}

/// Removes `_xlfn.`/`_xlws.` prefixes from formula text read from files.
String stripFunctionPrefixes(String formula) {
  if (!formula.contains('_xl')) return formula;
  return formula.replaceAll(RegExp(r'_xlfn\.(_xlws\.)?|_xlws\.', caseSensitive: false), '');
}

/// Functions newer than Excel 2007 that must be stored with `_xlfn.`.
const futureFunctions = <String>{
  'CONCAT', 'TEXTJOIN', 'IFS', 'MAXIFS', 'MINIFS', 'SWITCH', 'XLOOKUP', //
  'XMATCH', 'IFNA', 'DAYS', 'ISOWEEKNUM', 'STDEV.S', 'STDEV.P', 'VAR.S',
  'VAR.P', 'MODE.SNGL', 'PERCENTILE.INC', 'PERCENTILE.EXC', 'QUARTILE.INC',
  'QUARTILE.EXC', 'RANK.EQ', 'RANK.AVG', 'CEILING.MATH', 'FLOOR.MATH',
  'AGGREGATE', 'UNIQUE', 'SORT', 'SORTBY', 'FILTER', 'SEQUENCE', 'RANDARRAY',
  'LET', 'NUMBERVALUE', 'FORMULATEXT', 'SHEET', 'SHEETS', 'XOR',
};

/// Adds `_xlfn.` prefixes for functions Excel stores that way.
String addFunctionPrefixes(String formula) {
  List<FToken> toks;
  try {
    toks = tokenizeFormula(formula);
  } on FormulaSyntaxError {
    return formula;
  }
  final b = StringBuffer();
  var pos = 0;
  for (final t in toks) {
    if (t.type != FTokType.func) continue;
    final upper = t.text.toUpperCase();
    if (!futureFunctions.contains(upper)) continue;
    b.write(formula.substring(pos, t.start));
    final ws = upper == 'SORT' || upper == 'FILTER' ? '_xlws.' : '';
    b.write('_xlfn.$ws${t.text}');
    pos = t.end;
  }
  if (pos == 0) return formula;
  b.write(formula.substring(pos));
  return b.toString();
}
