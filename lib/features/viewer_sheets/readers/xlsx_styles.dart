import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../model/cell.dart';
import '../model/number_format.dart';

/// Default Office theme colours in Excel index order:
/// lt1, dk1, lt2, dk2, accent1..6, hlink, folHlink.
const defaultThemeColors = <int>[
  0xFFFFFFFF, 0xFF000000, 0xFFE7E6E6, 0xFF44546A, 0xFF4472C4, 0xFFED7D31, //
  0xFFA5A5A5, 0xFFFFC000, 0xFF5B9BD5, 0xFF70AD47, 0xFF0563C1, 0xFF954F72,
];

/// Excel/BIFF default 64-colour palette (indices 0..63).
const defaultIndexedColors = <int>[
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF, //
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
  0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
  0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
  0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
  0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
  0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
  0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
];

String localName(String qualified) {
  final i = qualified.indexOf(':');
  return i < 0 ? qualified : qualified.substring(i + 1);
}

Iterable<XmlElement> childElements(XmlElement e, String local) =>
    e.childElements.where((c) => c.name.local == local);

XmlElement? firstChild(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

/// Parses `xl/theme/theme1.xml` into the 12 theme colours.
List<int> parseThemeColors(String? xml) {
  if (xml == null) return defaultThemeColors;
  try {
    final doc = XmlDocument.parse(xml);
    final scheme = doc.descendantElements.firstWhere((e) => e.name.local == 'clrScheme');
    int? colorOf(String name) {
      final el = firstChild(scheme, name);
      if (el == null) return null;
      for (final c in el.childElements) {
        if (c.name.local == 'srgbClr') {
          return 0xFF000000 | (int.tryParse(c.getAttribute('val') ?? '', radix: 16) ?? 0);
        }
        if (c.name.local == 'sysClr') {
          final last = c.getAttribute('lastClr');
          if (last != null) return 0xFF000000 | (int.tryParse(last, radix: 16) ?? 0);
          return c.getAttribute('val') == 'window' ? 0xFFFFFFFF : 0xFF000000;
        }
      }
      return null;
    }

    const order = [
      'lt1', 'dk1', 'lt2', 'dk2', 'accent1', 'accent2', 'accent3', 'accent4', //
      'accent5', 'accent6', 'hlink', 'folHlink',
    ];
    return [
      for (var i = 0; i < order.length; i++) colorOf(order[i]) ?? defaultThemeColors[i],
    ];
  } catch (_) {
    return defaultThemeColors;
  }
}

/// Applies an Excel tint (-1..1) to an ARGB colour via HSL luminance.
int applyTint(int argb, double tint) {
  if (tint == 0) return argb;
  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  var h = 0.0;
  var s = 0.0;
  var l = (mx + mn) / 2;
  if (mx != mn) {
    final d = mx - mn;
    s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h /= 6;
  }
  l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint;
  double hue(double p, double q, double t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }

  double rr, gg, bb;
  if (s == 0) {
    rr = gg = bb = l;
  } else {
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    rr = hue(p, q, h + 1 / 3);
    gg = hue(p, q, h);
    bb = hue(p, q, h - 1 / 3);
  }
  int c(double v) => (v * 255).round().clamp(0, 255);
  return 0xFF000000 | (c(rr) << 16) | (c(gg) << 8) | c(bb);
}

/// Resolved colour of a `<color>`/`<fgColor>` element; null = automatic.
int? parseColorElement(XmlElement? el, List<int> theme, List<int> indexed,
    {bool isFont = false}) {
  if (el == null) return null;
  if (el.getAttribute('auto') == '1' || el.getAttribute('auto') == 'true') return null;
  final tint = double.tryParse(el.getAttribute('tint') ?? '') ?? 0;
  int? base;
  final rgb = el.getAttribute('rgb');
  final themeAttr = el.getAttribute('theme');
  final idx = el.getAttribute('indexed');
  if (rgb != null && rgb.isNotEmpty) {
    final v = int.tryParse(rgb, radix: 16);
    if (v != null) base = rgb.length <= 6 ? 0xFF000000 | v : 0xFF000000 | (v & 0xFFFFFF);
  } else if (themeAttr != null) {
    final t = int.tryParse(themeAttr);
    if (t != null && t >= 0 && t < theme.length) {
      if (isFont && t == 1 && tint == 0) return null;
      base = theme[t];
    }
  } else if (idx != null) {
    final i = int.tryParse(idx);
    if (i == null || i >= 64) return null; // system colours = automatic
    if (isFont && (i == 8 || i == 0)) return null;
    base = 0xFF000000 | (i < indexed.length ? indexed[i] : 0);
  }
  if (base == null) return null;
  final out = applyTint(base, tint);
  if (isFont && (out & 0xFFFFFF) == 0) return null; // plain black = automatic
  return out;
}

class XlsxFont {
  XlsxFont({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.size,
  });
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int? color;
  final double? size;
}

bool _flag(XmlElement font, String name) {
  final el = firstChild(font, name);
  if (el == null) return false;
  final v = el.getAttribute('val');
  if (name == 'u') return v != 'none';
  return v == null || v == '1' || v == 'true';
}

XlsxFont parseFont(XmlElement font, List<int> theme, List<int> indexed) {
  return XlsxFont(
    bold: _flag(font, 'b'),
    italic: _flag(font, 'i'),
    underline: _flag(font, 'u'),
    strike: _flag(font, 'strike'),
    color: parseColorElement(firstChild(font, 'color'), theme, indexed, isFont: true),
    size: double.tryParse(firstChild(font, 'sz')?.getAttribute('val') ?? ''),
  );
}

int? parseFill(XmlElement fill, List<int> theme, List<int> indexed) {
  final pattern = firstChild(fill, 'patternFill');
  if (pattern != null) {
    final type = pattern.getAttribute('patternType') ?? 'none';
    if (type == 'none' || type == 'gray125') return null;
    final fg = firstChild(pattern, 'fgColor');
    final c = parseColorElement(fg, theme, indexed);
    if (c != null) return c;
    return parseColorElement(firstChild(pattern, 'bgColor'), theme, indexed);
  }
  final grad = firstChild(fill, 'gradientFill');
  if (grad != null) {
    final stop = firstChild(grad, 'stop');
    if (stop != null) return parseColorElement(firstChild(stop, 'color'), theme, indexed);
  }
  return null;
}

HAlign parseHAlign(String? v) => switch (v) {
      'left' => HAlign.left,
      'center' => HAlign.center,
      'right' => HAlign.right,
      'fill' => HAlign.fill,
      'justify' => HAlign.justify,
      'centerContinuous' => HAlign.centerContinuous,
      'distributed' => HAlign.distributed,
      _ => HAlign.general,
    };

VAlign parseVAlign(String? v) => switch (v) {
      'top' => VAlign.top,
      'center' => VAlign.center,
      'justify' => VAlign.justify,
      'distributed' => VAlign.distributed,
      _ => VAlign.bottom,
    };

String hAlignName(HAlign a) => switch (a) {
      HAlign.general => 'general',
      HAlign.left => 'left',
      HAlign.center => 'center',
      HAlign.right => 'right',
      HAlign.fill => 'fill',
      HAlign.justify => 'justify',
      HAlign.centerContinuous => 'centerContinuous',
      HAlign.distributed => 'distributed',
    };

String vAlignName(VAlign a) => switch (a) {
      VAlign.top => 'top',
      VAlign.center => 'center',
      VAlign.bottom => 'bottom',
      VAlign.justify => 'justify',
      VAlign.distributed => 'distributed',
    };

/// Parsed `styles.xml`.
class XlsxStyles {
  XlsxStyles({
    required this.cellStyles,
    required this.numFmts,
    required this.defaultFontSize,
  });

  /// One [CellStyle] per `cellXfs/xf` (with [CellStyle.baseXf] set).
  final List<CellStyle> cellStyles;

  /// Custom number formats by id.
  final Map<int, String> numFmts;
  final double defaultFontSize;

  static XlsxStyles parse(String? xml, List<int> theme) {
    if (xml == null) {
      return XlsxStyles(cellStyles: const [CellStyle(baseXf: 0)], numFmts: {}, defaultFontSize: 11);
    }
    final doc = XmlDocument.parse(xml);
    final root = doc.rootElement;
    var indexed = defaultIndexedColors;
    final colors = firstChild(root, 'colors');
    final idxEl = colors == null ? null : firstChild(colors, 'indexedColors');
    if (idxEl != null) {
      final custom = [
        for (final c in childElements(idxEl, 'rgbColor'))
          int.tryParse(c.getAttribute('rgb') ?? '', radix: 16) ?? 0,
      ];
      if (custom.isNotEmpty) indexed = [for (final v in custom) v & 0xFFFFFF];
    }
    final numFmts = <int, String>{};
    final nf = firstChild(root, 'numFmts');
    if (nf != null) {
      for (final f in childElements(nf, 'numFmt')) {
        final id = int.tryParse(f.getAttribute('numFmtId') ?? '');
        final code = f.getAttribute('formatCode');
        if (id != null && code != null) numFmts[id] = code;
      }
    }
    final fonts = <XlsxFont>[];
    final fontsEl = firstChild(root, 'fonts');
    if (fontsEl != null) {
      for (final f in childElements(fontsEl, 'font')) {
        fonts.add(parseFont(f, theme, indexed));
      }
    }
    final defaultSize = fonts.isNotEmpty ? (fonts.first.size ?? 11) : 11.0;
    final fills = <int?>[];
    final fillsEl = firstChild(root, 'fills');
    if (fillsEl != null) {
      for (final f in childElements(fillsEl, 'fill')) {
        fills.add(parseFill(f, theme, indexed));
      }
    }
    final styles = <CellStyle>[];
    final xfs = firstChild(root, 'cellXfs');
    if (xfs != null) {
      var i = 0;
      for (final xf in childElements(xfs, 'xf')) {
        final fmtId = int.tryParse(xf.getAttribute('numFmtId') ?? '0') ?? 0;
        final fontId = int.tryParse(xf.getAttribute('fontId') ?? '0') ?? 0;
        final fillId = int.tryParse(xf.getAttribute('fillId') ?? '0') ?? 0;
        final font = fontId < fonts.length ? fonts[fontId] : null;
        final align = firstChild(xf, 'alignment');
        final size = font?.size;
        styles.add(CellStyle(
          bold: font?.bold ?? false,
          italic: font?.italic ?? false,
          underline: font?.underline ?? false,
          strike: font?.strike ?? false,
          fontColor: font?.color,
          fontSize: size == null || size == defaultSize ? null : size,
          fillColor: fillId < fills.length ? fills[fillId] : null,
          numFmt: numFmts[fmtId] ?? NumberFormats.codeForId(fmtId),
          hAlign: parseHAlign(align?.getAttribute('horizontal')),
          vAlign: parseVAlign(align?.getAttribute('vertical')),
          wrap: align?.getAttribute('wrapText') == '1' || align?.getAttribute('wrapText') == 'true',
          baseXf: i,
        ));
        i++;
      }
    }
    if (styles.isEmpty) styles.add(const CellStyle(baseXf: 0));
    return XlsxStyles(cellStyles: styles, numFmts: numFmts, defaultFontSize: defaultSize);
  }
}
