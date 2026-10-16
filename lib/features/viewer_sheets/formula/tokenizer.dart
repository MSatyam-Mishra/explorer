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

/// Matches `$?[A-Za-z]{1,3}$?\d+` (what a regular expression did before,
/// without its cost on every word): (absolute column, column index or -1
/// when past the last column, absolute row, 1-based row capped above the
/// sheet size), or null.
(bool, int, bool, int)? _matchCell(String w) {
  final n = w.length;
  var i = 0;
  var absC = false;
  if (i < n && w.codeUnitAt(i) == 0x24) {
    absC = true;
    i++;
  }
  final ls = i;
  var col = 0;
  while (i < n) {
    final u = w.codeUnitAt(i) | 0x20; // lower-case letters
    if (u < 0x61 || u > 0x7A) break;
    col = col * 26 + (u - 0x60);
    i++;
  }
  final letters = i - ls;
  if (letters < 1 || letters > 3) return null;
  var absR = false;
  if (i < n && w.codeUnitAt(i) == 0x24) {
    absR = true;
    i++;
  }
  final ds = i;
  var row = 0;
  for (; i < n; i++) {
    final u = w.codeUnitAt(i);
    if (u < 0x30 || u > 0x39) return null;
    if (row <= kMaxRows) row = row * 10 + (u - 0x30);
  }
  if (i == ds) return null;
  return (absC, col - 1 < kMaxCols ? col - 1 : -1, absR, row);
}
final _colRe = RegExp(r'^(\$?)([A-Za-z]{1,3})$');
final _rowRe = RegExp(r'^(\$?)(\d+)$');
final _numRe = RegExp(r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?');

// Whitespace and operator characters end a word.
final List<bool> _delimiterTable = () {
  final t = List<bool>.filled(128, false);
  for (final u in ' \t\r\n+-*/^&=<>%(),;:{}!"\'#@[]'.codeUnits) {
    t[u] = true;
  }
  return t;
}();

bool _isDelimiter(int u) => u < 128 && _delimiterTable[u];

/// Index of the `]` closing the bracket at [from] (nested brackets allowed,
/// `'` escapes the next character as in structured references), or -1.
int _matchBracket(String src, int from) {
  var depth = 0;
  for (var j = from; j < src.length; j++) {
    final u = src.codeUnitAt(j);
    if (u == 0x27) {
      j++;
    } else if (u == 0x5B) {
      depth++;
    } else if (u == 0x5D) {
      depth--;
      if (depth == 0) return j;
    }
  }
  return -1;
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
    final cm = _matchCell(w1);
    if (cm != null) {
      final (absC, c, absR, r) = cm;
      if (c < 0 || r < 1 || r > kMaxRows) return null;
      if (p < n && src[p] == '(') return null; // function like LOG10(
      final info = RefInfo(
        kind: RefKind.cell,
        sheet: sheet,
        r1: r - 1,
        c1: c,
        absC1: absC,
        absR1: absR,
      );
      if (p < n && src[p] == ':') {
        final w2 = readWord(p + 1);
        final cm2 = _matchCell(w2);
        if (cm2 != null) {
          final (absC2, c2, absR2, r2) = cm2;
          if (c2 >= 0 && r2 >= 1 && r2 <= kMaxRows) {
            info
              ..kind = RefKind.area
              ..r2 = r2 - 1
              ..c2 = c2
              ..absC2 = absC2
              ..absR2 = absR2;
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
      // External workbook reference ([1]Sheet1!A1) or a structured reference
      // without a table name ([@Qty], [[#This Row],[Qty]]) -> unsupported name.
      final close = _matchBracket(src, i);
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
    if ((u >= 48 && u <= 57) ||
        (ch == '.' && i + 1 < n && src.codeUnitAt(i + 1) >= 48 && src.codeUnitAt(i + 1) <= 57)) {
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
      if (end < n && src[end] == '[') {
        // Structured reference: Table1[Qty], Table1[[#This Row],[Qty]]
        // (but not an external reference like [1]Sheet1!A1).
        final close = _matchBracket(src, end);
        if (close < 0) throw FormulaSyntaxError('Invalid reference');
        var j = close + 1;
        while (j < n && !_isDelimiter(src.codeUnitAt(j))) {
          j++;
        }
        if (j >= n || src[j] != '!') {
          out.add(FToken(FTokType.name, src.substring(i, close + 1), i, close + 1));
          i = close + 1;
          continue;
        }
      }
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

final _filePrefix = RegExp(r'^(_xlfn\.|_xlws\.|_xlpm\.)+', caseSensitive: false);

/// Formula text as shown to the user: the `_xlfn.`/`_xlws.`/`_xlpm.`
/// prefixes Excel stores in files are removed. [Cell.formula] keeps the file
/// form; [addFunctionPrefixes] puts them back for edited formulas.
String stripFunctionPrefixes(String formula) {
  if (!formula.contains('_xl') && !formula.contains('_XL')) return formula;
  List<FToken> toks;
  try {
    toks = tokenizeFormula(formula);
  } on FormulaSyntaxError {
    return formula;
  }
  final b = StringBuffer();
  var pos = 0;
  for (final t in toks) {
    if (t.type != FTokType.func && t.type != FTokType.name) continue;
    final m = _filePrefix.firstMatch(t.text);
    if (m == null) continue;
    b.write(formula.substring(pos, t.start));
    b.write(t.text.substring(m.end));
    pos = t.end;
  }
  if (pos == 0) return formula;
  b.write(formula.substring(pos));
  return b.toString();
}

/// Functions added after Excel 2007, which files must store with `_xlfn.`
/// (Excel shows #NAME? otherwise). ISO.CEILING, ECMA.CEILING,
/// NETWORKDAYS.INTL and WORKDAY.INTL are 2007 built-ins and stay bare.
const futureFunctions = <String>{
  // Excel 2010
  'AGGREGATE', 'BETA.DIST', 'BETA.INV', 'BINOM.DIST', 'BINOM.INV', //
  'CEILING.PRECISE', 'CHISQ.DIST', 'CHISQ.DIST.RT', 'CHISQ.INV', 'CHISQ.INV.RT',
  'CHISQ.TEST', 'CONFIDENCE.NORM', 'CONFIDENCE.T', 'COVARIANCE.P',
  'COVARIANCE.S', 'ERF.PRECISE', 'ERFC.PRECISE', 'EXPON.DIST', 'F.DIST',
  'F.DIST.RT', 'F.INV', 'F.INV.RT', 'F.TEST', 'FLOOR.PRECISE', 'GAMMA.DIST',
  'GAMMA.INV', 'GAMMALN.PRECISE', 'HYPGEOM.DIST', 'LOGNORM.DIST',
  'LOGNORM.INV', 'MODE.MULT', 'MODE.SNGL', 'NEGBINOM.DIST', 'NORM.DIST',
  'NORM.INV', 'NORM.S.DIST', 'NORM.S.INV', 'PERCENTILE.EXC', 'PERCENTILE.INC',
  'PERCENTRANK.EXC', 'PERCENTRANK.INC', 'POISSON.DIST', 'QUARTILE.EXC',
  'QUARTILE.INC', 'RANK.AVG', 'RANK.EQ', 'STDEV.P', 'STDEV.S', 'T.DIST',
  'T.DIST.2T', 'T.DIST.RT', 'T.INV', 'T.INV.2T', 'T.TEST', 'VAR.P', 'VAR.S',
  'WEIBULL.DIST', 'Z.TEST',
  // Excel 2013
  'ACOT', 'ACOTH', 'ARABIC', 'BASE', 'BINOM.DIST.RANGE', 'BITAND', //
  'BITLSHIFT', 'BITOR', 'BITRSHIFT', 'BITXOR', 'CEILING.MATH', 'COMBINA', 'COT',
  'COTH', 'CSC', 'CSCH', 'DAYS', 'DECIMAL', 'ENCODEURL', 'FILTERXML',
  'FLOOR.MATH', 'FORMULATEXT', 'GAMMA', 'GAUSS', 'IFNA', 'IMCOSH', 'IMCOT',
  'IMCSC', 'IMCSCH', 'IMSEC', 'IMSECH', 'IMSINH', 'IMTAN', 'ISFORMULA',
  'ISOWEEKNUM', 'MUNIT', 'NUMBERVALUE', 'PDURATION', 'PERMUTATIONA', 'PHI',
  'QUERYSTRING', 'RRI', 'SEC', 'SECH', 'SHEET', 'SHEETS', 'SKEW.P', 'UNICHAR',
  'UNICODE', 'WEBSERVICE', 'XOR',
  // Excel 2016 / 2019
  'CONCAT', 'FORECAST.ETS', 'FORECAST.ETS.CONFINT', //
  'FORECAST.ETS.SEASONALITY', 'FORECAST.ETS.STAT', 'FORECAST.LINEAR', 'IFS',
  'MAXIFS', 'MINIFS', 'SWITCH', 'TEXTJOIN',
  // Excel 2021 / Microsoft 365
  'ANCHORARRAY', 'ARRAYTOTEXT', 'BYCOL', 'BYROW', 'CHOOSECOLS', //
  'CHOOSEROWS', 'DETECTLANGUAGE', 'DROP', 'EXPAND', 'FIELDVALUE', 'FILTER',
  'GROUPBY', 'HSTACK', 'IMAGE', 'ISOMITTED', 'LAMBDA', 'LET', 'MAKEARRAY',
  'MAP', 'PERCENTOF', 'PIVOTBY', 'RANDARRAY', 'REDUCE', 'REGEXEXTRACT',
  'REGEXREPLACE', 'REGEXTEST', 'SCAN', 'SEQUENCE', 'SINGLE', 'SORT', 'SORTBY',
  'STOCKHISTORY', 'TAKE', 'TEXTAFTER', 'TEXTBEFORE', 'TEXTSPLIT', 'TOCOL',
  'TOROW', 'TRANSLATE', 'TRIMRANGE', 'UNIQUE', 'VALUETOTEXT', 'VSTACK',
  'WRAPCOLS', 'WRAPROWS', 'XLOOKUP', 'XMATCH',
};

/// Names declared as LET/LAMBDA parameters in [toks] (upper case, without
/// `_xlpm.`), which files store as `_xlpm.name`.
Set<String> _lambdaParams(List<FToken> toks) {
  final out = <String>{};
  // Per open parenthesis: (function, argument index, single-name candidates).
  final stack = <(String?, List<int>, List<(int, String)>)>[];
  FToken? argFirst;
  var argTokens = 0;
  void endArg() {
    if (stack.isEmpty) return;
    final f = stack.last;
    if (argTokens == 1 && argFirst?.type == FTokType.name) {
      f.$3.add((f.$2[0], normalizeFunctionName(argFirst!.text.replaceFirst(_filePrefix, ''))));
    }
    f.$2[0]++;
  }

  for (var i = 0; i < toks.length; i++) {
    final t = toks[i];
    if (t.type == FTokType.lparen) {
      final prev = i > 0 && toks[i - 1].type == FTokType.func ? normalizeFunctionName(toks[i - 1].text) : null;
      stack.add((prev, [0], []));
      argFirst = null;
      argTokens = 0;
      continue;
    }
    if (t.type == FTokType.comma && stack.isNotEmpty) {
      endArg();
      argFirst = null;
      argTokens = 0;
      continue;
    }
    if (t.type == FTokType.rparen && stack.isNotEmpty) {
      endArg();
      final f = stack.removeLast();
      final last = f.$2[0] - 1;
      for (final (idx, name) in f.$3) {
        if (f.$1 == 'LAMBDA' && idx < last) out.add(name);
        if (f.$1 == 'LET' && idx.isEven && idx < last) out.add(name);
      }
      // The call itself counts as one token of the enclosing argument.
      argFirst = null;
      argTokens = 2;
      continue;
    }
    if (t.type == FTokType.func) continue; // counted with its parentheses
    argFirst ??= t;
    argTokens++;
  }
  return out;
}

/// Adds the `_xlfn.` (and `_xlws.`/`_xlpm.`) prefixes Excel expects in files.
/// Idempotent: names that already carry a prefix are left alone.
String addFunctionPrefixes(String formula) {
  if (!formula.contains('(')) return formula; // no function calls
  List<FToken> toks;
  try {
    toks = tokenizeFormula(formula);
  } on FormulaSyntaxError {
    return _addPrefixesFallback(formula);
  }
  final params = (formula.contains('(') && (formula.toUpperCase().contains('LET') ||
          formula.toUpperCase().contains('LAMBDA')))
      ? _lambdaParams(toks)
      : const <String>{};
  final b = StringBuffer();
  var pos = 0;
  for (final t in toks) {
    if (t.type != FTokType.func && t.type != FTokType.name) continue;
    if (_filePrefix.hasMatch(t.text)) continue;
    final upper = t.text.toUpperCase();
    String? rep;
    if (params.contains(upper)) {
      rep = '_xlpm.${t.text}';
    } else if (t.type == FTokType.func && futureFunctions.contains(upper)) {
      final ws = upper == 'SORT' || upper == 'FILTER' ? '_xlws.' : '';
      rep = '_xlfn.$ws${t.text}';
    }
    if (rep == null) continue;
    b.write(formula.substring(pos, t.start));
    b.write(rep);
    pos = t.end;
  }
  if (pos == 0) return formula;
  b.write(formula.substring(pos));
  return b.toString();
}

/// Gives function calls in [formula] the file prefixes the same functions
/// carry in [original] (the formula before an edit), so functions newer than
/// [futureFunctions] keep their `_xlfn.` when a cell is edited.
String carryFunctionPrefixes(String formula, String original) {
  if (!original.contains('_xl') && !original.contains('_XL')) return formula;
  final prefixes = <String, String>{};
  try {
    for (final t in tokenizeFormula(original)) {
      if (t.type != FTokType.func) continue;
      final m = _filePrefix.firstMatch(t.text);
      if (m != null) prefixes[t.text.substring(m.end).toUpperCase()] = m[0]!.toLowerCase();
    }
  } on FormulaSyntaxError {
    return formula;
  }
  if (prefixes.isEmpty) return formula;
  List<FToken> toks;
  try {
    toks = tokenizeFormula(formula);
  } on FormulaSyntaxError {
    return formula;
  }
  final b = StringBuffer();
  var pos = 0;
  for (final t in toks) {
    if (t.type != FTokType.func || _filePrefix.hasMatch(t.text)) continue;
    final p = prefixes[t.text.toUpperCase()];
    if (p == null) continue;
    b.write(formula.substring(pos, t.start));
    b.write('$p${t.text}');
    pos = t.end;
  }
  if (pos == 0) return formula;
  b.write(formula.substring(pos));
  return b.toString();
}

/// Prefixes future function calls in text the tokenizer rejects (skipping
/// string literals, quoted names and bracketed parts).
String _addPrefixesFallback(String formula) {
  final b = StringBuffer();
  var i = 0;
  final n = formula.length;
  bool wordChar(int u) =>
      (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x2E || u == 0x5F;
  while (i < n) {
    final u = formula.codeUnitAt(i);
    if (u == 0x22 || u == 0x27) {
      var j = i + 1;
      while (j < n) {
        if (formula.codeUnitAt(j) == u) {
          if (j + 1 < n && formula.codeUnitAt(j + 1) == u) {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      final end = j < n ? j + 1 : n;
      b.write(formula.substring(i, end));
      i = end;
      continue;
    }
    if (u == 0x5B) {
      final close = _matchBracket(formula, i);
      final end = close < 0 ? n : close + 1;
      b.write(formula.substring(i, end));
      i = end;
      continue;
    }
    if (wordChar(u)) {
      var j = i;
      while (j < n && wordChar(formula.codeUnitAt(j))) {
        j++;
      }
      final word = formula.substring(i, j);
      final upper = word.toUpperCase();
      if (j < n && formula.codeUnitAt(j) == 0x28 && futureFunctions.contains(upper)) {
        b.write(upper == 'SORT' || upper == 'FILTER' ? '_xlfn._xlws.' : '_xlfn.');
      }
      b.write(word);
      i = j;
      continue;
    }
    b.writeCharCode(u);
    i++;
  }
  return b.toString();
}
