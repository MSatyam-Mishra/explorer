import 'dart:math' as math;

import '../model/number_format.dart';
import '../model/workbook.dart';
import 'evaluator.dart';
import 'parser.dart';

typedef FormulaFn = Object? Function(List<FNode> args, Evaluator ev);

Never _err(CellError e) => throw FormulaException(e);

double _round(double x, int digits, int mode) {
  final f = math.pow(10, digits).toDouble();
  var y = x * f;
  if (y.isFinite) y = double.parse(y.toStringAsPrecision(15));
  switch (mode) {
    case 0:
      y = y < 0 ? -((-y) + 0.5).floorToDouble() : (y + 0.5).floorToDouble();
    case 1:
      y = y < 0 ? -(-y).ceilToDouble() : y.ceilToDouble();
    default:
      y = y.truncateToDouble();
  }
  return y / f;
}

/// Criteria used by SUMIF/COUNTIF/AVERAGEIF and friends.
class _Criteria {
  _Criteria(Object? crit) {
    if (crit is double) {
      _num = crit;
      return;
    }
    if (crit is bool) {
      _bool = crit;
      return;
    }
    if (crit is CellError) {
      _error = crit;
      return;
    }
    var s = crit == null ? '' : crit.toString();
    for (final o in const ['<=', '>=', '<>', '<', '>', '=']) {
      if (s.startsWith(o)) {
        _op = o;
        s = s.substring(o.length);
        break;
      }
    }
    final n = parseNumberText(s);
    if (n != null) {
      _num = n;
      return;
    }
    final u = s.toUpperCase();
    if (u == 'TRUE' || u == 'FALSE') {
      _bool = u == 'TRUE';
      return;
    }
    final err = CellError.tryParse(s);
    if (err != null) {
      _error = err;
      return;
    }
    _text = s;
    if (s.contains('*') || s.contains('?') || s.contains('~')) {
      _pattern = RegExp('^${wildcardToRegex(s)}\$', caseSensitive: false, dotAll: true);
    }
  }

  String _op = '=';
  double? _num;
  bool? _bool;
  CellError? _error;
  String? _text;
  RegExp? _pattern;

  bool matches(Object? v) {
    if (_num != null) {
      if (v is double) return _cmp(v.compareTo(_num!));
      if (v is String && _op == '=') {
        final d = parseNumberText(v);
        return d != null && d == _num;
      }
      return _op == '<>';
    }
    if (_bool != null) {
      if (v is bool) return _cmp((v ? 1 : 0).compareTo(_bool! ? 1 : 0));
      return _op == '<>';
    }
    if (_error != null) {
      final eq = v is CellError && v == _error;
      return _op == '<>' ? !eq : (_op == '=' && eq);
    }
    final t = _text ?? '';
    if (t.isEmpty) {
      final blank = v == null || (v is String && v.isEmpty);
      if (_op == '=') return blank;
      if (_op == '<>') return !blank;
      return false;
    }
    if (_op == '=' || _op == '<>') {
      final eq = v is String &&
          (_pattern != null ? _pattern!.hasMatch(v) : v.toLowerCase() == t.toLowerCase());
      return _op == '=' ? eq : !eq;
    }
    if (v is! String) return false;
    return _cmp(v.toLowerCase().compareTo(t.toLowerCase()).sign);
  }

  bool _cmp(int c) => switch (_op) {
        '<' => c < 0,
        '<=' => c <= 0,
        '>' => c > 0,
        '>=' => c >= 0,
        '<>' => c != 0,
        _ => c == 0,
      };
}

String wildcardToRegex(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '~' && i + 1 < s.length) {
      b.write(RegExp.escape(s[i + 1]));
      i++;
    } else if (ch == '*') {
      b.write('.*');
    } else if (ch == '?') {
      b.write('.');
    } else {
      b.write(RegExp.escape(ch));
    }
  }
  return b.toString();
}

/// Iterates (value, row offset, col offset) over a range clamped to its
/// used area.
Iterable<(Object?, int, int)> _cells(Evaluator ev, RangeValue r) sync* {
  final r2 = r.usedR2;
  final c2 = r.usedC2;
  for (var y = r.r1; y <= r2; y++) {
    for (var x = r.c1; x <= c2; x++) {
      yield (ev.cellValue(r.sheet, y, x), y - r.r1, x - r.c1);
    }
  }
}

int _usedArea(RangeValue r) {
  final r2 = r.usedR2;
  final c2 = r.usedC2;
  if (r2 < r.r1 || c2 < r.c1) return 0;
  return (r2 - r.r1 + 1) * (c2 - r.c1 + 1);
}

/// Shared implementation of the *IF/*IFS family. Calls [f] with the value
/// in [target] for every position where all criteria match.
/// Returns how many blank cells outside the used area also match (only
/// meaningful for COUNTIFS).
int _ifs(Evaluator ev, List<(RangeValue, _Criteria)> conds, RangeValue? target,
    void Function(Object?) f) {
  final first = conds.first.$1;
  for (final c in conds) {
    if (c.$1.rows != first.rows || c.$1.cols != first.cols) {
      _err(CellError.value);
    }
  }
  final r2 = first.usedR2;
  final c2 = first.usedC2;
  var visited = 0;
  for (var y = first.r1; y <= r2; y++) {
    for (var x = first.c1; x <= c2; x++) {
      visited++;
      final dy = y - first.r1;
      final dx = x - first.c1;
      var ok = true;
      for (final c in conds) {
        if (!c.$2.matches(ev.cellValue(c.$1.sheet, c.$1.r1 + dy, c.$1.c1 + dx))) {
          ok = false;
          break;
        }
      }
      if (ok) {
        f(target == null ? true : ev.cellValue(target.sheet, target.r1 + dy, target.c1 + dx));
      }
    }
  }
  // Blank cells outside the used area (COUNTIFS(A:A,"") etc.).
  final total = first.rows * first.cols;
  if (total > visited && target == null && conds.every((c) => c.$2.matches(null))) {
    return total - visited;
  }
  return 0;
}

