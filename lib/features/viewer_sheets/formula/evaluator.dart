import 'dart:math' as math;

import '../model/number_format.dart';
import '../model/workbook.dart';
import 'functions.dart';
import 'parser.dart';
import 'tokenizer.dart';

/// A reference to a block of cells, produced by evaluating reference nodes.
class RangeValue {
  const RangeValue(this.sheet, this.r1, this.c1, this.r2, this.c2);

  final SheetData sheet;
  final int r1;
  final int c1;
  final int r2;
  final int c2;

  int get rows => r2 - r1 + 1;
  int get cols => c2 - c1 + 1;
  bool get isSingle => r1 == r2 && c1 == c2;

  bool contains(int r, int c) => r >= r1 && r <= r2 && c >= c1 && c <= c2;

  /// Last row that can contain data (clamped to the used area).
  int get usedR2 => math.min(r2, sheet.usedRows - 1);
  int get usedC2 => math.min(c2, sheet.usedCols - 1);
}

/// A constant or computed array (e.g. `{1,2,3}`).
class ArrayValue {
  const ArrayValue(this.rows);
  final List<List<Object?>> rows;
}

/// Thrown inside function implementations to produce an error value.
class FormulaException implements Exception {
  const FormulaException(this.error);
  final CellError error;
}

/// Thrown when the formula uses something this engine can't evaluate (an
/// unknown function, a defined name...). The cell keeps its cached value.
class UnsupportedFormula implements Exception {
  const UnsupportedFormula(this.reason);
  final String reason;
}

const Object _keepCached = Object();

/// Evaluates one formula in the context of a cell.
class Evaluator {
  Evaluator(this.engine, this.sheet, this.row, this.col);

  final FormulaEngine engine;
  final SheetData sheet;
  final int row;
  final int col;

  Workbook get workbook => engine.workbook;

  /// Evaluates [node] to a scalar cell value.
  Object? evaluateTop(FNode node) {
    Object? v;
    try {
      v = deref(eval(node));
    } on FormulaException catch (e) {
      return e.error;
    }
    return normalize(v, blankAsZero: true);
  }

  static Object? normalize(Object? v, {bool blankAsZero = false}) {
    if (v == null) return blankAsZero ? 0.0 : null;
    if (v is int) return v.toDouble();
    if (v is double) {
      if (v.isNaN || v.isInfinite) return CellError.num;
      return v == 0 ? 0.0 : v;
    }
    return v;
  }

  /// Evaluates a node; references stay [RangeValue]s, errors are returned as
  /// [CellError] values.
  Object? eval(FNode node) {
    switch (node) {
      case NumNode(:final value):
        return value;
      case StrNode(:final value):
        return value;
      case BoolNode(:final value):
        return value;
      case ErrNode(:final error):
        return error;
      case MissingNode():
        return null;
      case RefNode(:final ref):
        return resolveRef(ref);
      case NameNode(:final name):
        throw UnsupportedFormula('Name $name');
      case FuncNode(:final name, :final args):
        final fn = formulaFunctions[name];
        if (fn == null) throw UnsupportedFormula('Function $name');
        try {
          final r = fn(args, this);
          if (r is double && (r.isNaN || r.isInfinite)) return CellError.num;
          return r;
        } on FormulaException catch (e) {
          return e.error;
        }
      case UnaryNode(:final op, :final operand):
        final v = scalar(operand);
        if (v is CellError) return v;
        try {
          final x = number(v);
          return op == '-' ? -x : x;
        } on FormulaException catch (e) {
          return e.error;
        }
      case PercentNode(:final operand):
        final v = scalar(operand);
        if (v is CellError) return v;
        try {
          return number(v) / 100;
        } on FormulaException catch (e) {
          return e.error;
        }
      case BinNode(:final op, :final left, :final right):
        return _binary(op, left, right);
      case RangeOpNode(:final left, :final right):
        final a = eval(left);
        final b = eval(right);
        if (a is CellError) return a;
        if (b is CellError) return b;
        if (a is RangeValue && b is RangeValue && identical(a.sheet, b.sheet)) {
          return RangeValue(
            a.sheet,
            math.min(a.r1, b.r1),
            math.min(a.c1, b.c1),
            math.max(a.r2, b.r2),
            math.max(a.c2, b.c2),
          );
        }
        return CellError.value;
      case ArrayNode(:final rows):
        return ArrayValue([
          for (final r in rows) [for (final c in r) deref(eval(c))],
        ]);
    }
  }

