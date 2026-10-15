import 'package:xml/xml.dart';

/// Namespace-prefix-agnostic helpers for walking Office XML.
///
/// Office documents almost always use the conventional prefixes (`w:`, `a:`,
/// `p:` …) but nothing guarantees it, so lookups here match on local names.
abstract final class Ox {
  /// Attribute value by local name (ignores the prefix).
  static String? attr(XmlElement? e, String local) {
    if (e == null) return null;
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }

  /// Attribute value by exact qualified name, then by local name.
  static String? attrQ(XmlElement? e, String qualified) {
    if (e == null) return null;
    for (final a in e.attributes) {
      if (a.name.qualified == qualified) return a.value;
    }
    final i = qualified.indexOf(':');
    return i < 0 ? null : attr(e, qualified.substring(i + 1));
  }

  static XmlElement? child(XmlElement? e, String local) {
    if (e == null) return null;
    for (final c in e.children) {
      if (c is XmlElement && c.name.local == local) return c;
    }
    return null;
  }

  static Iterable<XmlElement> children(XmlElement? e, String local) sync* {
    if (e == null) return;
    for (final c in e.children) {
      if (c is XmlElement && c.name.local == local) yield c;
    }
  }

  static Iterable<XmlElement> elements(XmlElement? e) sync* {
    if (e == null) return;
    for (final c in e.children) {
      if (c is XmlElement) yield c;
    }
  }

  /// Follows a chain of child local names.
  static XmlElement? path(XmlElement? e, List<String> locals) {
    var cur = e;
    for (final l in locals) {
      cur = child(cur, l);
      if (cur == null) return null;
    }
    return cur;
  }

  /// All descendants with the given local name (document order).
  static Iterable<XmlElement> descendants(XmlElement? e, String local) sync* {
    if (e == null) return;
    for (final d in e.descendants) {
      if (d is XmlElement && d.name.local == local) yield d;
    }
  }

  static XmlElement? firstDescendant(XmlElement? e, String local) {
    if (e == null) return null;
    for (final d in e.descendants) {
      if (d is XmlElement && d.name.local == local) return d;
    }
    return null;
  }

  /// OOXML on/off property: `<w:b/>`, `<w:b w:val="1"/>`, `<w:b w:val="false"/>`.
  static bool? toggle(XmlElement? e) {
    if (e == null) return null;
    final v = attr(e, 'val');
    if (v == null) return true;
    switch (v.toLowerCase()) {
      case '0':
      case 'false':
      case 'off':
      case 'none':
        return false;
      default:
        return true;
    }
  }

  static int? intAttr(XmlElement? e, String local) {
    final v = attr(e, local);
    if (v == null) return null;
    return int.tryParse(v) ?? double.tryParse(v)?.round();
  }

  static double? doubleAttr(XmlElement? e, String local) {
    final v = attr(e, local);
    if (v == null) return null;
    return double.tryParse(v);
  }

  /// Parses `RRGGBB` (or `#RRGGBB`) into opaque ARGB; null for auto/invalid.
  static int? hexColor(String? v) {
    if (v == null) return null;
    var s = v.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.isEmpty || s.toLowerCase() == 'auto') return null;
    if (s.length == 3) {
      s = '${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}';
    }
    if (s.length != 6) return null;
    final n = int.tryParse(s, radix: 16);
    return n == null ? null : 0xFF000000 | n;
  }

  static String colorHex(int argb) =>
      (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  /// Plain text of an element, concatenating text nodes.
  static String text(XmlElement e) {
    final sb = StringBuffer();
    for (final d in e.descendants) {
      if (d is XmlText) sb.write(d.value);
      if (d is XmlCDATA) sb.write(d.value);
    }
    return sb.toString();
  }
}

/// XML escaping for generated markup.
String xmlEscape(String s) {
  final sb = StringBuffer();
  for (final c in s.runes) {
    switch (c) {
      case 0x26:
        sb.write('&amp;');
      case 0x3C:
        sb.write('&lt;');
      case 0x3E:
        sb.write('&gt;');
      case 0x22:
        sb.write('&quot;');
      case 0x27:
        sb.write('&apos;');
      default:
        // XML 1.0 forbids most C0 controls.
        if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) continue;
        if (c == 0xFFFE || c == 0xFFFF) continue;
        sb.writeCharCode(c);
    }
  }
  return sb.toString();
}

/// Unit conversions used across Office formats. Everything internal is in
/// points (1/72 inch).
abstract final class Units {
  static double twips(num v) => v / 20.0;
  static double emu(num v) => v / 12700.0;
  static double halfPoints(num v) => v / 2.0;
  static int toTwips(double pt) => (pt * 20).round();
  static int toEmu(double pt) => (pt * 12700).round();

  /// Parses an ODF/CSS length (`2.5cm`, `10mm`, `1in`, `12pt`, `16px`) to pt.
  static double? length(String? v) {
    if (v == null) return null;
    final m = RegExp(r'^\s*(-?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)\s*([a-z%]*)\s*$')
        .firstMatch(v);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    switch (m.group(2)) {
      case 'cm':
        return n * 72 / 2.54;
      case 'mm':
        return n * 72 / 25.4;
      case 'in':
        return n * 72;
      case 'pc':
        return n * 12;
      case 'px':
        return n * 0.75;
      case 'pt':
      case '':
        return n;
      default:
        return null;
    }
  }
}