bool _lookupEquals(Object? cell, Object? lookup, RegExp? pattern) {
  if (cell == null) return false;
  if (lookup is double) return cell is double && cell == lookup;
  if (lookup is bool) return cell is bool && cell == lookup;
  if (lookup is String) {
    if (cell is! String) return false;
    if (pattern != null) return pattern.hasMatch(cell);
    return cell.toLowerCase() == lookup.toLowerCase();
  }
  return false;
}

RegExp? _lookupPattern(Object? lookup) {
  if (lookup is String && (lookup.contains('*') || lookup.contains('?'))) {
    return RegExp('^${wildcardToRegex(lookup)}\$', caseSensitive: false, dotAll: true);
  }
  return null;
}

int _sameTypeCompare(Evaluator ev, Object? a, Object? b) {
  if (a is double && b is double) return a.compareTo(b);
  if (a is String && b is String) return a.toLowerCase().compareTo(b.toLowerCase()).sign;
  if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
  return 2; // incomparable
}

/// Position (0-based) of [lookup] in a 1-D list of values.
int _matchIn(Evaluator ev, List<Object?> values, Object? lookup, int type) {
  if (type == 0) {
    final p = _lookupPattern(lookup);
    for (var i = 0; i < values.length; i++) {
      if (_lookupEquals(values[i], lookup, p)) return i;
    }
    return -1;
  }
  var best = -1;
  for (var i = 0; i < values.length; i++) {
    final v = values[i];
    if (v == null) continue;
    final c = _sameTypeCompare(ev, v, lookup);
    if (c == 2) continue;
    if (type > 0) {
      if (c <= 0) {
        best = i;
      } else {
        break;
      }
    } else {
      if (c >= 0) {
        best = i;
      } else {
        break;
      }
    }
  }
  return best;
}

List<Object?> _vector(Evaluator ev, Object? v) {
  if (v is RangeValue) {
    if (v.rows == 1) {
      final c2 = v.cols > 1000 ? v.usedC2 : v.c2;
      return [for (var x = v.c1; x <= c2; x++) ev.cellValue(v.sheet, v.r1, x)];
    }
    if (v.cols == 1) {
      final r2 = v.rows > 1000 ? v.usedR2 : v.r2;
      return [for (var y = v.r1; y <= r2; y++) ev.cellValue(v.sheet, y, v.c1)];
    }
    _err(CellError.na);
  }
  if (v is ArrayValue) {
    if (v.rows.length == 1) return v.rows.first;
    return [for (final r in v.rows) r.isEmpty ? null : r.first];
  }
  if (v is CellError) _err(v);
  return [v];
}

List<double> _numbers(Evaluator ev, List<FNode> args) {
  final out = <double>[];
  ev.forEachNumber(args, out.add);
  return out;
}

double _variance(List<double> xs, bool sample) {
  final n = xs.length;
  if (n < (sample ? 2 : 1)) _err(CellError.div0);
  final mean = xs.reduce((a, b) => a + b) / n;
  var s = 0.0;
  for (final x in xs) {
    s += (x - mean) * (x - mean);
  }
  return s / (sample ? n - 1 : n);
}

DateTime _date(Evaluator ev, double serial) {
  final d = NumberFormats.serialToDateTime(serial, date1904: ev.workbook.date1904);
  if (d == null) _err(CellError.num);
  return d;
}

double _serial(Evaluator ev, DateTime d) =>
    NumberFormats.dateTimeToSerial(d, date1904: ev.workbook.date1904);

Object? _aggregate(String name, List<FNode> args, Evaluator ev) =>
    formulaFunctions[name]!(args, ev);

