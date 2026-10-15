import 'dart:math' as math;

import 'cell.dart';

/// Display text plus an optional colour from a `[Red]`-style section.
class FormattedValue {
  const FormattedValue(this.text, [this.color]);
  final String text;

  /// 0xAARRGGBB
  final int? color;
}

/// Pragmatic Excel number-format engine: General, fixed decimals, thousands
/// separators, percentages, scientific, fractions, currency literals, dates,
/// times, elapsed time, colours and simple conditions.
abstract final class NumberFormats {
  static const general = 'General';

  static const builtin = <int, String>{
    0: 'General',
    1: '0',
    2: '0.00',
    3: '#,##0',
    4: '#,##0.00',
    5: r'"$"#,##0_);\("$"#,##0\)',
    6: r'"$"#,##0_);[Red]\("$"#,##0\)',
    7: r'"$"#,##0.00_);\("$"#,##0.00\)',
    8: r'"$"#,##0.00_);[Red]\("$"#,##0.00\)',
    9: '0%',
    10: '0.00%',
    11: '0.00E+00',
    12: '# ?/?',
    13: '# ??/??',
    14: 'm/d/yyyy',
    15: 'd-mmm-yy',
    16: 'd-mmm',
    17: 'mmm-yy',
    18: 'h:mm AM/PM',
    19: 'h:mm:ss AM/PM',
    20: 'h:mm',
    21: 'h:mm:ss',
    22: 'm/d/yyyy h:mm',
    37: '#,##0 ;(#,##0)',
    38: '#,##0 ;[Red](#,##0)',
    39: '#,##0.00;(#,##0.00)',
    40: '#,##0.00;[Red](#,##0.00)',
    41: r'_(* #,##0_);_(* \(#,##0\);_(* "-"_);_(@_)',
    42: r'_("$"* #,##0_);_("$"* \(#,##0\);_("$"* "-"_);_(@_)',
    43: r'_(* #,##0.00_);_(* \(#,##0.00\);_(* "-"??_);_(@_)',
    44: r'_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)',
    45: 'mm:ss',
    46: '[h]:mm:ss',
    47: 'mm:ss.0',
    48: '##0.0E+0',
    49: '@',
  };

  /// Format code for a built-in id (East-Asian date ids map to a date).
  static String codeForId(int id) {
    final c = builtin[id];
    if (c != null) return c;
    if ((id >= 27 && id <= 36) || (id >= 50 && id <= 58)) return 'yyyy/m/d';
    if (id == 59) return 't0';
    return general;
  }

  static final Map<String, int> _idByCode = () {
    final m = <String, int>{};
    builtin.forEach((id, code) => m.putIfAbsent(code, () => id));
    return m;
  }();

  /// Built-in id for [code] if Excel knows it without a `<numFmt>` entry.
  static int? builtinIdForCode(String code) => _idByCode[code];

  static final Map<String, _Format> _cache = {};

  static _Format _compile(String code) {
    final cached = _cache[code];
    if (cached != null) return cached;
    if (_cache.length > 2000) _cache.clear();
    _Format f;
    try {
      f = _Format.parse(code);
    } catch (_) {
      f = _Format.parse('General');
    }
    return _cache[code] = f;
  }

  static bool isDateFormat(String code) => _compile(code).isDate;
  static bool isTimeOnlyFormat(String code) => _compile(code).isTimeOnly;
  static bool isPercentFormat(String code) => _compile(code).isPercent;
  static bool isTextFormat(String code) => code.trim() == '@';

  /// Formats [value] for display.
  static FormattedValue format(Object? value, String code,
      {bool date1904 = false}) {
    if (value == null) return const FormattedValue('');
    if (value is bool) return FormattedValue(value ? 'TRUE' : 'FALSE');
    if (value is CellError) return FormattedValue(value.code);
    try {
      final fmt = _compile(code);
      if (value is String) return fmt.formatText(value);
      if (value is num) return fmt.formatNumber(value.toDouble(), date1904);
    } catch (_) {
      // Unusual format codes must never break rendering.
      if (value is num) return FormattedValue(formatGeneral(value.toDouble()));
      if (value is String) return FormattedValue(value);
    }
    return FormattedValue(value.toString());
  }