  Object? resolveRef(RefInfo ref) {
    final target = ref.sheet == null ? sheet : workbook.sheetByName(ref.sheet!);
    if (target == null) return CellError.ref;
    return RangeValue(target, ref.top, ref.left, ref.bottom, ref.right);
  }

  Object? _binary(String op, FNode l, FNode r) {
    final a = scalar(l);
    final b = scalar(r);
    if (a is CellError) return a;
    if (b is CellError) return b;
    try {
      switch (op) {
        case '+':
          return number(a) + number(b);
        case '-':
          return number(a) - number(b);
        case '*':
          return number(a) * number(b);
        case '/':
          final d = number(b);
          final n = number(a);
          if (d == 0) return CellError.div0;
          return n / d;
        case '^':
          final x = number(a);
          final y = number(b);
          if (x == 0 && y == 0) return CellError.num;
          if (x == 0 && y < 0) return CellError.div0;
          final p = math.pow(x, y).toDouble();
          if (p.isNaN || p.isInfinite) return CellError.num;
          return p;
        case '&':
          return text(a) + text(b);
        case '=':
          return compareValues(a, b) == 0;
        case '<>':
          return compareValues(a, b) != 0;
        case '<':
          return compareValues(a, b) < 0;
        case '>':
          return compareValues(a, b) > 0;
        case '<=':
          return compareValues(a, b) <= 0;
        case '>=':
          return compareValues(a, b) >= 0;
      }
    } on FormulaException catch (e) {
      return e.error;
    }
    return CellError.value;
  }

  /// Evaluates and reduces references/arrays to a single value.
  Object? scalar(FNode node) => deref(eval(node));

  Object? deref(Object? v) {
    if (v is RangeValue) {
      if (v.isSingle) return cellValue(v.sheet, v.r1, v.c1);
      if (v.c1 == v.c2 && row >= v.r1 && row <= v.r2) {
        return cellValue(v.sheet, row, v.c1);
      }
      if (v.r1 == v.r2 && col >= v.c1 && col <= v.c2) {
        return cellValue(v.sheet, v.r1, col);
      }
      return CellError.value;
    }
    if (v is ArrayValue) {
      if (v.rows.isEmpty || v.rows.first.isEmpty) return CellError.value;
      return v.rows.first.first;
    }
    return v;
  }

  Object? cellValue(SheetData s, int r, int c) => s.cells[cellKey(r, c)]?.value;

  // --- coercions -----------------------------------------------------------

