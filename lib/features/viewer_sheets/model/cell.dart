/// Core cell types for the spreadsheet model.
///
/// Everything in `model/`, `readers/`, `writers/` and `formula/` is plain Dart
/// (no Flutter imports) so it can run inside `Isolate.run`.
library;

/// Excel's sheet limits.
const int kMaxRows = 1048576;
const int kMaxCols = 16384;

/// Packs a zero-based row/column into a single map key.
int cellKey(int row, int col) => row * kMaxCols + col;
int keyRow(int key) => key ~/ kMaxCols;
int keyCol(int key) => key % kMaxCols;

/// A spreadsheet error value such as `#DIV/0!`.
class CellError {
  const CellError(this.code);

  final String code;

  static const nullError = CellError('#NULL!');
  static const div0 = CellError('#DIV/0!');
  static const value = CellError('#VALUE!');
  static const ref = CellError('#REF!');
  static const name = CellError('#NAME?');
  static const num = CellError('#NUM!');
  static const na = CellError('#N/A');
  static const gettingData = CellError('#GETTING_DATA');

  /// Circular reference marker (app-only; never written as a cached value).
  static const circular = CellError('#CIRC!');

  static const standardCodes = <String>{
    '#NULL!',
    '#DIV/0!',
    '#VALUE!',
    '#REF!',
    '#NAME?',
    '#NUM!',
    '#N/A',
    '#GETTING_DATA',
  };

  /// True for the error codes Excel itself understands.
  bool get isStandard => standardCodes.contains(code);

  static CellError? tryParse(String text) {
    final t = text.trim().toUpperCase();
    if (standardCodes.contains(t) || t == '#CIRC!') return CellError(t);
    return null;
  }

  @override
  bool operator ==(Object other) => other is CellError && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

enum HAlign {
  general,
  left,
  center,
  right,
  fill,
  justify,
  centerContinuous,
  distributed,
}

enum VAlign { top, center, bottom, justify, distributed }

const Object _keep = Object();

/// Basic visual style of a cell. Immutable and value-comparable so equal
/// styles can be shared and de-duplicated by writers.
class CellStyle {
  const CellStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.wrap = false,
    this.fontColor,
    this.fillColor,
    this.fontSize,
    this.hAlign = HAlign.general,
    this.vAlign = VAlign.bottom,
    this.numFmt = 'General',
    this.baseXf,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool wrap;

  /// 0xAARRGGBB, null = automatic text colour.
  final int? fontColor;

  /// 0xAARRGGBB, null = no fill.
  final int? fillColor;

  /// Font size in points, null = default (11pt).
  final double? fontSize;
  final HAlign hAlign;
  final VAlign vAlign;

  /// Number format code (e.g. `0.00%`), `General` by default.
  final String numFmt;

  /// Index into the original xlsx `cellXfs` this style was read from. Lets the
  /// writer keep borders, fonts and other attributes this model doesn't track.
  final int? baseXf;

  static const plain = CellStyle();

  bool get isDefaultLook => sameLook(plain);

  /// Equality ignoring [baseXf].
  bool sameLook(CellStyle o) =>
      bold == o.bold &&
      italic == o.italic &&
      underline == o.underline &&
      strike == o.strike &&
      wrap == o.wrap &&
      fontColor == o.fontColor &&
      fillColor == o.fillColor &&
      fontSize == o.fontSize &&
      hAlign == o.hAlign &&
      vAlign == o.vAlign &&
      numFmt == o.numFmt;

  CellStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? wrap,
    Object? fontColor = _keep,
    Object? fillColor = _keep,
    Object? fontSize = _keep,
    HAlign? hAlign,
    VAlign? vAlign,
    String? numFmt,
    Object? baseXf = _keep,
  }) {
    return CellStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strike: strike ?? this.strike,
      wrap: wrap ?? this.wrap,
      fontColor: identical(fontColor, _keep) ? this.fontColor : fontColor as int?,
      fillColor: identical(fillColor, _keep) ? this.fillColor : fillColor as int?,
      fontSize: identical(fontSize, _keep) ? this.fontSize : fontSize as double?,
      hAlign: hAlign ?? this.hAlign,
      vAlign: vAlign ?? this.vAlign,
      numFmt: numFmt ?? this.numFmt,
      baseXf: identical(baseXf, _keep) ? this.baseXf : baseXf as int?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CellStyle && other.baseXf == baseXf && sameLook(other);

  @override
  int get hashCode => Object.hash(bold, italic, underline, strike, wrap,
      fontColor, fillColor, fontSize, hAlign, vAlign, numFmt, baseXf);
}