  /// Excel "General" display: up to 10 significant digits, exponent for very
  /// large or small magnitudes.
  static String formatGeneral(double v) {
    if (v.isNaN) return '#NUM!';
    if (v.isInfinite) return '#NUM!';
    if (v == 0) return '0';
    final a = v.abs();
    if (a >= 1e11 || a < 1e-9) {
      return _expString(v, 5, 2, trimZeros: true);
    }
    if (v == v.truncateToDouble() && a < 1e15) {
      return v.toInt().toString();
    }
    final intDigits = a >= 1 ? (math.log(a) / math.ln10).floor() + 1 : 1;
    final decimals = (10 - intDigits).clamp(0, 10);
    var s = _toFixed(v, decimals);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    if (s == '-0') s = '0';
    return s;
  }

  /// Full precision (15 significant digits) for editing and CSV export.
  static String numberToPlainString(double v) {
    if (v.isNaN || v.isInfinite) return '#NUM!';
    if (v == 0) return '0';
    if (v == v.truncateToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    var s = v.toStringAsPrecision(15);
    if (s.contains('e')) {
      final parts = s.split('e');
      var m = parts[0];
      if (m.contains('.')) {
        m = m.replaceFirst(RegExp(r'0+$'), '');
        if (m.endsWith('.')) m = m.substring(0, m.length - 1);
      }
      final e = int.parse(parts[1]);
      if (e > -7 && e < 21) {
        // Prefer plain notation for moderate exponents.
        final d = double.parse(s);
        var plain = d.toStringAsFixed(e < 0 ? (14 - e).clamp(0, 20) : 0);
        if (plain.contains('.')) {
          plain = plain.replaceFirst(RegExp(r'0+$'), '');
          if (plain.endsWith('.')) plain = plain.substring(0, plain.length - 1);
        }
        return plain;
      }
      return '${m}E${e < 0 ? '-' : '+'}${e.abs().toString().padLeft(2, '0')}';
    }
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _toFixed(double v, int decimals) {
    if (decimals > 20) decimals = 20;
    // Round on the 15-significant-digit representation first so 2.675 shows
    // as 2.68 like Excel instead of the binary 2.67499.
    final adj = double.parse(v.toStringAsPrecision(15));
    final scaled = adj * math.pow(10, decimals);
    if (scaled.abs() < 9e15) {
      final r = _roundHalfAway(scaled);
      final neg = r < 0;
      var digits = r.abs().toStringAsFixed(0);
      if (decimals > 0) {
        digits = digits.padLeft(decimals + 1, '0');
        digits =
            '${digits.substring(0, digits.length - decimals)}.${digits.substring(digits.length - decimals)}';
      }
      return neg && r != 0 ? '-$digits' : digits;
    }
    return adj.toStringAsFixed(decimals);
  }

  static double _roundHalfAway(double x) =>
      x < 0 ? -(x.abs() + 0.5).floorToDouble() : (x + 0.5).floorToDouble();

  static String _expString(double v, int decimals, int expDigits,
      {bool trimZeros = false, bool plusSign = true}) {
    if (v == 0) {
      final m = decimals > 0 && !trimZeros ? '0.${'0' * decimals}' : '0';
      return '${m}E+${'0' * expDigits}';
    }
    var e = (math.log(v.abs()) / math.ln10).floor();
    var m = v / math.pow(10, e);
    var ms = _toFixed(m, decimals);
    if (double.parse(ms).abs() >= 10) {
      e += 1;
      m = v / math.pow(10, e);
      ms = _toFixed(m, decimals);
    }
    if (trimZeros && ms.contains('.')) {
      ms = ms.replaceFirst(RegExp(r'0+$'), '');
      if (ms.endsWith('.')) ms = ms.substring(0, ms.length - 1);
    }
    final sign = e < 0 ? '-' : (plusSign ? '+' : '');
    return '${ms}E$sign${e.abs().toString().padLeft(expDigits, '0')}';
  }

  // ---------------------------------------------------------------------------
  // Dates

  /// Converts an Excel serial to a UTC [DateTime]; null when out of range.
  static DateTime? serialToDateTime(double serial, {bool date1904 = false}) {
    if (serial.isNaN || serial.isInfinite) return null;
    DateTime base;
    if (date1904) {
      base = DateTime.utc(1904, 1, 1);
    } else {
      if (serial < 0) return null;
      base = serial < 60 ? DateTime.utc(1899, 12, 31) : DateTime.utc(1899, 12, 30);
    }
    if (serial > 2958465) return null; // > 9999-12-31
    final ms = (serial * 86400000).round();
    return base.add(Duration(milliseconds: ms));
  }

  static double dateTimeToSerial(DateTime dt, {bool date1904 = false}) {
    final utc = DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute,
        dt.second, dt.millisecond);
    if (date1904) {
      return utc.difference(DateTime.utc(1904, 1, 1)).inMilliseconds / 86400000;
    }
    var days = utc.difference(DateTime.utc(1899, 12, 30)).inMilliseconds / 86400000;
    if (days < 61) days -= 1;
    return days;
  }

  static const monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];
  static const dayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
    'Sunday',
  ];
}