  double number(Object? v) {
    if (v == null) return 0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is bool) return v ? 1 : 0;
    if (v is CellError) throw FormulaException(v);
    if (v is String) {
      final d = parseNumberText(v);
      if (d == null) throw const FormulaException(CellError.value);
      return d;
    }
    if (v is RangeValue || v is ArrayValue) return number(deref(v));
    throw const FormulaException(CellError.value);
  }

  String text(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is double) return NumberFormats.numberToPlainString(v);
    if (v is bool) return v ? 'TRUE' : 'FALSE';
    if (v is CellError) throw FormulaException(v);
    if (v is RangeValue || v is ArrayValue) return text(deref(v));
    return v.toString();
  }

  bool boolean(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is double) return v != 0;
    if (v is CellError) throw FormulaException(v);
    if (v is String) {
      final u = v.trim().toUpperCase();
      if (u == 'TRUE') return true;
      if (u == 'FALSE') return false;
      throw const FormulaException(CellError.value);
    }
    if (v is RangeValue || v is ArrayValue) return boolean(deref(v));
    throw const FormulaException(CellError.value);
  }

  // --- argument helpers ----------------------------------------------------

  void argCount(List<FNode> args, int min, [int? max]) {
    if (args.length < min || (max != null && args.length > max)) {
      throw const FormulaException(CellError.value);
    }
  }

  bool hasArg(List<FNode> args, int i) =>
      i < args.length && args[i] is! MissingNode;

  Object? argValue(List<FNode> args, int i) =>
      i < args.length ? scalar(args[i]) : null;

  double numArg(List<FNode> args, int i, [double? def]) {
    if (!hasArg(args, i)) {
      if (def != null) return def;
      if (i < args.length) return 0;
      throw const FormulaException(CellError.value);
    }
    final v = scalar(args[i]);
    return number(v);
  }

  String textArg(List<FNode> args, int i, [String? def]) {
    if (!hasArg(args, i)) {
      if (def != null) return def;
      if (i < args.length) return '';
      throw const FormulaException(CellError.value);
    }
    return text(scalar(args[i]));
  }

  bool boolArg(List<FNode> args, int i, [bool? def]) {
    if (!hasArg(args, i)) {
      if (def != null) return def;
      if (i < args.length) return false;
      throw const FormulaException(CellError.value);
    }
    return boolean(scalar(args[i]));
  }

  /// Evaluates an argument that must be a reference.
  RangeValue rangeArg(List<FNode> args, int i) {
    if (i >= args.length) throw const FormulaException(CellError.value);
    final v = eval(args[i]);
    if (v is CellError) throw FormulaException(v);
    if (v is RangeValue) return v;
    throw const FormulaException(CellError.value);
  }

  /// Non-blank values of a range (row-major when [ordered]).
  Iterable<Object?> rangeValues(RangeValue r, {bool ordered = false}) sync* {
    final s = r.sheet;
    final r2 = r.usedR2;
    final c2 = r.usedC2;
    if (r2 < r.r1 || c2 < r.c1) return;
    final area = (r2 - r.r1 + 1) * (c2 - r.c1 + 1);
    if (area <= 4096 || area <= s.cells.length) {
      for (var y = r.r1; y <= r2; y++) {
        for (var x = r.c1; x <= c2; x++) {
          final v = s.cells[cellKey(y, x)]?.value;
          if (v != null) yield v;
        }
      }
      return;
    }
    final keys = <int>[];
    s.cells.forEach((k, cell) {
      if (cell.value == null) return;
      final y = keyRow(k);
      final x = keyCol(k);
      if (y >= r.r1 && y <= r2 && x >= r.c1 && x <= c2) keys.add(k);
    });
    if (ordered) keys.sort();
    for (final k in keys) {
      yield s.cells[k]!.value;
    }
  }

  /// Calls [f] for every non-blank value of [r] (fast path, unordered when
  /// the range is much larger than the data).
  void forEachRangeValue(RangeValue r, void Function(Object v) f) {
    final s = r.sheet;
    final r2 = r.usedR2;
    final c2 = r.usedC2;
    if (r2 < r.r1 || c2 < r.c1) return;
    final cells = s.cells;
    final area = (r2 - r.r1 + 1) * (c2 - r.c1 + 1);
    if (area <= 4096 || area <= cells.length) {
      for (var y = r.r1; y <= r2; y++) {
        final base = y * kMaxCols;
        for (var x = r.c1; x <= c2; x++) {
          final v = cells[base + x]?.value;
          if (v != null) f(v);
        }
      }
      return;
    }
    cells.forEach((k, cell) {
      final v = cell.value;
      if (v == null) return;
      final y = k ~/ kMaxCols;
      final x = k % kMaxCols;
      if (y >= r.r1 && y <= r2 && x >= r.c1 && x <= c2) f(v);
    });
  }

  /// Calls [f] for each number in the arguments, Excel SUM-style: numbers in
  /// references count, text/booleans in references are ignored, direct
  /// arguments are coerced.
  void forEachNumber(List<FNode> args, void Function(double) f) {
    for (final node in args) {
      if (node is MissingNode) continue;
      final v = eval(node);
      if (v is RangeValue) {
        forEachRangeValue(v, (x) {
          if (x is double) {
            f(x);
          } else if (x is CellError) {
            throw FormulaException(x);
          }
        });
      } else if (v is ArrayValue) {
        for (final row in v.rows) {
          for (final x in row) {
            if (x is double) {
              f(x);
            } else if (x is CellError) {
              throw FormulaException(x);
            }
          }
        }
      } else if (v is CellError) {
        throw FormulaException(v);
      } else if (v != null) {
        f(number(v));
      }
    }
  }

  /// Flattens arguments into a list of values (blank cells skipped).
  List<Object?> flatValues(List<FNode> args, {bool ordered = true}) {
    final out = <Object?>[];
    for (final node in args) {
      if (node is MissingNode) continue;
      final v = eval(node);
      if (v is RangeValue) {
        out.addAll(rangeValues(v, ordered: ordered));
      } else if (v is ArrayValue) {
        for (final row in v.rows) {
          out.addAll(row);
        }
      } else {
        out.add(v);
      }
    }
    return out;
  }

  /// A 2-D grid of values for an argument (range, array or scalar).
  List<List<Object?>> grid(Object? v) {
    if (v is RangeValue) {
      final r2 = v.rows > 100000 ? v.usedR2 : v.r2;
      final c2 = v.cols > 1000 ? v.usedC2 : v.c2;
      return [
        for (var y = v.r1; y <= r2; y++)
          [for (var x = v.c1; x <= c2; x++) cellValue(v.sheet, y, x)],
      ];
    }
    if (v is ArrayValue) return v.rows;
    return [
      [v],
    ];
  }

  /// Excel ordering: numbers < text < booleans; text is case-insensitive.
  int compareValues(Object? a, Object? b) {
    if (a is CellError) throw FormulaException(a);
    if (b is CellError) throw FormulaException(b);
    a ??= b is String ? '' : (b is bool ? false : 0.0);
    b ??= a is String ? '' : (a is bool ? false : 0.0);
    final ra = _rank(a);
    final rb = _rank(b);
    if (ra != rb) return ra.compareTo(rb);
    if (a is double && b is double) return a.compareTo(b);
    if (a is String && b is String) {
      return a.toLowerCase().compareTo(b.toLowerCase()).sign;
    }
    if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
    return 0;
  }

  static int _rank(Object? v) {
    if (v is double) return 0;
    if (v is String) return 1;
    if (v is bool) return 2;
    return 3;
  }

  double get todaySerial {
    final now = DateTime.now();
    return NumberFormats.dateTimeToSerial(DateTime(now.year, now.month, now.day),
        date1904: workbook.date1904);
  }

  double get nowSerial => NumberFormats.dateTimeToSerial(DateTime.now(),
      date1904: workbook.date1904);
}