final Map<String, FormulaFn> formulaFunctions = {
  // --- math & aggregates ----------------------------------------------------
  'SUM': (a, ev) {
    var s = 0.0;
    ev.forEachNumber(a, (x) => s += x);
    return s;
  },
  'AVERAGE': (a, ev) {
    var s = 0.0;
    var n = 0;
    ev.forEachNumber(a, (x) {
      s += x;
      n++;
    });
    if (n == 0) _err(CellError.div0);
    return s / n;
  },
  'MIN': (a, ev) {
    double? m;
    ev.forEachNumber(a, (x) => m = m == null ? x : math.min(m!, x));
    return m ?? 0.0;
  },
  'MAX': (a, ev) {
    double? m;
    ev.forEachNumber(a, (x) => m = m == null ? x : math.max(m!, x));
    return m ?? 0.0;
  },
  'PRODUCT': (a, ev) {
    var p = 1.0;
    var any = false;
    ev.forEachNumber(a, (x) {
      p *= x;
      any = true;
    });
    return any ? p : 0.0;
  },
  'COUNT': (a, ev) {
    var n = 0;
    for (final node in a) {
      if (node is MissingNode) continue;
      final v = ev.eval(node);
      if (v is RangeValue) {
        ev.forEachRangeValue(v, (x) {
          if (x is double) n++;
        });
      } else if (v is ArrayValue) {
        for (final r in v.rows) {
          n += r.whereType<double>().length;
        }
      } else if (v is double || v is bool) {
        n++;
      } else if (v is String && parseNumberText(v) != null) {
        n++;
      }
    }
    return n.toDouble();
  },
  'COUNTA': (a, ev) {
    var n = 0;
    for (final node in a) {
      if (node is MissingNode) continue;
      final v = ev.eval(node);
      if (v is RangeValue) {
        ev.forEachRangeValue(v, (_) => n++);
      } else if (v is ArrayValue) {
        for (final r in v.rows) {
          n += r.where((x) => x != null).length;
        }
      } else {
        n++;
      }
    }
    return n.toDouble();
  },
  'COUNTBLANK': (a, ev) {
    ev.argCount(a, 1, 1);
    final r = ev.rangeArg(a, 0);
    var nonBlank = 0;
    for (final v in ev.rangeValues(r)) {
      if (!(v is String && v.isEmpty)) nonBlank++;
    }
    return (r.rows * r.cols - nonBlank).toDouble();
  },
  'ABS': (a, ev) => ev.numArg(a, 0).abs(),
  'SQRT': (a, ev) {
    final x = ev.numArg(a, 0);
    if (x < 0) _err(CellError.num);
    return math.sqrt(x);
  },
  'POWER': (a, ev) {
    final x = ev.numArg(a, 0);
    final y = ev.numArg(a, 1);
    if (x == 0 && y <= 0) _err(y == 0 ? CellError.num : CellError.div0);
    return math.pow(x, y).toDouble();
  },
  'MOD': (a, ev) {
    final n = ev.numArg(a, 0);
    final d = ev.numArg(a, 1);
    if (d == 0) _err(CellError.div0);
    return n - d * (n / d).floorToDouble();
  },
  'INT': (a, ev) => ev.numArg(a, 0).floorToDouble(),
  'TRUNC': (a, ev) => _round(ev.numArg(a, 0), ev.numArg(a, 1, 0).truncate(), -1),
  'ROUND': (a, ev) {
    ev.argCount(a, 2, 2);
    return _round(ev.numArg(a, 0), ev.numArg(a, 1).truncate(), 0);
  },
  'ROUNDUP': (a, ev) {
    ev.argCount(a, 2, 2);
    return _round(ev.numArg(a, 0), ev.numArg(a, 1).truncate(), 1);
  },
  'ROUNDDOWN': (a, ev) {
    ev.argCount(a, 2, 2);
    return _round(ev.numArg(a, 0), ev.numArg(a, 1).truncate(), -1);
  },
  'CEILING': (a, ev) {
    final x = ev.numArg(a, 0);
    final s = ev.numArg(a, 1, x < 0 ? -1 : 1);
    if (s == 0) return 0.0;
    if (x > 0 && s < 0) _err(CellError.num);
    return (x / s).ceilToDouble() * s;
  },
  'FLOOR': (a, ev) {
    final x = ev.numArg(a, 0);
    final s = ev.numArg(a, 1, x < 0 ? -1 : 1);
    if (s == 0) _err(CellError.div0);
    if (x > 0 && s < 0) _err(CellError.num);
    return (x / s).floorToDouble() * s;
  },
  'SIGN': (a, ev) => ev.numArg(a, 0).sign,
  'PI': (a, ev) => math.pi,
  'EXP': (a, ev) => math.exp(ev.numArg(a, 0)),
  'LN': (a, ev) {
    final x = ev.numArg(a, 0);
    if (x <= 0) _err(CellError.num);
    return math.log(x);
  },
  'LOG10': (a, ev) {
    final x = ev.numArg(a, 0);
    if (x <= 0) _err(CellError.num);
    return math.log(x) / math.ln10;
  },
  'LOG': (a, ev) {
    final x = ev.numArg(a, 0);
    final b = ev.numArg(a, 1, 10);
    if (x <= 0 || b <= 0 || b == 1) _err(CellError.num);
    return math.log(x) / math.log(b);
  },
  'SIN': (a, ev) => math.sin(ev.numArg(a, 0)),
  'COS': (a, ev) => math.cos(ev.numArg(a, 0)),
  'TAN': (a, ev) => math.tan(ev.numArg(a, 0)),
  'RADIANS': (a, ev) => ev.numArg(a, 0) * math.pi / 180,
  'DEGREES': (a, ev) => ev.numArg(a, 0) * 180 / math.pi,
  'RAND': (a, ev) => math.Random().nextDouble(),
  'RANDBETWEEN': (a, ev) {
    final lo = ev.numArg(a, 0).ceil();
    final hi = ev.numArg(a, 1).floor();
    if (hi < lo) _err(CellError.num);
    return (lo + math.Random().nextInt(hi - lo + 1)).toDouble();
  },
  'MEDIAN': (a, ev) {
    final xs = _numbers(ev, a)..sort();
    if (xs.isEmpty) _err(CellError.num);
    final m = xs.length ~/ 2;
    return xs.length.isOdd ? xs[m] : (xs[m - 1] + xs[m]) / 2;
  },
  'LARGE': (a, ev) {
    final xs = _numbers(ev, a.sublist(0, 1))..sort((x, y) => y.compareTo(x));
    final k = ev.numArg(a, 1).ceil();
    if (k < 1 || k > xs.length) _err(CellError.num);
    return xs[k - 1];
  },
  'SMALL': (a, ev) {
    final xs = _numbers(ev, a.sublist(0, 1))..sort();
    final k = ev.numArg(a, 1).ceil();
    if (k < 1 || k > xs.length) _err(CellError.num);
    return xs[k - 1];
  },
  'STDEV': (a, ev) => math.sqrt(_variance(_numbers(ev, a), true)),
  'STDEV.S': (a, ev) => math.sqrt(_variance(_numbers(ev, a), true)),
  'STDEVP': (a, ev) => math.sqrt(_variance(_numbers(ev, a), false)),
  'STDEV.P': (a, ev) => math.sqrt(_variance(_numbers(ev, a), false)),
  'VAR': (a, ev) => _variance(_numbers(ev, a), true),
  'VAR.S': (a, ev) => _variance(_numbers(ev, a), true),
  'VARP': (a, ev) => _variance(_numbers(ev, a), false),
  'VAR.P': (a, ev) => _variance(_numbers(ev, a), false),
  'SUMPRODUCT': (a, ev) {
    if (a.isEmpty) _err(CellError.value);
    final grids = [for (final n in a) ev.grid(ev.eval(n))];
    final rows = grids.first.length;
    final cols = rows == 0 ? 0 : grids.first.first.length;
    for (final g in grids) {
      if (g.length != rows || (rows > 0 && g.first.length != cols)) {
        _err(CellError.value);
      }
    }
    var sum = 0.0;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        var p = 1.0;
        for (final g in grids) {
          final v = g[y][x];
          if (v is CellError) _err(v);
          p *= v is double ? v : 0;
        }
        sum += p;
      }
    }
    return sum;
  },
  'SUBTOTAL': (a, ev) {
    final fn = ev.numArg(a, 0).toInt() % 100;
    const names = {
      1: 'AVERAGE', 2: 'COUNT', 3: 'COUNTA', 4: 'MAX', 5: 'MIN', 6: 'PRODUCT', //
      7: 'STDEV', 8: 'STDEVP', 9: 'SUM', 10: 'VAR', 11: 'VARP',
    };
    final name = names[fn];
    if (name == null) _err(CellError.value);
    return _aggregate(name, a.sublist(1), ev);
  },

  // --- logic -----------------------------------------------------------------
  'IF': (a, ev) {
    ev.argCount(a, 1, 3);
    final c = ev.boolean(ev.scalar(a[0]));
    if (c) {
      if (a.length < 2) return true;
      return a[1] is MissingNode ? 0.0 : ev.eval(a[1]);
    }
    if (a.length < 3) return false;
    return a[2] is MissingNode ? 0.0 : ev.eval(a[2]);
  },
  'IFS': (a, ev) {
    if (a.length < 2 || a.length.isOdd) _err(CellError.value);
    for (var i = 0; i < a.length; i += 2) {
      if (ev.boolean(ev.scalar(a[i]))) return ev.eval(a[i + 1]);
    }
    _err(CellError.na);
  },
  'SWITCH': (a, ev) {
    if (a.length < 3) _err(CellError.value);
    final v = ev.scalar(a[0]);
    if (v is CellError) return v;
    var i = 1;
    for (; i + 1 < a.length; i += 2) {
      final c = ev.scalar(a[i]);
      if (c is CellError) return c;
      if (ev.compareValues(v, c) == 0) return ev.eval(a[i + 1]);
    }
    if (i < a.length) return ev.eval(a[i]);
    _err(CellError.na);
  },
  'AND': (a, ev) {
    var any = false;
    var result = true;
    for (final v in ev.flatValues(a)) {
      if (v is CellError) _err(v);
      if (v is bool || v is double) {
        any = true;
        if (!ev.boolean(v)) result = false;
      } else if (v is String) {
        final u = v.toUpperCase();
        if (u == 'TRUE' || u == 'FALSE') {
          any = true;
          if (u == 'FALSE') result = false;
        }
      }
    }
    if (!any) _err(CellError.value);
    return result;
  },
  'OR': (a, ev) {
    var any = false;
    var result = false;
    for (final v in ev.flatValues(a)) {
      if (v is CellError) _err(v);
      if (v is bool || v is double) {
        any = true;
        if (ev.boolean(v)) result = true;
      } else if (v is String) {
        final u = v.toUpperCase();
        if (u == 'TRUE' || u == 'FALSE') {
          any = true;
          if (u == 'TRUE') result = true;
        }
      }
    }
    if (!any) _err(CellError.value);
    return result;
  },
  'XOR': (a, ev) {
    var count = 0;
    for (final v in ev.flatValues(a)) {
      if (v is CellError) _err(v);
      if ((v is bool || v is double) && ev.boolean(v)) count++;
    }
    return count.isOdd;
  },
  'NOT': (a, ev) => !ev.boolArg(a, 0),
  'TRUE': (a, ev) => true,
  'FALSE': (a, ev) => false,
  'IFERROR': (a, ev) {
    ev.argCount(a, 2, 2);
    final v = ev.scalar(a[0]);
    if (v is CellError) return a[1] is MissingNode ? 0.0 : ev.eval(a[1]);
    return v;
  },
  'IFNA': (a, ev) {
    ev.argCount(a, 2, 2);
    final v = ev.scalar(a[0]);
    if (v == CellError.na) return ev.eval(a[1]);
    return v;
  },
  'ISERROR': (a, ev) => ev.argValue(a, 0) is CellError,
  'ISERR': (a, ev) {
    final v = ev.argValue(a, 0);
    return v is CellError && v != CellError.na;
  },
  'ISNA': (a, ev) => ev.argValue(a, 0) == CellError.na,
  'ISBLANK': (a, ev) => ev.argValue(a, 0) == null,
  'ISNUMBER': (a, ev) => ev.argValue(a, 0) is double,
  'ISTEXT': (a, ev) => ev.argValue(a, 0) is String,
  'ISNONTEXT': (a, ev) => ev.argValue(a, 0) is! String,
  'ISLOGICAL': (a, ev) => ev.argValue(a, 0) is bool,
  'ISEVEN': (a, ev) => ev.numArg(a, 0).truncate().isEven,
  'ISODD': (a, ev) => ev.numArg(a, 0).truncate().isOdd,
  'NA': (a, ev) => CellError.na,
  'N': (a, ev) {
    final v = ev.argValue(a, 0);
    if (v is double) return v;
    if (v is bool) return v ? 1.0 : 0.0;
    if (v is CellError) return v;
    return 0.0;
  },
  'T': (a, ev) {
    final v = ev.argValue(a, 0);
    if (v is CellError) return v;
    return v is String ? v : '';
  },

  // --- text --------------------------------------------------------------------
  'LEN': (a, ev) => ev.textArg(a, 0).length.toDouble(),
  'LEFT': (a, ev) {
    final s = ev.textArg(a, 0);
    final n = ev.numArg(a, 1, 1).truncate();
    if (n < 0) _err(CellError.value);
    return s.substring(0, math.min(n, s.length));
  },
  'RIGHT': (a, ev) {
    final s = ev.textArg(a, 0);
    final n = ev.numArg(a, 1, 1).truncate();
    if (n < 0) _err(CellError.value);
    return s.substring(s.length - math.min(n, s.length));
  },
  'MID': (a, ev) {
    ev.argCount(a, 3, 3);
    final s = ev.textArg(a, 0);
    final start = ev.numArg(a, 1).truncate();
    final n = ev.numArg(a, 2).truncate();
    if (start < 1 || n < 0) _err(CellError.value);
    if (start > s.length) return '';
    return s.substring(start - 1, math.min(s.length, start - 1 + n));
  },
  'UPPER': (a, ev) => ev.textArg(a, 0).toUpperCase(),
  'LOWER': (a, ev) => ev.textArg(a, 0).toLowerCase(),
  'PROPER': (a, ev) => ev.textArg(a, 0).toLowerCase().replaceAllMapped(
      RegExp(r'(^|[^A-Za-zÀ-￿])([a-zà-￿])'),
      (m) => '${m[1]}${m[2]!.toUpperCase()}'),
  'TRIM': (a, ev) => ev.textArg(a, 0).trim().replaceAll(RegExp(r' {2,}'), ' '),
  'CLEAN': (a, ev) => ev.textArg(a, 0).replaceAll(RegExp(r'[\x00-\x1F]'), ''),
  'CONCATENATE': (a, ev) {
    final b = StringBuffer();
    for (var i = 0; i < a.length; i++) {
      b.write(ev.textArg(a, i, ''));
    }
    return b.toString();
  },
  'CONCAT': (a, ev) {
    final b = StringBuffer();
    for (final v in ev.flatValues(a)) {
      if (v is CellError) _err(v);
      b.write(ev.text(v));
    }
    return b.toString();
  },
  'TEXTJOIN': (a, ev) {
    ev.argCount(a, 3);
    final delim = ev.textArg(a, 0);
    final ignoreEmpty = ev.boolArg(a, 1);
    final parts = <String>[];
    for (final node in a.sublist(2)) {
      if (node is MissingNode) {
        if (!ignoreEmpty) parts.add('');
        continue;
      }
      final v = ev.eval(node);
      final values = v is RangeValue
          ? ev.grid(v).expand((r) => r)
          : v is ArrayValue
              ? v.rows.expand((r) => r)
              : [v];
      for (final x in values) {
        if (x is CellError) _err(x);
        final s = ev.text(x);
        if (ignoreEmpty && s.isEmpty) continue;
        parts.add(s);
      }
    }
    return parts.join(delim);
  },
  'REPT': (a, ev) {
    final s = ev.textArg(a, 0);
    final n = ev.numArg(a, 1).truncate();
    if (n < 0 || s.length * n > 32767) _err(CellError.value);
    return s * n;
  },
  'EXACT': (a, ev) => ev.textArg(a, 0) == ev.textArg(a, 1),
  'SUBSTITUTE': (a, ev) {
    ev.argCount(a, 3, 4);
    final s = ev.textArg(a, 0);
    final old = ev.textArg(a, 1);
    final rep = ev.textArg(a, 2);
    if (old.isEmpty) return s;
    if (!ev.hasArg(a, 3)) return s.replaceAll(old, rep);
    final nth = ev.numArg(a, 3).truncate();
    if (nth < 1) _err(CellError.value);
    var idx = -1;
    for (var i = 0; i < nth; i++) {
      idx = s.indexOf(old, idx + 1);
      if (idx < 0) return s;
    }
    return s.replaceRange(idx, idx + old.length, rep);
  },
  'REPLACE': (a, ev) {
    ev.argCount(a, 4, 4);
    final s = ev.textArg(a, 0);
    final start = ev.numArg(a, 1).truncate();
    final n = ev.numArg(a, 2).truncate();
    final rep = ev.textArg(a, 3);
    if (start < 1 || n < 0) _err(CellError.value);
    final st = math.min(start - 1, s.length);
    final en = math.min(st + n, s.length);
    return s.replaceRange(st, en, rep);
  },
  'FIND': (a, ev) {
    final find = ev.textArg(a, 0);
    final within = ev.textArg(a, 1);
    final start = ev.numArg(a, 2, 1).truncate();
    if (start < 1 || start > within.length + 1) _err(CellError.value);
    final i = within.indexOf(find, start - 1);
    if (i < 0) _err(CellError.value);
    return (i + 1).toDouble();
  },
  'SEARCH': (a, ev) {
    final find = ev.textArg(a, 0);
    final within = ev.textArg(a, 1);
    final start = ev.numArg(a, 2, 1).truncate();
    if (start < 1 || start > within.length + 1) _err(CellError.value);
    final re = RegExp(wildcardToRegex(find), caseSensitive: false, dotAll: true);
    final m = re.firstMatch(within.substring(start - 1));
    if (m == null) _err(CellError.value);
    return (m.start + start).toDouble();
  },
  'CHAR': (a, ev) {
    final n = ev.numArg(a, 0).truncate();
    if (n < 1 || n > 255) _err(CellError.value);
    return String.fromCharCode(n);
  },
  'CODE': (a, ev) {
    final s = ev.textArg(a, 0);
    if (s.isEmpty) _err(CellError.value);
    return s.codeUnitAt(0).toDouble();
  },
  'VALUE': (a, ev) {
    final v = ev.argValue(a, 0);
    if (v is double) return v;
    if (v is CellError) return v;
    final d = parseNumberText(ev.text(v));
    if (d != null) return d;
    final date = parseDateText(ev.text(v));
    if (date != null) return _serial(ev, date);
    _err(CellError.value);
  },
  'TEXT': (a, ev) {
    ev.argCount(a, 2, 2);
    var v = ev.argValue(a, 0);
    if (v is CellError) return v;
    if (v is String) v = parseNumberText(v) ?? v;
    final fmt = ev.textArg(a, 1);
    return NumberFormats.format(v ?? 0.0, fmt, date1904: ev.workbook.date1904).text;
  },
  'FIXED': (a, ev) {
    final x = ev.numArg(a, 0);
    final d = ev.numArg(a, 1, 2).truncate().clamp(0, 15);
    final noCommas = ev.boolArg(a, 2, false);
    final code = '${noCommas ? '0' : '#,##0'}${d > 0 ? '.${'0' * d}' : ''}';
    return NumberFormats.format(x, code).text;
  },

  // --- dates -------------------------------------------------------------------
  'TODAY': (a, ev) => ev.todaySerial,
  'NOW': (a, ev) => ev.nowSerial,
  'DATE': (a, ev) {
    ev.argCount(a, 3, 3);
    var y = ev.numArg(a, 0).truncate();
    final m = ev.numArg(a, 1).truncate();
    final d = ev.numArg(a, 2).truncate();
    if (y < 1900) y += 1900;
    if (y > 9999) _err(CellError.num);
    return _serial(ev, DateTime.utc(y, m, d));
  },
  'TIME': (a, ev) {
    final h = ev.numArg(a, 0);
    final m = ev.numArg(a, 1);
    final s = ev.numArg(a, 2);
    final t = (h * 3600 + m * 60 + s) / 86400;
    return t - t.floorToDouble();
  },
  'YEAR': (a, ev) => _date(ev, ev.numArg(a, 0)).year.toDouble(),
  'MONTH': (a, ev) => _date(ev, ev.numArg(a, 0)).month.toDouble(),
  'DAY': (a, ev) => _date(ev, ev.numArg(a, 0)).day.toDouble(),
  'HOUR': (a, ev) => _date(ev, ev.numArg(a, 0)).hour.toDouble(),
  'MINUTE': (a, ev) => _date(ev, ev.numArg(a, 0)).minute.toDouble(),
  'SECOND': (a, ev) => _date(ev, ev.numArg(a, 0)).second.toDouble(),
  'WEEKDAY': (a, ev) {
    final d = _date(ev, ev.numArg(a, 0));
    final type = ev.numArg(a, 1, 1).truncate();
    final wd = d.weekday; // Mon=1..Sun=7
    switch (type) {
      case 1:
        return (wd % 7 + 1).toDouble();
      case 2:
        return wd.toDouble();
      case 3:
        return (wd - 1).toDouble();
    }
    _err(CellError.num);
  },
  'EDATE': (a, ev) {
    final d = _date(ev, ev.numArg(a, 0));
    final m = ev.numArg(a, 1).truncate();
    final target = DateTime.utc(d.year, d.month + m, 1);
    final last = DateTime.utc(target.year, target.month + 1, 0).day;
    return _serial(ev, DateTime.utc(target.year, target.month, math.min(d.day, last)));
  },
  'EOMONTH': (a, ev) {
    final d = _date(ev, ev.numArg(a, 0));
    final m = ev.numArg(a, 1).truncate();
    return _serial(ev, DateTime.utc(d.year, d.month + m + 1, 0));
  },
  'DAYS': (a, ev) =>
      (ev.numArg(a, 0).floorToDouble() - ev.numArg(a, 1).floorToDouble()),
  'DATEVALUE': (a, ev) {
    final d = parseDateText(ev.textArg(a, 0));
    if (d == null) _err(CellError.value);
    return _serial(ev, DateTime.utc(d.year, d.month, d.day));
  },

  // --- conditional aggregates ----------------------------------------------------
  'SUMIF': (a, ev) {
    ev.argCount(a, 2, 3);
    final range = ev.rangeArg(a, 0);
    final crit = _Criteria(ev.argValue(a, 1));
    final target = ev.hasArg(a, 2) ? ev.rangeArg(a, 2) : range;
    var s = 0.0;
    for (final (v, dy, dx) in _cells(ev, range)) {
      if (!crit.matches(v)) continue;
      final t = ev.cellValue(target.sheet, target.r1 + dy, target.c1 + dx);
      if (t is double) s += t;
      if (t is CellError) _err(t);
    }
    return s;
  },
  'COUNTIF': (a, ev) {
    ev.argCount(a, 2, 2);
    final range = ev.rangeArg(a, 0);
    final crit = _Criteria(ev.argValue(a, 1));
    var n = 0;
    for (final (v, _, _) in _cells(ev, range)) {
      if (crit.matches(v)) n++;
    }
    final outside = range.rows * range.cols - _usedArea(range);
    if (outside > 0 && crit.matches(null)) n += outside;
    return n.toDouble();
  },
  'AVERAGEIF': (a, ev) {
    ev.argCount(a, 2, 3);
    final range = ev.rangeArg(a, 0);
    final crit = _Criteria(ev.argValue(a, 1));
    final target = ev.hasArg(a, 2) ? ev.rangeArg(a, 2) : range;
    var s = 0.0;
    var n = 0;
    for (final (v, dy, dx) in _cells(ev, range)) {
      if (!crit.matches(v)) continue;
      final t = ev.cellValue(target.sheet, target.r1 + dy, target.c1 + dx);
      if (t is double) {
        s += t;
        n++;
      }
    }
    if (n == 0) _err(CellError.div0);
    return s / n;
  },
  'SUMIFS': (a, ev) {
    if (a.length < 3 || a.length.isEven) _err(CellError.value);
    final target = ev.rangeArg(a, 0);
    final conds = [
      for (var i = 1; i + 1 < a.length; i += 2)
        (ev.rangeArg(a, i), _Criteria(ev.argValue(a, i + 1))),
    ];
    var s = 0.0;
    final first = conds.first.$1;
    if (target.rows != first.rows || target.cols != first.cols) _err(CellError.value);
    _ifs(ev, conds, target, (v) {
      if (v is double) s += v;
    });
    return s;
  },
  'COUNTIFS': (a, ev) {
    if (a.length < 2 || a.length.isOdd) _err(CellError.value);
    final conds = [
      for (var i = 0; i + 1 < a.length; i += 2)
        (ev.rangeArg(a, i), _Criteria(ev.argValue(a, i + 1))),
    ];
    var n = 0;
    final extra = _ifs(ev, conds, null, (_) => n++);
    n += extra;
    return n.toDouble();
  },
  'AVERAGEIFS': (a, ev) {
    if (a.length < 3 || a.length.isEven) _err(CellError.value);
    final target = ev.rangeArg(a, 0);
    final conds = [
      for (var i = 1; i + 1 < a.length; i += 2)
        (ev.rangeArg(a, i), _Criteria(ev.argValue(a, i + 1))),
    ];
    var s = 0.0;
    var n = 0;
    _ifs(ev, conds, target, (v) {
      if (v is double) {
        s += v;
        n++;
      }
    });
    if (n == 0) _err(CellError.div0);
    return s / n;
  },
  'MAXIFS': (a, ev) {
    final target = ev.rangeArg(a, 0);
    final conds = [
      for (var i = 1; i + 1 < a.length; i += 2)
        (ev.rangeArg(a, i), _Criteria(ev.argValue(a, i + 1))),
    ];
    if (conds.isEmpty) _err(CellError.value);
    double? m;
    _ifs(ev, conds, target, (v) {
      if (v is double) m = m == null ? v : math.max(m!, v);
    });
    return m ?? 0.0;
  },
  'MINIFS': (a, ev) {
    final target = ev.rangeArg(a, 0);
    final conds = [
      for (var i = 1; i + 1 < a.length; i += 2)
        (ev.rangeArg(a, i), _Criteria(ev.argValue(a, i + 1))),
    ];
    if (conds.isEmpty) _err(CellError.value);
    double? m;
    _ifs(ev, conds, target, (v) {
      if (v is double) m = m == null ? v : math.min(m!, v);
    });
    return m ?? 0.0;
  },

  // --- lookup & reference ------------------------------------------------------------
  'VLOOKUP': (a, ev) {
    ev.argCount(a, 3, 4);
    final lookup = ev.argValue(a, 0);
    if (lookup is CellError) return lookup;
    final table = ev.eval(a[1]);
    final col = ev.numArg(a, 2).truncate();
    final approx = ev.boolArg(a, 3, true);
    final g = ev.grid(table is RangeValue
        ? RangeValue(table.sheet, table.r1, table.c1, table.usedR2 < table.r1 ? table.r1 : table.usedR2, table.c2)
        : table);
    if (col < 1) _err(CellError.value);
    if (g.isNotEmpty && col > g.first.length) _err(CellError.ref);
    final firstCol = [for (final r in g) r.isEmpty ? null : r.first];
    final idx = _matchIn(ev, firstCol, lookup, approx ? 1 : 0);
    if (idx < 0) _err(CellError.na);
    return g[idx][col - 1];
  },
  'HLOOKUP': (a, ev) {
    ev.argCount(a, 3, 4);
    final lookup = ev.argValue(a, 0);
    if (lookup is CellError) return lookup;
    final table = ev.eval(a[1]);
    final row = ev.numArg(a, 2).truncate();
    final approx = ev.boolArg(a, 3, true);
    final g = ev.grid(table is RangeValue
        ? RangeValue(table.sheet, table.r1, table.c1, table.r2, table.usedC2 < table.c1 ? table.c1 : table.usedC2)
        : table);
    if (row < 1) _err(CellError.value);
    if (row > g.length) _err(CellError.ref);
    final idx = _matchIn(ev, g.first, lookup, approx ? 1 : 0);
    if (idx < 0) _err(CellError.na);
    return g[row - 1][idx];
  },
  'MATCH': (a, ev) {
    ev.argCount(a, 2, 3);
    final lookup = ev.argValue(a, 0);
    if (lookup is CellError) return lookup;
    final values = _vector(ev, ev.eval(a[1]));
    final type = ev.numArg(a, 2, 1).sign.toInt();
    final idx = _matchIn(ev, values, lookup, type);
    if (idx < 0) _err(CellError.na);
    return (idx + 1).toDouble();
  },
  'XLOOKUP': (a, ev) {
    ev.argCount(a, 3, 6);
    final lookup = ev.argValue(a, 0);
    if (lookup is CellError) return lookup;
    final keys = _vector(ev, ev.eval(a[1]));
    final results = _vector(ev, ev.eval(a[2]));
    final idx = _matchIn(ev, keys, lookup, 0);
    if (idx < 0 || idx >= results.length) {
      if (ev.hasArg(a, 3)) return ev.eval(a[3]);
      _err(CellError.na);
    }
    return results[idx];
  },
  'INDEX': (a, ev) {
    ev.argCount(a, 2, 3);
    final ref = ev.eval(a[0]);
    if (ref is CellError) return ref;
    var r = ev.numArg(a, 1).truncate();
    var c = ev.hasArg(a, 2) ? ev.numArg(a, 2).truncate() : 0;
    if (ref is RangeValue) {
      if (ref.rows == 1 && a.length == 2) {
        c = r;
        r = 1;
      } else if (a.length == 2 && ref.cols == 1) {
        c = 1;
      }
      if (r < 0 || c < 0 || r > ref.rows || c > ref.cols) _err(CellError.ref);
      final r1 = r == 0 ? ref.r1 : ref.r1 + r - 1;
      final r2 = r == 0 ? ref.r2 : r1;
      final c1 = c == 0 ? ref.c1 : ref.c1 + c - 1;
      final c2 = c == 0 ? ref.c2 : c1;
      return RangeValue(ref.sheet, r1, c1, r2, c2);
    }
    final g = ev.grid(ref);
    if (g.length == 1 && a.length == 2) {
      c = r;
      r = 1;
    }
    if (r < 1 || r > g.length) _err(CellError.ref);
    final row = g[r - 1];
    if (c == 0) c = 1;
    if (c < 1 || c > row.length) _err(CellError.ref);
    return row[c - 1];
  },
  'CHOOSE': (a, ev) {
    ev.argCount(a, 2);
    final i = ev.numArg(a, 0).truncate();
    if (i < 1 || i >= a.length) _err(CellError.value);
    return ev.eval(a[i]);
  },
  'ROW': (a, ev) {
    if (a.isEmpty || a[0] is MissingNode) return (ev.row + 1).toDouble();
    return (ev.rangeArg(a, 0).r1 + 1).toDouble();
  },
  'COLUMN': (a, ev) {
    if (a.isEmpty || a[0] is MissingNode) return (ev.col + 1).toDouble();
    return (ev.rangeArg(a, 0).c1 + 1).toDouble();
  },
  'ROWS': (a, ev) {
    final v = ev.eval(a[0]);
    if (v is RangeValue) return v.rows.toDouble();
    return ev.grid(v).length.toDouble();
  },
  'COLUMNS': (a, ev) {
    final v = ev.eval(a[0]);
    if (v is RangeValue) return v.cols.toDouble();
    final g = ev.grid(v);
    return (g.isEmpty ? 0 : g.first.length).toDouble();
  },
};