// -----------------------------------------------------------------------------
// Format compilation

enum _T { lit, d0, dHash, dQ, point, comma, percent, exp, slash, at, general, date }

class _Tok {
  const _Tok(this.t, [this.s = '']);
  final _T t;
  final String s;

  bool get isDigit => t == _T.d0 || t == _T.dHash || t == _T.dQ;
}

enum _Kind { general, number, date, text, literal }

class _Cond {
  const _Cond(this.op, this.value);
  final String op;
  final double value;

  bool test(double v) => switch (op) {
        '<' => v < value,
        '<=' => v <= value,
        '>' => v > value,
        '>=' => v >= value,
        '<>' => v != value,
        _ => v == value,
      };
}

const _colorNames = <String, int>{
  'black': 0xFF000000,
  'blue': 0xFF0000FF,
  'cyan': 0xFF00FFFF,
  'green': 0xFF008000,
  'magenta': 0xFFFF00FF,
  'red': 0xFFFF0000,
  'white': 0xFFFFFFFF,
  'yellow': 0xFFFFFF00,
};

class _Section {
  _Section(this.toks, this.kind, this.color, this.cond);
  final List<_Tok> toks;
  final _Kind kind;
  final int? color;
  final _Cond? cond;
  bool hasAmPm = false;
  bool hasSubSecondsOrElapsed = false;
}

class _Format {
  _Format(this.sections);

  final List<_Section> sections;

  bool get isDate => sections.isNotEmpty && sections.first.kind == _Kind.date;

  bool get isTimeOnly {
    if (!isDate) return false;
    for (final t in sections.first.toks) {
      if (t.t == _T.date) {
        final c = t.s[0];
        // 'm' tokens that survived minute resolution are months.
        if (c == 'y' || c == 'd' || c == 'm') return false;
      }
    }
    return true;
  }

  bool get isPercent =>
      sections.isNotEmpty && sections.first.toks.any((t) => t.t == _T.percent);

  static _Format parse(String code) {
    final raw = _splitSections(code);
    final sections = <_Section>[];
    for (final s in raw) {
      sections.add(_parseSection(s));
    }
    if (sections.isEmpty) sections.add(_parseSection('General'));
    return _Format(sections);
  }