final _numText = RegExp(r'^[+-]?\$?(\d{1,3}(,\d{3})+|\d*)(\.\d+)?([eE][+-]?\d+)?%?$');

/// Converts user/text input such as `1,234.5`, `-3e2`, `50%`, `$12` to a
/// number, or null.
double? parseNumberText(String s) {
  final t = s.trim();
  if (t.isEmpty || !_numText.hasMatch(t)) return null;
  var core = t.replaceAll(',', '').replaceAll(r'$', '');
  var pct = false;
  if (core.endsWith('%')) {
    pct = true;
    core = core.substring(0, core.length - 1);
  }
  if (core.isEmpty || core == '+' || core == '-' || core == '.') return null;
  final d = double.tryParse(core);
  if (d == null) return null;
  return pct ? d / 100 : d;
}

typedef CellId = (SheetData, int);

class _Prec {
  _Prec(this.sheet, this.range);
  final SheetData sheet;
  final CellRange range;
}

class _BigDep {
  _BigDep(this.sheet, this.range, this.id);
  final SheetData sheet;
  final CellRange range;
  final CellId id;
}

const _volatileFunctions = {
  'TODAY', 'NOW', 'RAND', 'RANDBETWEEN', 'OFFSET', 'INDIRECT', 'CELL', 'INFO', //
};

/// Dependency-tracking recalculation engine.
class FormulaEngine {
  FormulaEngine(this.workbook);

  final Workbook workbook;

  final Map<String, Object> _astCache = {};
  static const Object _syntaxError = Object();

  bool _built = false;
  final Map<CellId, List<_Prec>> _precOf = {};
  final Map<CellId, Set<CellId>> _dependents = {};
  final Map<SheetData, Map<int, List<_BigDep>>> _colBuckets = {};
  final Map<SheetData, List<_BigDep>> _wide = {};
  final Set<CellId> _volatile = {};

  /// Parsed syntax tree for [formula], or null when it doesn't parse.
  FNode? parse(String formula) {
    final cached = _astCache[formula];
    if (cached != null) return identical(cached, _syntaxError) ? null : cached as FNode;
    if (_astCache.length > 20000) _astCache.clear();
    try {
      final n = parseFormula(formula);
      _astCache[formula] = n;
      return n;
    } on FormulaSyntaxError {
      _astCache[formula] = _syntaxError;
      return null;
    } catch (_) {
      _astCache[formula] = _syntaxError;
      return null;
    }
  }

  /// Drops the dependency graph (after structural edits); rebuilt lazily.
  void invalidate() {
    _built = false;
    _precOf.clear();
    _dependents.clear();
    _colBuckets.clear();
    _wide.clear();
    _volatile.clear();
  }