/// One cell. [value] is the constant value, or the cached/calculated result
/// when [formula] is set. Values are `null`, [String], [double], [bool] or
/// [CellError]. Dates are numbers (serials) with a date [CellStyle.numFmt].
class Cell {
  const Cell({this.value, this.formula, this.style = CellStyle.plain, this.arrayRef});

  final Object? value;

  /// Formula text without the leading `=`.
  final String? formula;
  final CellStyle style;

  /// For array (CSE) formulas, the range the array formula covers.
  final String? arrayRef;

  bool get hasFormula => formula != null;
  bool get isBlank => value == null && formula == null;
  bool get hasContent => !isBlank;

  Cell withValue(Object? v) =>
      Cell(value: v, formula: formula, style: style, arrayRef: arrayRef);

  Cell withStyle(CellStyle s) =>
      Cell(value: value, formula: formula, style: s, arrayRef: arrayRef);

  Cell withFormula(String? f, Object? v) =>
      Cell(value: v, formula: f, style: style);
}

/// A rectangular, normalised range of cells (inclusive bounds, zero-based).
class CellRange {
  const CellRange._(this.r1, this.c1, this.r2, this.c2);

  factory CellRange(int ra, int ca, int rb, int cb) => CellRange._(
        ra < rb ? ra : rb,
        ca < cb ? ca : cb,
        ra < rb ? rb : ra,
        ca < cb ? cb : ca,
      );

  factory CellRange.single(int r, int c) => CellRange._(r, c, r, c);

  final int r1;
  final int c1;
  final int r2;
  final int c2;

  int get rowCount => r2 - r1 + 1;
  int get colCount => c2 - c1 + 1;
  int get area => rowCount * colCount;
  bool get isSingle => r1 == r2 && c1 == c2;

  bool contains(int r, int c) => r >= r1 && r <= r2 && c >= c1 && c <= c2;

  bool containsRange(CellRange o) =>
      o.r1 >= r1 && o.r2 <= r2 && o.c1 >= c1 && o.c2 <= c2;

  bool intersects(CellRange o) =>
      !(o.r1 > r2 || o.r2 < r1 || o.c1 > c2 || o.c2 < c1);

  CellRange union(CellRange o) => CellRange._(
        r1 < o.r1 ? r1 : o.r1,
        c1 < o.c1 ? c1 : o.c1,
        r2 > o.r2 ? r2 : o.r2,
        c2 > o.c2 ? c2 : o.c2,
      );

  String toA1() =>
      isSingle ? cellName(r1, c1) : '${cellName(r1, c1)}:${cellName(r2, c2)}';

  /// Parses `A1` or `A1:B2` (with optional `$`).
  static CellRange? parse(String text) {
    final parts = text.trim().split(':');
    if (parts.isEmpty || parts.length > 2) return null;
    final a = parseCellName(parts[0]);
    if (a == null) return null;
    if (parts.length == 1) return CellRange.single(a.$1, a.$2);
    final b = parseCellName(parts[1]);
    if (b == null) return null;
    return CellRange(a.$1, a.$2, b.$1, b.$2);
  }

  @override
  bool operator ==(Object other) =>
      other is CellRange &&
      other.r1 == r1 &&
      other.c1 == c1 &&
      other.r2 == r2 &&
      other.c2 == c2;

  @override
  int get hashCode => Object.hash(r1, c1, r2, c2);

  @override
  String toString() => toA1();
}

/// `0 -> A`, `25 -> Z`, `26 -> AA`.
String columnName(int col) {
  var n = col + 1;
  final codes = <int>[];
  while (n > 0) {
    final rem = (n - 1) % 26;
    codes.add(65 + rem);
    n = (n - 1) ~/ 26;
  }
  return String.fromCharCodes(codes.reversed);
}

/// `A -> 0`; returns null for invalid letters.
int? columnIndex(String letters) {
  if (letters.isEmpty || letters.length > 3) return null;
  var n = 0;
  for (final u in letters.toUpperCase().codeUnits) {
    if (u < 65 || u > 90) return null;
    n = n * 26 + (u - 64);
  }
  final idx = n - 1;
  return idx < kMaxCols ? idx : null;
}

String cellName(int row, int col, {bool absRow = false, bool absCol = false}) =>
    '${absCol ? r'$' : ''}${columnName(col)}${absRow ? r'$' : ''}${row + 1}';

final _cellNameRe = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d{1,7})$');

/// Parses `B12` / `$B$12` into zero-based (row, col).
(int, int)? parseCellName(String text) {
  final m = _cellNameRe.firstMatch(text.trim());
  if (m == null) return null;
  final col = columnIndex(m.group(1)!);
  final row = int.parse(m.group(2)!) - 1;
  if (col == null || row < 0 || row >= kMaxRows) return null;
  return (row, col);
}