  static List<String> _splitSections(String code) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    var inBracket = false;
    for (var i = 0; i < code.length; i++) {
      final ch = code[i];
      if (ch == '"' && !inBracket) inQuote = !inQuote;
      if (!inQuote) {
        if (ch == '[') inBracket = true;
        if (ch == ']') inBracket = false;
        if (ch == '\\' && i + 1 < code.length) {
          buf
            ..write(ch)
            ..write(code[i + 1]);
          i++;
          continue;
        }
        if (ch == ';' && !inBracket) {
          out.add(buf.toString());
          buf.clear();
          continue;
        }
      }
      buf.write(ch);
    }
    out.add(buf.toString());
    return out;
  }

  static _Section _parseSection(String s) {
    final toks = <_Tok>[];
    int? color;
    _Cond? cond;
    var i = 0;
    final n = s.length;
    final lower = s.toLowerCase();
    while (i < n) {
      final ch = s[i];
      final lc = lower[i];
      if (ch == '"') {
        final end = s.indexOf('"', i + 1);
        final text = end < 0 ? s.substring(i + 1) : s.substring(i + 1, end);
        toks.add(_Tok(_T.lit, text));
        i = end < 0 ? n : end + 1;
      } else if (ch == '\\') {
        if (i + 1 < n) toks.add(_Tok(_T.lit, s[i + 1]));
        i += 2;
      } else if (ch == '_') {
        toks.add(const _Tok(_T.lit, ' '));
        i += 2;
      } else if (ch == '*') {
        i += 2;
      } else if (ch == '[') {
        final end = s.indexOf(']', i + 1);
        final inner = end < 0 ? s.substring(i + 1) : s.substring(i + 1, end);
        i = end < 0 ? n : end + 1;
        final il = inner.toLowerCase();
        if (_colorNames.containsKey(il)) {
          color = _colorNames[il];
        } else if (il.startsWith('color')) {
          color = null;
        } else if (inner.startsWith(r'$')) {
          final dash = inner.indexOf('-');
          final sym = dash < 0 ? inner.substring(1) : inner.substring(1, dash);
          if (sym.isNotEmpty) toks.add(_Tok(_T.lit, sym));
        } else if (RegExp(r'^(<=|>=|<>|<|>|=)\s*-?[\d.]+$').hasMatch(inner)) {
          final m = RegExp(r'^(<=|>=|<>|<|>|=)\s*(-?[\d.]+)$').firstMatch(inner)!;
          cond = _Cond(m.group(1)!, double.tryParse(m.group(2)!) ?? 0);
        } else if (RegExp(r'^(h+|m+|s+)$').hasMatch(il)) {
          toks.add(_Tok(_T.date, '[${il[0]}]'));
        }
      } else if (lower.startsWith('general', i)) {
        toks.add(const _Tok(_T.general));
        i += 7;
      } else if (ch == '0') {
        toks.add(const _Tok(_T.d0));
        i++;
      } else if (ch == '#') {
        toks.add(const _Tok(_T.dHash));
        i++;
      } else if (ch == '?') {
        toks.add(const _Tok(_T.dQ));
        i++;
      } else if (ch == '.') {
        toks.add(const _Tok(_T.point));
        i++;
      } else if (ch == ',') {
        toks.add(const _Tok(_T.comma));
        i++;
      } else if (ch == '%') {
        toks.add(const _Tok(_T.percent));
        i++;
      } else if ((lc == 'e') &&
          i + 1 < n &&
          (s[i + 1] == '+' || s[i + 1] == '-')) {
        toks.add(_Tok(_T.exp, s[i + 1]));
        i += 2;
      } else if (ch == '/') {
        toks.add(const _Tok(_T.slash));
        i++;
      } else if (ch == '@') {
        toks.add(const _Tok(_T.at));
        i++;
      } else if (lower.startsWith('am/pm', i)) {
        toks.add(const _Tok(_T.date, 'AM/PM'));
        i += 5;
      } else if (lower.startsWith('a/p', i)) {
        toks.add(const _Tok(_T.date, 'A/P'));
        i += 3;
      } else if (lc == 'y' || lc == 'm' || lc == 'd' || lc == 'h' || lc == 's') {
        var j = i;
        while (j < n && lower[j] == lc) {
          j++;
        }
        toks.add(_Tok(_T.date, lower.substring(i, j)));
        i = j;
      } else if (lc == 'b' && i + 1 < n && (s[i + 1] == '1' || s[i + 1] == '2')) {
        i += 2;
      } else if (lc == 'e' || lc == 'g') {
        // Era tokens: treat 'e' as a 4-digit year, ignore 'g'.
        if (lc == 'e') toks.add(const _Tok(_T.date, 'yyyy'));
        i++;
      } else {
        toks.add(_Tok(_T.lit, ch));
        i++;
      }
    }

    final hasDate = toks.any((t) => t.t == _T.date);
    if (hasDate) {
      final out = <_Tok>[];
      var lastWasSeconds = false;
      for (var k = 0; k < toks.length; k++) {
        final t = toks[k];
        if (t.t == _T.date) {
          out.add(t);
          lastWasSeconds = t.s.startsWith('s') || t.s == '[s]';
          continue;
        }
        if (t.t == _T.point && lastWasSeconds) {
          var d = 0;
          while (k + 1 < toks.length && toks[k + 1].t == _T.d0) {
            d++;
            k++;
          }
          out.add(_Tok(_T.date, '.${'0' * d}'));
          lastWasSeconds = false;
          continue;
        }
        lastWasSeconds = false;
        switch (t.t) {
          case _T.lit:
            out.add(t);
          case _T.slash:
            out.add(const _Tok(_T.lit, '/'));
          case _T.point:
            out.add(const _Tok(_T.lit, '.'));
          case _T.comma:
            out.add(const _Tok(_T.lit, ','));
          case _T.percent:
            out.add(const _Tok(_T.lit, '%'));
          case _T.d0:
            out.add(const _Tok(_T.lit, '0'));
          default:
            break;
        }
      }
      // Resolve month vs minute.
      final resolved = <_Tok>[];
      for (var k = 0; k < out.length; k++) {
        final t = out[k];
        if (t.t == _T.date && (t.s == 'm' || t.s == 'mm')) {
          var minute = false;
          for (var p = k - 1; p >= 0; p--) {
            final q = out[p];
            if (q.t != _T.date) continue;
            minute = q.s.startsWith('h') || q.s == '[h]';
            break;
          }
          if (!minute) {
            for (var p = k + 1; p < out.length; p++) {
              final q = out[p];
              if (q.t != _T.date) continue;
              minute = q.s.startsWith('s') || q.s == '[s]';
              break;
            }
          }
          resolved.add(minute ? _Tok(_T.date, t.s == 'm' ? 'n' : 'nn') : t);
        } else {
          resolved.add(t);
        }
      }
      final sec = _Section(resolved, _Kind.date, color, cond);
      sec.hasAmPm = resolved.any((t) => t.t == _T.date && (t.s == 'AM/PM' || t.s == 'A/P'));
      sec.hasSubSecondsOrElapsed = resolved.any((t) =>
          t.t == _T.date && (t.s.startsWith('.') || t.s.startsWith('[')));
      return sec;
    }
    if (toks.any((t) => t.isDigit)) return _Section(toks, _Kind.number, color, cond);
    if (toks.any((t) => t.t == _T.general)) {
      return _Section(toks, _Kind.general, color, cond);
    }
    if (toks.any((t) => t.t == _T.at)) return _Section(toks, _Kind.text, color, cond);
    return _Section(toks, _Kind.literal, color, cond);
  }

  FormattedValue formatText(String text) {
    _Section? sec;
    if (sections.length >= 4) {
      sec = sections[3];
    } else if (sections.length == 1 && sections[0].kind == _Kind.text) {
      sec = sections[0];
    }
    if (sec == null) return FormattedValue(text);
    final b = StringBuffer();
    for (final t in sec.toks) {
      if (t.t == _T.at) {
        b.write(text);
      } else if (t.t == _T.lit) {
        b.write(t.s);
      }
    }
    return FormattedValue(b.toString(), sec.color);
  }

  FormattedValue formatNumber(double v, bool date1904) {
    if (v.isNaN || v.isInfinite) return const FormattedValue('#NUM!');
    _Section sec;
    var value = v;
    var useAbs = false;
    final hasConds = sections.any((s) => s.cond != null);
    if (hasConds) {
      _Section? chosen;
      var idx = 0;
      for (var i = 0; i < sections.length && i < 3; i++) {
        final s = sections[i];
        if (s.kind == _Kind.text) continue;
        if (s.cond == null || s.cond!.test(v)) {
          chosen = s;
          idx = i;
          break;
        }
      }
      chosen ??= sections.first;
      sec = chosen;
      useAbs = idx > 0 && v < 0;
    } else if (sections.length == 1 || sections[1].kind == _Kind.text) {
      sec = sections[0];
    } else if (v > 0) {
      sec = sections[0];
    } else if (v < 0) {
      sec = sections[1];
      useAbs = true;
    } else {
      sec = sections.length >= 3 && sections[2].kind != _Kind.text
          ? sections[2]
          : sections[0];
    }
    if (useAbs) value = value.abs();

    switch (sec.kind) {
      case _Kind.general:
        final b = StringBuffer();
        for (final t in sec.toks) {
          if (t.t == _T.general) {
            b.write(NumberFormats.formatGeneral(value));
          } else if (t.t == _T.lit) {
            b.write(t.s);
          }
        }
        return FormattedValue(b.toString(), sec.color);
      case _Kind.date:
        return FormattedValue(_formatDate(sec, value, date1904), sec.color);
      case _Kind.number:
        return FormattedValue(_formatNum(sec, value), sec.color);
      case _Kind.text:
        return FormattedValue(NumberFormats.formatGeneral(value), sec.color);
      case _Kind.literal:
        final b = StringBuffer();
        for (final t in sec.toks) {
          if (t.t == _T.lit) b.write(t.s);
        }
        return FormattedValue(b.toString(), sec.color);
    }
  }

  // -------------------------------------------------------------------------

  String _formatNum(_Section sec, double v) {
    final toks = sec.toks;
    final neg = v < 0;
    var a = v.abs();

    final pointIdx = toks.indexWhere((t) => t.t == _T.point);
    final expIdx = toks.indexWhere((t) => t.t == _T.exp);
    final slashIdx = toks.indexWhere((t) => t.t == _T.slash);
    final percents = toks.where((t) => t.t == _T.percent).length;
    for (var i = 0; i < percents; i++) {
      a *= 100;
    }

    // Integer region ends at the point, the exponent or the end.
    final intEnd = pointIdx >= 0
        ? pointIdx
        : (expIdx >= 0 ? expIdx : toks.length);

    // Scaling commas: commas after the last integer digit placeholder.
    var lastIntDigit = -1;
    var firstIntDigit = -1;
    for (var i = 0; i < intEnd; i++) {
      if (toks[i].isDigit) {
        lastIntDigit = i;
        if (firstIntDigit < 0) firstIntDigit = i;
      }
    }
    var grouping = false;
    var scale = 0;
    for (var i = 0; i < intEnd; i++) {
      if (toks[i].t != _T.comma) continue;
      if (i > firstIntDigit && i < lastIntDigit) {
        grouping = true;
      } else if (i > lastIntDigit && lastIntDigit >= 0) {
        // Only counts when no digit follows before the point.
        scale++;
      }
    }
    if (pointIdx < 0 && lastIntDigit < 0) {
      // Commas trailing a format with digits only after the point.
    }
    for (var i = 0; i < scale; i++) {
      a /= 1000;
    }

    if (slashIdx >= 0) return _formatFraction(sec, a, neg);

    final decToks = <_Tok>[];
    if (pointIdx >= 0) {
      final end = expIdx >= 0 ? expIdx : toks.length;
      for (var i = pointIdx + 1; i < end; i++) {
        if (toks[i].isDigit) decToks.add(toks[i]);
      }
    }
    final intToks = <int>[];
    for (var i = 0; i < intEnd; i++) {
      if (toks[i].isDigit) intToks.add(i);
    }

    String intDigits;
    String decDigits;
    String? expText;
    if (expIdx >= 0) {
      var expDigits = 0;
      for (var i = expIdx + 1; i < toks.length; i++) {
        if (toks[i].isDigit) expDigits++;
      }
      var e = a == 0 ? 0 : (math.log(a) / math.ln10).floor();
      final intCount = intToks.isEmpty ? 1 : intToks.length;
      if (intCount > 1) {
        // Engineering-style: exponent multiple of the integer digit count.
        e = (e / intCount).floor() * intCount;
      }
      var m = a == 0 ? 0.0 : a / math.pow(10, e);
      var s = NumberFormats._toFixed(m, decToks.length);
      if (a != 0 && double.parse(s) >= math.pow(10, intCount)) {
        e += intCount;
        m = a / math.pow(10, e);
        s = NumberFormats._toFixed(m, decToks.length);
      }
      final parts = s.split('.');
      intDigits = parts[0];
      decDigits = parts.length > 1 ? parts[1] : '';
      final sign = toks[expIdx].s;
      final es = e.abs().toString().padLeft(expDigits, '0');
      expText = 'E${e < 0 ? '-' : (sign == '+' ? '+' : '')}$es';
    } else {
      if (a >= 1e21) return NumberFormats.formatGeneral(neg ? -a : a);
      final s = NumberFormats._toFixed(a, decToks.length);
      final parts = s.split('.');
      intDigits = parts[0];
      decDigits = parts.length > 1 ? parts[1] : '';
    }

    // Integer part: placeholders decide padding.
    if (intDigits == '0') {
      final requiresZero = intToks.any((i) => toks[i].t == _T.d0);
      if (!requiresZero) intDigits = '';
    }
    final assigned = List<String>.filled(intToks.length, '');
    var di = intDigits.length - 1;
    for (var p = intToks.length - 1; p >= 0; p--) {
      final t = toks[intToks[p]];
      if (di >= 0) {
        assigned[p] = intDigits[di];
        di--;
      } else {
        assigned[p] = t.t == _T.d0 ? '0' : (t.t == _T.dQ ? ' ' : '');
      }
    }
    if (di >= 0 && assigned.isNotEmpty) {
      assigned[0] = intDigits.substring(0, di + 1) + assigned[0];
    }
    String? groupedInt;
    if (grouping) {
      final joined = assigned.join();
      final trimmed = joined.trimLeft();
      final pad = joined.length - trimmed.length;
      groupedInt = (' ' * pad) + _group(trimmed);
    }

    // Decimal part: '#' drops trailing zeros, '?' turns them into spaces.
    final dec = decDigits.split('');
    for (var k = dec.length - 1; k >= 0; k--) {
      if (dec[k] != '0') break;
      final t = decToks[k].t;
      if (t == _T.dHash) {
        dec[k] = '';
      } else if (t == _T.dQ) {
        dec[k] = ' ';
      } else {
        break;
      }
    }

    final b = StringBuffer();
    var intPos = 0;
    var decPos = 0;
    var afterExp = false;
    var wroteExp = false;
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (expIdx >= 0 && i > expIdx) afterExp = true;
      switch (t.t) {
        case _T.lit:
          b.write(t.s);
        case _T.d0:
        case _T.dHash:
        case _T.dQ:
          if (afterExp) {
            if (!wroteExp) {
              b.write(expText!.substring(1));
              wroteExp = true;
            }
          } else if (i < intEnd) {
            if (groupedInt != null) {
              if (intPos == 0) b.write(groupedInt);
            } else {
              b.write(assigned[intPos]);
            }
            intPos++;
          } else {
            if (decPos < dec.length) b.write(dec[decPos]);
            decPos++;
          }
        case _T.point:
          if (i == pointIdx) b.write('.');
        case _T.percent:
          b.write('%');
        case _T.exp:
          b.write('E');
          if (!toks.skip(i + 1).any((x) => x.isDigit)) {
            b.write(expText!.substring(1));
            wroteExp = true;
          }
        case _T.comma:
          break;
        case _T.at:
          break;
        case _T.general:
          b.write(NumberFormats.formatGeneral(a));
        case _T.slash:
          b.write('/');
        case _T.date:
          break;
      }
    }
    var out = b.toString();
    if (neg && _hasNonZeroDigit(out)) out = '-$out';
    return out;
  }

  static bool _hasNonZeroDigit(String s) {
    for (final u in s.codeUnits) {
      if (u >= 49 && u <= 57) return true;
    }
    return false;
  }

  static String _group(String digits) {
    if (digits.length <= 3) return digits;
    final b = StringBuffer();
    final first = digits.length % 3;
    if (first > 0) b.write(digits.substring(0, first));
    for (var i = first; i < digits.length; i += 3) {
      if (b.isNotEmpty) b.write(',');
      b.write(digits.substring(i, i + 3));
    }
    return b.toString();
  }

  String _formatFraction(_Section sec, double a, bool neg) {
    final toks = sec.toks;
    final slash = toks.indexWhere((t) => t.t == _T.slash);
    // Denominator: digit placeholders or a fixed literal number.
    var denPlaceholders = 0;
    final fixedDen = StringBuffer();
    var k = slash + 1;
    while (k < toks.length &&
        (toks[k].isDigit || (toks[k].t == _T.lit && RegExp(r'^\d$').hasMatch(toks[k].s)))) {
      if (toks[k].isDigit) {
        denPlaceholders++;
      } else {
        fixedDen.write(toks[k].s);
      }
      k++;
    }
    // Numerator: digits right before the slash.
    var j = slash - 1;
    while (j >= 0 && toks[j].isDigit) {
      j--;
    }
    final numStart = j + 1;
    final hasInt = toks.sublist(0, numStart).any((t) => t.isDigit);
    var whole = hasInt ? a.floorToDouble() : 0.0;
    final frac = a - whole;
    int num;
    int den;
    if (fixedDen.isNotEmpty) {
      den = int.parse(fixedDen.toString());
      num = (frac * den).round();
    } else {
      final maxDen = math.pow(10, denPlaceholders.clamp(1, 4)).toInt() - 1;
      var bestN = 0;
      var bestD = 1;
      var bestErr = double.infinity;
      for (var d = 1; d <= maxDen; d++) {
        final n = (frac * d).round();
        final err = (frac - n / d).abs();
        if (err < bestErr - 1e-12) {
          bestErr = err;
          bestN = n;
          bestD = d;
          if (err == 0) break;
        }
      }
      num = bestN;
      den = bestD;
    }
    if (num == den && hasInt) {
      whole += 1;
      num = 0;
    }
    final sign = neg ? '-' : '';
    if (!hasInt) return '$sign$num/$den';
    final w = whole.toInt();
    if (num == 0) return '$sign$w';
    if (w == 0) return '$sign$num/$den';
    return '$sign$w $num/$den';
  }

  String _formatDate(_Section sec, double v, bool date1904) {
    if (v < 0 && !date1904) return '########';
    final roundToMs = sec.hasSubSecondsOrElapsed;
    final serial = roundToMs ? v : (v * 86400).round() / 86400;
    final dt = NumberFormats.serialToDateTime(serial, date1904: date1904);
    if (dt == null) return '########';
    final b = StringBuffer();
    final hour12 = sec.hasAmPm;
    for (final t in sec.toks) {
      if (t.t == _T.lit) {
        b.write(t.s);
        continue;
      }
      if (t.t != _T.date) continue;
      final s = t.s;
      switch (s) {
        case 'AM/PM':
          b.write(dt.hour < 12 ? 'AM' : 'PM');
        case 'A/P':
          b.write(dt.hour < 12 ? 'A' : 'P');
        case '[h]':
          b.write((v * 24).floor());
        case '[m]':
          b.write((v * 1440).floor());
        case '[s]':
          b.write((v * 86400).round());
        default:
          if (s.startsWith('.')) {
            final digits = s.length - 1;
            final ms = dt.millisecond;
            b.write('.${ms.toString().padLeft(3, '0').substring(0, digits.clamp(1, 3))}');
          } else {
            final c = s[0];
            final len = s.length;
            switch (c) {
              case 'y':
                b.write(len <= 2
                    ? (dt.year % 100).toString().padLeft(2, '0')
                    : dt.year.toString().padLeft(4, '0'));
              case 'm':
                if (len == 1) {
                  b.write(dt.month);
                } else if (len == 2) {
                  b.write(dt.month.toString().padLeft(2, '0'));
                } else if (len == 3) {
                  b.write(NumberFormats.monthNames[dt.month - 1].substring(0, 3));
                } else if (len == 5) {
                  b.write(NumberFormats.monthNames[dt.month - 1][0]);
                } else {
                  b.write(NumberFormats.monthNames[dt.month - 1]);
                }
              case 'n':
                b.write(len == 1
                    ? dt.minute.toString()
                    : dt.minute.toString().padLeft(2, '0'));
              case 'd':
                if (len == 1) {
                  b.write(dt.day);
                } else if (len == 2) {
                  b.write(dt.day.toString().padLeft(2, '0'));
                } else if (len == 3) {
                  b.write(NumberFormats.dayNames[dt.weekday - 1].substring(0, 3));
                } else {
                  b.write(NumberFormats.dayNames[dt.weekday - 1]);
                }
              case 'h':
                var h = dt.hour;
                if (hour12) {
                  h = h % 12;
                  if (h == 0) h = 12;
                }
                b.write(len == 1 ? h.toString() : h.toString().padLeft(2, '0'));
              case 's':
                b.write(len == 1
                    ? dt.second.toString()
                    : dt.second.toString().padLeft(2, '0'));
            }
          }
      }
    }
    return b.toString();
  }
}