  void _ensureBuilt() {
    if (_built) return;
    _built = true;
    for (final s in workbook.sheets) {
      s.cells.forEach((k, cell) {
        final f = cell.formula;
        if (f != null) _addFormula(s, k, f);
      });
    }
  }

  void _addFormula(SheetData s, int key, String formula) {
    final id = (s, key);
    final ast = parse(formula);
    final precs = <_Prec>[];
    if (ast != null) {
      visitRefs(ast, (ref) {
        final target = ref.sheet == null ? s : workbook.sheetByName(ref.sheet!);
        if (target == null) return;
        precs.add(_Prec(target, CellRange(ref.top, ref.left, ref.bottom, ref.right)));
      });
      visitFuncs(ast, (f) {
        if (_volatileFunctions.contains(f.name)) _volatile.add(id);
      });
    }
    _precOf[id] = precs;
    for (final p in precs) {
      if (p.range.area <= 64) {
        for (var r = p.range.r1; r <= p.range.r2; r++) {
          for (var c = p.range.c1; c <= p.range.c2; c++) {
            _dependents.putIfAbsent((p.sheet, cellKey(r, c)), () => <CellId>{}).add(id);
          }
        }
      } else {
        final dep = _BigDep(p.sheet, p.range, id);
        if (p.range.colCount <= 64) {
          final buckets = _colBuckets.putIfAbsent(p.sheet, () => {});
          for (var c = p.range.c1; c <= p.range.c2; c++) {
            buckets.putIfAbsent(c, () => []).add(dep);
          }
        } else {
          _wide.putIfAbsent(p.sheet, () => []).add(dep);
        }
      }
    }
  }

  void _removeFormula(CellId id) {
    final precs = _precOf.remove(id);
    _volatile.remove(id);
    if (precs == null) return;
    for (final p in precs) {
      if (p.range.area <= 64) {
        for (var r = p.range.r1; r <= p.range.r2; r++) {
          for (var c = p.range.c1; c <= p.range.c2; c++) {
            final key = (p.sheet, cellKey(r, c));
            final set = _dependents[key];
            if (set != null) {
              set.remove(id);
              if (set.isEmpty) _dependents.remove(key);
            }
          }
        }
      } else if (p.range.colCount <= 64) {
        final buckets = _colBuckets[p.sheet];
        if (buckets == null) continue;
        for (var c = p.range.c1; c <= p.range.c2; c++) {
          buckets[c]?.removeWhere((d) => d.id == id);
        }
      } else {
        _wide[p.sheet]?.removeWhere((d) => d.id == id);
      }
    }
  }

  Iterable<CellId> _dependentsOf(SheetData s, int key) sync* {
    final direct = _dependents[(s, key)];
    if (direct != null) yield* direct;
    final r = keyRow(key);
    final c = keyCol(key);
    final bucket = _colBuckets[s]?[c];
    if (bucket != null) {
      for (final d in bucket) {
        if (d.range.contains(r, c)) yield d.id;
      }
    }
    final wide = _wide[s];
    if (wide != null) {
      for (final d in wide) {
        if (d.range.contains(r, c)) yield d.id;
      }
    }
  }

  Iterable<CellId> _dirtyPrecedents(
      CellId id, Map<SheetData, Map<int, Set<int>>> index) sync* {
    final precs = _precOf[id];
    if (precs == null) return;
    for (final p in precs) {
      final s = p.sheet;
      final cols = index[s];
      if (cols == null) continue;
      final range = p.range;
      final r2 = math.min(range.r2, s.usedRows - 1);
      final c2 = math.min(range.c2, s.usedCols - 1);
      if (r2 < range.r1 || c2 < range.c1) continue;
      if (c2 - range.c1 + 1 <= cols.length) {
        for (var c = range.c1; c <= c2; c++) {
          final rows = cols[c];
          if (rows == null) continue;
          if (rows.length <= r2 - range.r1 + 1) {
            for (final r in rows) {
              if (r >= range.r1 && r <= r2) yield (s, cellKey(r, c));
            }
          } else {
            for (var r = range.r1; r <= r2; r++) {
              if (rows.contains(r)) yield (s, cellKey(r, c));
            }
          }
        }
      } else {
        for (final e in cols.entries) {
          final c = e.key;
          if (c < range.c1 || c > c2) continue;
          for (final r in e.value) {
            if (r >= range.r1 && r <= r2) yield (s, cellKey(r, c));
          }
        }
      }
    }
  }