final _isoDate = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?$');
final _usDate = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?)?$');
final _monthNameDate = RegExp(r'^(\d{1,2})[- ]([A-Za-z]{3,9})[- ,]+(\d{2,4})$');

/// Parses common date spellings (`2024-01-31`, `1/31/2024`, `31-Jan-2024`).
DateTime? parseDateText(String text) {
  final t = text.trim();
  var m = _isoDate.firstMatch(t);
  if (m != null) {
    final y = int.parse(m[1]!);
    final mo = int.parse(m[2]!);
    final d = int.parse(m[3]!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime.utc(y, mo, d, int.tryParse(m[4] ?? '') ?? 0,
        int.tryParse(m[5] ?? '') ?? 0, int.tryParse(m[6] ?? '') ?? 0);
  }
  m = _usDate.firstMatch(t);
  if (m != null) {
    final mo = int.parse(m[1]!);
    final d = int.parse(m[2]!);
    var y = int.parse(m[3]!);
    if (y < 100) y += y < 30 ? 2000 : 1900;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    var h = int.tryParse(m[4] ?? '') ?? 0;
    final ampm = m[7]?.toUpperCase();
    if (ampm == 'PM' && h < 12) h += 12;
    if (ampm == 'AM' && h == 12) h = 0;
    return DateTime.utc(y, mo, d, h, int.tryParse(m[5] ?? '') ?? 0,
        int.tryParse(m[6] ?? '') ?? 0);
  }
  m = _monthNameDate.firstMatch(t);
  if (m != null) {
    final name = m[2]!.toLowerCase();
    final idx = NumberFormats.monthNames
        .indexWhere((n) => n.toLowerCase().startsWith(name.substring(0, 3)));
    if (idx < 0) return null;
    var y = int.parse(m[3]!);
    if (y < 100) y += y < 30 ? 2000 : 1900;
    return DateTime.utc(y, idx + 1, int.parse(m[1]!));
  }
  return null;
}