  /// Recalculates formulas affected by edits to [keys] on [sheet] (the
  /// edited cells themselves included).
  void cellsChanged(SheetData sheet, Iterable<int> keys) {
    _ensureBuilt();
    final changed = <CellId>[];
    final dirty = <CellId>{};
    for (final k in keys) {
      final id = (sheet, k);
      _removeFormula(id);
      final f = sheet.cells[k]?.formula;
      if (f != null) {
        _addFormula(sheet, k, f);
        dirty.add(id);
      }
      changed.add(id);
    }
    final queue = <CellId>[...changed, ..._volatile];
    dirty.addAll(_volatile);
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      for (final dep in _dependentsOf(id.$1, id.$2)) {
        if (dirty.add(dep)) queue.add(dep);
      }
    }
    _recalc(dirty);
  }

  /// Recalculates every formula in the workbook.
  void recalcAll() {
    invalidate();
    _ensureBuilt();
    _recalc(_precOf.keys.toSet());
  }

  /// Evaluates formulas that have no cached value (and their dependents).
  void recalcMissing() {
    final missing = <CellId>{};
    for (final s in workbook.sheets) {
      s.cells.forEach((k, cell) {
        if (cell.formula != null && cell.value == null) missing.add((s, k));
      });
    }
    if (missing.isEmpty) return;
    _ensureBuilt();
    final dirty = <CellId>{...missing};
    final queue = missing.toList();
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      for (final dep in _dependentsOf(id.$1, id.$2)) {
        if (dirty.add(dep)) queue.add(dep);
      }
    }
    _recalc(dirty);
  }

  void _recalc(Set<CellId> dirty) {
    if (dirty.isEmpty) return;
    // Dirty formula cells indexed by sheet -> column -> rows.
    final index = <SheetData, Map<int, Set<int>>>{};
    for (final d in dirty) {
      index
          .putIfAbsent(d.$1, () => <int, Set<int>>{})
          .putIfAbsent(keyCol(d.$2), () => <int>{})
          .add(keyRow(d.$2));
    }
    final state = <CellId, int>{};
    final order = <CellId>[];
    final circular = <CellId>{};
    for (final start in dirty) {
      if (state.containsKey(start)) continue;
      state[start] = 1;
      final stack = <(CellId, Iterator<CellId>)>[
        (start, _dirtyPrecedents(start, index).iterator),
      ];
      while (stack.isNotEmpty) {
        final top = stack.last;
        final it = top.$2;
        if (it.moveNext()) {
          final p = it.current;
          final st = state[p];
          if (st == null) {
            state[p] = 1;
            stack.add((p, _dirtyPrecedents(p, index).iterator));
          } else if (st == 1) {
            for (var i = stack.length - 1; i >= 0; i--) {
              circular.add(stack[i].$1);
              if (stack[i].$1 == p) break;
            }
          }
        } else {
          state[top.$1] = 2;
          order.add(top.$1);
          stack.removeLast();
        }
      }
    }
    for (final id in order) {
      final s = id.$1;
      final k = id.$2;
      final cell = s.cells[k];
      if (cell == null || cell.formula == null) continue;
      if (circular.contains(id)) {
        s.cells[k] = cell.withValue(CellError.circular);
        continue;
      }
      final result = evaluateCell(s, k, cell);
      if (!identical(result, _keepCached)) s.cells[k] = cell.withValue(result);
    }
  }

  /// Evaluates a formula cell; returns a sentinel when the cached value
  /// should be kept.
  Object? evaluateCell(SheetData s, int key, Cell cell) {
    if (cell.arrayRef != null) return _keepCached;
    final ast = parse(cell.formula!);
    if (ast == null) return _keepCached;
    try {
      return Evaluator(this, s, keyRow(key), keyCol(key)).evaluateTop(ast);
    } on UnsupportedFormula {
      return _keepCached;
    } on StackOverflowError {
      return CellError.num;
    } catch (_) {
      return CellError.value;
    }
  }

  /// Evaluates an arbitrary formula at a position (used for previews and
  /// tests). Returns null when unsupported.
  Object? evaluateFormula(SheetData s, int row, int col, String formula) {
    final ast = parse(formula);
    if (ast == null) return CellError.name;
    try {
      return Evaluator(this, s, row, col).evaluateTop(ast);
    } on UnsupportedFormula {
      return null;
    }
  }

  /// True when [formula] parses.
  bool isValid(String formula) => parse(formula) != null;
}
