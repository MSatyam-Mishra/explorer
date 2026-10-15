import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import '../common/office_package.dart';
import '../common/office_xml.dart';
import 'slide_model.dart';

/// Parses PPTX/PPTM/PPSX/POTX/PPSM bytes. Runs in a background isolate.
SlideDeck parsePptxBytes(Uint8List bytes) =>
    PptxParser(OfficePackage.decode(bytes)).parse();

class _Theme {
  final Map<String, int> colors = {};
  String? major;
  String? minor;
  List<XmlElement> fillStyles = const [];
  List<XmlElement> lineStyles = const [];
  List<XmlElement> bgFillStyles = const [];
}

class _Master {
  _Master(this.part, this.doc, this.rels, this.theme);
  final String part;
  final XmlDocument doc;
  final Map<String, OfficeRel> rels;
  final _Theme theme;
  final Map<String, String> clrMap = {};
  XmlElement? get root => doc.rootElement;
  XmlElement? get txStyles => Ox.child(root, 'txStyles');
}

class _Layout {
  _Layout(this.part, this.doc, this.rels, this.master);
  final String part;
  final XmlDocument doc;
  final Map<String, OfficeRel> rels;
  final _Master master;
}

/// Where shapes come from (slide, layout or master) and how to resolve
/// relationships and colours there.
class _Ctx {
  _Ctx({
    required this.part,
    required this.rels,
    required this.master,
    this.layout,
    required this.fromSlide,
    required this.slideNumber,
  });

  final String part;
  final Map<String, OfficeRel> rels;
  final _Master master;
  final _Layout? layout;
  final bool fromSlide;
  final int slideNumber;
}

/// Maps child coordinates of nested groups to slide coordinates.
class _Xf {
  const _Xf(this.sx, this.sy, this.dx, this.dy);
  final double sx;
  final double sy;
  final double dx;
  final double dy;
  static const identity = _Xf(1, 1, 0, 0);

  SlideRect apply(SlideRect r) => SlideRect(r.x * sx + dx, r.y * sy + dy, r.w * sx, r.h * sy);
}

class PptxParser {
  PptxParser(this.pkg);

  final OfficePackage pkg;
  final Map<String, _Master> _masters = {};
  final Map<String, _Layout> _layouts = {};
  final Map<String, SlideImageData> _images = {};
  final Map<String, XmlElement> _tableStyles = {};
  XmlElement? _defaultTextStyle;
  final List<String> _warnings = [];

  SlideDeck parse() {
    final main = pkg.mainPart() ?? 'ppt/presentation.xml';
    final pres = pkg.xml(main);
    if (pres == null) {
      throw const FormatException('This presentation has no readable content.');
    }
    final root = pres.rootElement;
    final sz = Ox.child(root, 'sldSz');
    final width = Units.emu(Ox.doubleAttr(sz, 'cx') ?? 9144000);
    final height = Units.emu(Ox.doubleAttr(sz, 'cy') ?? 6858000);
    _defaultTextStyle = Ox.child(root, 'defaultTextStyle');
    _loadTableStyles(main);

    final rels = pkg.relMap(main);
    final slides = <Slide>[];
    var n = 0;
    for (final s in Ox.children(Ox.child(root, 'sldIdLst'), 'sldId')) {
      final rid = Ox.attrQ(s, 'r:id');
      final rel = rid == null ? null : rels[rid];
      if (rel == null) continue;
      final part = OfficePackage.resolve(main, rel.target);
      n++;
      try {
        final slide = _parseSlide(part, n);
        if (slide == null) continue;
        slide
          ..relId = rid
          ..slideId = Ox.attr(s, 'id');
        slides.add(slide);
      } catch (e) {
        slides.add(Slide(index: n - 1, partName: part, relId: rid, slideId: Ox.attr(s, 'id'))
          ..notes = '');
        _warnings.add('Slide $n could not be fully read.');
      }
    }
    return SlideDeck(
      format: 'pptx',
      width: width,
      height: height,
      slides: slides,
      images: _images,
      warnings: _warnings,
    );
  }

  // ---------------------------------------------------------------------------
  // Theme / master / layout

  _Theme _loadTheme(String masterPart, Map<String, OfficeRel> rels) {
    final t = _Theme();
    for (final r in rels.values) {
      if (r.kind != 'theme') continue;
      final doc = pkg.xml(OfficePackage.resolve(masterPart, r.target));
      if (doc == null) break;
      final elements = Ox.child(doc.rootElement, 'themeElements');
      final scheme = Ox.child(elements, 'clrScheme');
      for (final c in Ox.elements(scheme)) {
        final v = _rawColor(c);
        if (v != null) t.colors[c.name.local] = v;
      }
      final fonts = Ox.child(elements, 'fontScheme');
      t.major = Ox.attr(Ox.path(fonts, ['majorFont', 'latin']), 'typeface');
      t.minor = Ox.attr(Ox.path(fonts, ['minorFont', 'latin']), 'typeface');
      final fmt = Ox.child(elements, 'fmtScheme');
      t.fillStyles = Ox.elements(Ox.child(fmt, 'fillStyleLst')).toList();
      t.lineStyles = Ox.elements(Ox.child(fmt, 'lnStyleLst')).toList();
      t.bgFillStyles = Ox.elements(Ox.child(fmt, 'bgFillStyleLst')).toList();
      break;
    }
    return t;
  }

  /// Colour of a theme scheme entry (`<a:dk1><a:srgbClr …/></a:dk1>`).
  int? _rawColor(XmlElement holder) {
    for (final e in Ox.elements(holder)) {
      switch (e.name.local) {
        case 'srgbClr':
          return Ox.hexColor(Ox.attr(e, 'val'));
        case 'sysClr':
          return Ox.hexColor(Ox.attr(e, 'lastClr')) ??
              (Ox.attr(e, 'val') == 'window' ? 0xFFFFFFFF : 0xFF000000);
      }
    }
    return null;
  }

  _Master _master(String part) {
    return _masters.putIfAbsent(part, () {
      final doc = pkg.xml(part) ?? XmlDocument.parse('<sldMaster/>');
      final rels = pkg.relMap(part);
      final m = _Master(part, doc, rels, _loadTheme(part, rels));
      final map = Ox.child(doc.rootElement, 'clrMap');
      if (map != null) {
        for (final a in map.attributes) {
          m.clrMap[a.name.local] = a.value;
        }
      }
      return m;
    });
  }

  _Layout? _layout(String part) {
    final existing = _layouts[part];
    if (existing != null) return existing;
    final doc = pkg.xml(part);
    if (doc == null) return null;
    final rels = pkg.relMap(part);
    String? masterPart;
    for (final r in rels.values) {
      if (r.kind == 'slideMaster') masterPart = OfficePackage.resolve(part, r.target);
    }
    if (masterPart == null) return null;
    final l = _Layout(part, doc, rels, _master(masterPart));
    _layouts[part] = l;
    return l;
  }

  void _loadTableStyles(String main) {
    for (final r in pkg.rels(main)) {
      if (r.kind != 'tableStyles') continue;
      final doc = pkg.xml(OfficePackage.resolve(main, r.target));
      for (final s in Ox.children(doc?.rootElement, 'tblStyle')) {
        final id = Ox.attr(s, 'styleId');
        if (id != null) _tableStyles[id] = s;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Colours

  int? _colorIn(XmlElement? parent, _Ctx c, {int? ph}) {
    if (parent == null) return null;
    for (final e in Ox.elements(parent)) {
      final base = _baseColor(e, c, ph: ph);
      if (base == null) continue;
      return _applyMods(base, e);
    }
    return null;
  }

  int? _baseColor(XmlElement e, _Ctx c, {int? ph}) {
    switch (e.name.local) {
      case 'srgbClr':
        return Ox.hexColor(Ox.attr(e, 'val'));
      case 'schemeClr':
        final v = Ox.attr(e, 'val') ?? '';
        if (v == 'phClr') return ph ?? 0xFF000000;
        final mapped = c.master.clrMap[v] ?? v;
        return c.master.theme.colors[mapped] ??
            switch (mapped) {
              'dk1' || 'tx1' => 0xFF000000,
              'lt1' || 'bg1' => 0xFFFFFFFF,
              'dk2' => 0xFF44546A,
              'lt2' => 0xFFE7E6E6,
              'accent1' => 0xFF4472C4,
              'accent2' => 0xFFED7D31,
              'accent3' => 0xFFA5A5A5,
              'accent4' => 0xFFFFC000,
              'accent5' => 0xFF5B9BD5,
              'accent6' => 0xFF70AD47,
              'hlink' => 0xFF0563C1,
              _ => 0xFF000000,
            };
      case 'sysClr':
        return Ox.hexColor(Ox.attr(e, 'lastClr')) ??
            (Ox.attr(e, 'val') == 'window' ? 0xFFFFFFFF : 0xFF000000);
      case 'prstClr':
        return _presetColors[Ox.attr(e, 'val')] ?? 0xFF000000;
      case 'scrgbClr':
        int ch(String a) => ((Ox.doubleAttr(e, a) ?? 0) / 100000 * 255).round().clamp(0, 255);
        return 0xFF000000 | (ch('r') << 16) | (ch('g') << 8) | ch('b');
      case 'hslClr':
        final h = (Ox.doubleAttr(e, 'hue') ?? 0) / 60000;
        final s = (Ox.doubleAttr(e, 'sat') ?? 0) / 100000;
        final l = (Ox.doubleAttr(e, 'lum') ?? 0) / 100000;
        return _fromHsl(h, s, l, 1);
    }
    return null;
  }

  static const _presetColors = {
    'black': 0xFF000000, 'white': 0xFFFFFFFF, 'red': 0xFFFF0000,
    'green': 0xFF008000, 'blue': 0xFF0000FF, 'yellow': 0xFFFFFF00,
    'gray': 0xFF808080, 'grey': 0xFF808080, 'darkGray': 0xFFA9A9A9,
    'lightGray': 0xFFD3D3D3, 'orange': 0xFFFFA500, 'purple': 0xFF800080,
    'navy': 0xFF000080, 'cyan': 0xFF00FFFF, 'magenta': 0xFFFF00FF,
    'darkBlue': 0xFF00008B, 'darkRed': 0xFF8B0000, 'darkGreen': 0xFF006400,
  };

  static (double, double, double) _toHsl(int argb) {
    final r = ((argb >> 16) & 0xFF) / 255, g = ((argb >> 8) & 0xFF) / 255, b = (argb & 0xFF) / 255;
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    final l = (mx + mn) / 2;
    if (mx == mn) return (0, 0, l);
    final d = mx - mn;
    final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    double h;
    if (mx == r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    return (h * 60, s, l);
  }

  static int _fromHsl(double h, double s, double l, double a) {
    double hue(double p, double q, double t) {
      var x = t;
      if (x < 0) x += 1;
      if (x > 1) x -= 1;
      if (x < 1 / 6) return p + (q - p) * 6 * x;
      if (x < 1 / 2) return q;
      if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
      return p;
    }

    double r, g, b;
    final hh = (h % 360) / 360;
    if (s == 0) {
      r = g = b = l;
    } else {
      final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      final p = 2 * l - q;
      r = hue(p, q, hh + 1 / 3);
      g = hue(p, q, hh);
      b = hue(p, q, hh - 1 / 3);
    }
    int c(double v) => (v * 255).round().clamp(0, 255);
    return (c(a) << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
  }

  int _applyMods(int base, XmlElement e) {
    var c = base;
    var alpha = ((c >> 24) & 0xFF) / 255;
    for (final m in Ox.elements(e)) {
      final v = (Ox.doubleAttr(m, 'val') ?? 0) / 100000;
      switch (m.name.local) {
        case 'lumMod':
          final (h, s, l) = _toHsl(c);
          c = _fromHsl(h, s, (l * v).clamp(0, 1), 1);
        case 'lumOff':
          final (h, s, l) = _toHsl(c);
          c = _fromHsl(h, s, (l + v).clamp(0, 1), 1);
        case 'satMod':
          final (h, s, l) = _toHsl(c);
          c = _fromHsl(h, (s * v).clamp(0, 1), l, 1);
        case 'tint':
          int t(int ch) => (ch + (255 - ch) * (1 - v)).round().clamp(0, 255);
          c = 0xFF000000 | (t((c >> 16) & 0xFF) << 16) | (t((c >> 8) & 0xFF) << 8) | t(c & 0xFF);
        case 'shade':
          int t(int ch) => (ch * v).round().clamp(0, 255);
          c = 0xFF000000 | (t((c >> 16) & 0xFF) << 16) | (t((c >> 8) & 0xFF) << 8) | t(c & 0xFF);
        case 'alpha':
          alpha = v.clamp(0, 1);
        case 'alphaMod':
          alpha = (alpha * v).clamp(0, 1);
      }
    }
    return ((alpha * 255).round() << 24) | (c & 0xFFFFFF);
  }

  // ---------------------------------------------------------------------------
  // Fills & lines

  /// Fill from an spPr-like element. Returns an empty [SlideFill] for an
  /// explicit "no fill", null when nothing is specified.
  SlideFill? _fill(XmlElement? holder, _Ctx c, {int? ph, SlideFill? group}) {
    if (holder == null) return null;
    for (final e in Ox.elements(holder)) {
      switch (e.name.local) {
        case 'noFill':
          return const SlideFill();
        case 'solidFill':
          return SlideFill(color: _colorIn(e, c, ph: ph));
        case 'gradFill':
          final stops = <SlideGradientStop>[];
          for (final gs in Ox.children(Ox.child(e, 'gsLst'), 'gs')) {
            final col = _colorIn(gs, c, ph: ph);
            if (col != null) {
              stops.add(SlideGradientStop((Ox.doubleAttr(gs, 'pos') ?? 0) / 100000, col));
            }
          }
          stops.sort((a, b) => a.position.compareTo(b.position));
          final ang = (Ox.doubleAttr(Ox.child(e, 'lin'), 'ang') ?? 5400000) / 60000;
          if (stops.isEmpty) return null;
          return SlideFill(gradient: stops, gradientAngle: ang, color: stops.first.color);
        case 'blipFill':
          final id = _image(Ox.attrQ(Ox.child(e, 'blip'), 'r:embed'), c);
          return id == null ? null : SlideFill(imageId: id);
        case 'pattFill':
          return SlideFill(color: _colorIn(Ox.child(e, 'fgClr'), c, ph: ph));
        case 'grpFill':
          return group;
      }
    }
    return null;
  }

  SlideLine? _line(XmlElement? ln, _Ctx c, {int? ph, double? defaultWidth}) {
    if (ln == null) return null;
    if (Ox.child(ln, 'noFill') != null) return const SlideLine(color: 0);
    final color = _colorIn(Ox.child(ln, 'solidFill'), c, ph: ph) ??
        _colorIn(Ox.child(Ox.child(ln, 'gradFill'), 'gsLst')?.childElements.firstOrNull, c, ph: ph);
    final w = Ox.doubleAttr(ln, 'w');
    if (color == null && w == null) return null;
    String? dash = Ox.attr(Ox.child(ln, 'prstDash'), 'val');
    if (dash == 'solid') dash = null;
    bool arrow(String local) {
      final t = Ox.attr(Ox.child(ln, local), 'type');
      return t != null && t != 'none';
    }

    return SlideLine(
      color: color ?? 0xFF000000,
      width: w == null ? (defaultWidth ?? 0.75) : Units.emu(w),
      dash: dash,
      headArrow: arrow('headEnd'),
      tailArrow: arrow('tailEnd'),
    );
  }

  String? _image(String? rid, _Ctx c) {
    if (rid == null) return null;
    final rel = c.rels[rid];
    if (rel == null || rel.external) return null;
    final path = OfficePackage.resolve(c.part, rel.target);
    if (_images.containsKey(path)) return path;
    final bytes = pkg.bytes(path);
    if (bytes == null) return null;
    var ext = sniffImageExtension(bytes) ?? path.split('.').last.toLowerCase();
    var data = bytes;
    if (ext == 'tiff' || ext == 'tif') {
      try {
        final d = img.decodeTiff(bytes);
        if (d != null) {
          data = Uint8List.fromList(img.encodePng(d));
          ext = 'png';
        }
      } catch (_) {}
    }
    _images[path] = SlideImageData(data, ext == 'jpg' ? 'jpeg' : ext);
    return path;
  }

  // ---------------------------------------------------------------------------
  // Slides

  Slide? _parseSlide(String part, int number) {
    final doc = pkg.xml(part);
    if (doc == null) return null;
    final rels = pkg.relMap(part);
    _Layout? layout;
    String? notesPart;
    for (final r in rels.values) {
      if (r.kind == 'slideLayout') layout = _layout(OfficePackage.resolve(part, r.target));
      if (r.kind == 'notesSlide') notesPart = OfficePackage.resolve(part, r.target);
    }
    final master = layout?.master ?? _master('');
    final root = doc.rootElement;
    final ctx = _Ctx(
      part: part,
      rels: rels,
      master: master,
      layout: layout,
      fromSlide: true,
      slideNumber: number,
    );
    final shapes = <SlideShape>[];
    final showMasterSlide = Ox.attr(root, 'showMasterSp') != '0';
    final layoutRoot = layout?.doc.rootElement;
    final showMasterLayout = Ox.attr(layoutRoot, 'showMasterSp') != '0';

    if (showMasterSlide && showMasterLayout && master.root != null) {
      final mctx = _Ctx(part: master.part, rels: master.rels, master: master, fromSlide: false, slideNumber: number);
      _shapes(Ox.path(master.root, ['cSld', 'spTree']), mctx, _Xf.identity, shapes, skipPlaceholders: true);
    }
    if (showMasterSlide && layout != null) {
      final lctx = _Ctx(part: layout.part, rels: layout.rels, master: master, layout: layout, fromSlide: false, slideNumber: number);
      _shapes(Ox.path(layoutRoot, ['cSld', 'spTree']), lctx, _Xf.identity, shapes, skipPlaceholders: true);
    }
    _shapes(Ox.path(root, ['cSld', 'spTree']), ctx, _Xf.identity, shapes);

    final bg = _background(Ox.child(root, 'cSld'), ctx) ??
        (layout == null ? null : _background(Ox.child(layoutRoot, 'cSld'), ctx)) ??
        _background(Ox.child(master.root, 'cSld'), ctx) ??
        const SlideFill(color: 0xFFFFFFFF);

    return Slide(
      index: number - 1,
      shapes: shapes,
      background: bg,
      notes: notesPart == null ? '' : _notes(notesPart),
      hidden: Ox.attr(root, 'show') == '0',
      partName: part,
    );
  }

  SlideFill? _background(XmlElement? cSld, _Ctx c) {
    final bg = Ox.child(cSld, 'bg');
    if (bg == null) return null;
    final pr = Ox.child(bg, 'bgPr');
    if (pr != null) return _fill(pr, c);
    final ref = Ox.child(bg, 'bgRef');
    if (ref != null) {
      final idx = Ox.intAttr(ref, 'idx') ?? 0;
      final color = _colorIn(ref, c);
      final list = idx >= 1001 ? c.master.theme.bgFillStyles : c.master.theme.fillStyles;
      final i = idx >= 1001 ? idx - 1001 : idx - 1;
      if (i >= 0 && i < list.length) {
        final holder = XmlElement(XmlName('x'), [], [list[i].copy()]);
        return _fill(holder, c, ph: color) ?? SlideFill(color: color);
      }
      return SlideFill(color: color);
    }
    return null;
  }

  String _notes(String part) {
    final doc = pkg.xml(part);
    if (doc == null) return '';
    for (final sp in Ox.descendants(doc.rootElement, 'sp')) {
      final ph = Ox.firstDescendant(Ox.child(sp, 'nvSpPr'), 'ph');
      if (Ox.attr(ph, 'type') != 'body') continue;
      final paras = <String>[];
      for (final p in Ox.descendants(Ox.child(sp, 'txBody'), 'p')) {
        final sb = StringBuffer();
        for (final e in Ox.elements(p)) {
          if (e.name.local == 'r' || e.name.local == 'fld') {
            sb.write(Ox.child(e, 't')?.innerText ?? '');
          } else if (e.name.local == 'br') {
            sb.write('\n');
          }
        }
        paras.add(sb.toString());
      }
      return paras.join('\n').trim();
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // Shapes

  void _shapes(XmlElement? tree, _Ctx c, _Xf xf, List<SlideShape> out,
      {bool skipPlaceholders = false, SlideFill? groupFill}) {
    for (final e in Ox.elements(tree)) {
      try {
        _shape(e, c, xf, out, skipPlaceholders: skipPlaceholders, groupFill: groupFill);
      } catch (_) {
        // Skip a broken shape rather than the whole slide.
      }
    }
  }

  void _shape(XmlElement e, _Ctx c, _Xf xf, List<SlideShape> out,
      {bool skipPlaceholders = false, SlideFill? groupFill}) {
    switch (e.name.local) {
      case 'sp':
        final ph = Ox.firstDescendant(_nvPr(e), 'ph');
        if (ph != null && skipPlaceholders) return;
        final s = _autoShape(e, c, xf, ph, groupFill);
        if (s != null) out.add(s);
      case 'cxnSp':
        final s = _autoShape(e, c, xf, null, groupFill);
        if (s != null) out.add(s);
      case 'pic':
        final ph = Ox.firstDescendant(_nvPr(e), 'ph');
        if (ph != null && skipPlaceholders) return;
        final p = _picture(e, c, xf, ph);
        if (p != null) out.add(p);
      case 'grpSp':
        final pr = Ox.child(e, 'grpSpPr');
        final x = Ox.child(pr, 'xfrm');
        var child = xf;
        if (x != null) {
          final off = Ox.child(x, 'off'), ext = Ox.child(x, 'ext');
          final chOff = Ox.child(x, 'chOff'), chExt = Ox.child(x, 'chExt');
          final ox = Units.emu(Ox.doubleAttr(off, 'x') ?? 0), oy = Units.emu(Ox.doubleAttr(off, 'y') ?? 0);
          final ew = Units.emu(Ox.doubleAttr(ext, 'cx') ?? 0), eh = Units.emu(Ox.doubleAttr(ext, 'cy') ?? 0);
          final cx = Units.emu(Ox.doubleAttr(chOff, 'x') ?? 0), cy = Units.emu(Ox.doubleAttr(chOff, 'y') ?? 0);
          final cw = Units.emu(Ox.doubleAttr(chExt, 'cx') ?? 0), chh = Units.emu(Ox.doubleAttr(chExt, 'cy') ?? 0);
          final sx = cw == 0 ? 1.0 : ew / cw, sy = chh == 0 ? 1.0 : eh / chh;
          // child → group space, then group space → parent.
          final local = _Xf(sx, sy, ox - cx * sx, oy - cy * sy);
          child = _Xf(local.sx * xf.sx, local.sy * xf.sy, local.dx * xf.sx + xf.dx, local.dy * xf.sy + xf.dy);
        }
        final gf = _fill(pr, c, group: groupFill) ?? groupFill;
        _shapes(e, c, child, out, skipPlaceholders: skipPlaceholders, groupFill: gf);
      case 'graphicFrame':
        _graphicFrame(e, c, xf, out);
      case 'AlternateContent':
        final choice = Ox.child(e, 'Choice');
        final fallback = Ox.child(e, 'Fallback');
        final before = out.length;
        if (choice != null) _shapes(choice, c, xf, out, skipPlaceholders: skipPlaceholders, groupFill: groupFill);
        if (out.length == before && fallback != null) {
          _shapes(fallback, c, xf, out, skipPlaceholders: skipPlaceholders, groupFill: groupFill);
        }
    }
  }

  XmlElement? _nvPr(XmlElement shape) {
    for (final nv in Ox.elements(shape)) {
      if (nv.name.local.startsWith('nv')) return Ox.child(nv, 'nvPr');
    }
    return null;
  }

  XmlElement? _cNvPr(XmlElement shape) {
    for (final nv in Ox.elements(shape)) {
      if (nv.name.local.startsWith('nv')) return Ox.child(nv, 'cNvPr');
    }
    return null;
  }

  /// Layout and master placeholders matching [ph].
  (XmlElement?, XmlElement?) _placeholderSources(XmlElement ph, _Ctx c) {
    final type = Ox.attr(ph, 'type') ?? 'obj';
    final idx = Ox.attr(ph, 'idx');
    XmlElement? find(XmlElement? root, {required bool byIdx, required String t}) {
      final tree = Ox.path(root, ['cSld', 'spTree']);
      if (tree == null) return null;
      XmlElement? typeMatch;
      for (final sp in Ox.descendants(tree, 'sp')) {
        final p = Ox.firstDescendant(_nvPr(sp), 'ph');
        if (p == null) continue;
        final pt = Ox.attr(p, 'type') ?? 'obj';
        if (byIdx && idx != null && Ox.attr(p, 'idx') == idx) return sp;
        if (typeMatch == null && _normType(pt) == _normType(t)) typeMatch = sp;
      }
      return typeMatch;
    }

    final layoutSp = c.layout == null ? null : find(c.layout!.doc.rootElement, byIdx: true, t: type);
    String masterType = type;
    if (layoutSp != null) {
      masterType = Ox.attr(Ox.firstDescendant(_nvPr(layoutSp), 'ph'), 'type') ?? masterType;
    }
    final masterSp = find(c.master.root, byIdx: false, t: masterType);
    return (layoutSp, masterSp);
  }

  static String _normType(String t) => switch (t) {
        'ctrTitle' => 'title',
        'subTitle' || 'obj' || 'body' => 'body',
        _ => t,
      };

  SlideRect? _xfrm(XmlElement? spPr) {
    final x = Ox.child(spPr, 'xfrm');
    if (x == null) return null;
    final off = Ox.child(x, 'off'), ext = Ox.child(x, 'ext');
    if (off == null || ext == null) return null;
    return SlideRect(
      Units.emu(Ox.doubleAttr(off, 'x') ?? 0),
      Units.emu(Ox.doubleAttr(off, 'y') ?? 0),
      Units.emu(Ox.doubleAttr(ext, 'cx') ?? 0),
      Units.emu(Ox.doubleAttr(ext, 'cy') ?? 0),
    );
  }

  SlideAutoShape? _autoShape(XmlElement e, _Ctx c, _Xf xf, XmlElement? ph, SlideFill? groupFill) {
    final spPr = Ox.child(e, 'spPr');
    XmlElement? layoutSp, masterSp;
    if (ph != null) (layoutSp, masterSp) = _placeholderSources(ph, c);
    final layoutPr = Ox.child(layoutSp, 'spPr');
    final masterPr = Ox.child(masterSp, 'spPr');

    var frame = _xfrm(spPr) ?? _xfrm(layoutPr) ?? _xfrm(masterPr);
    if (frame == null) return null;
    frame = xf.apply(frame);
    final x = Ox.child(spPr, 'xfrm') ?? Ox.child(layoutPr, 'xfrm') ?? Ox.child(masterPr, 'xfrm');
    final rot = (Ox.doubleAttr(x, 'rot') ?? 0) / 60000;

    // Shape style references (theme-based defaults).
    final style = Ox.child(e, 'style');
    final fillRef = Ox.child(style, 'fillRef');
    final lnRef = Ox.child(style, 'lnRef');
    final fontRef = Ox.child(style, 'fontRef');
    final fillRefColor = _colorIn(fillRef, c);
    final lnRefColor = _colorIn(lnRef, c);
    final fontColor = _colorIn(fontRef, c);

    var fill = _fill(spPr, c, group: groupFill) ?? _fill(layoutPr, c) ?? _fill(masterPr, c);
    if (fill == null && fillRef != null) {
      final idx = Ox.intAttr(fillRef, 'idx') ?? 0;
      final styles = c.master.theme.fillStyles;
      if (idx > 0 && idx <= styles.length) {
        final holder = XmlElement(XmlName('x'), [], [styles[idx - 1].copy()]);
        fill = _fill(holder, c, ph: fillRefColor);
      }
      if (idx > 0 && fill == null) fill = SlideFill(color: fillRefColor);
    }
    var line = _line(Ox.child(spPr, 'ln'), c, ph: lnRefColor);
    if (line == null && lnRef != null) {
      final idx = Ox.intAttr(lnRef, 'idx') ?? 0;
      final styles = c.master.theme.lineStyles;
      if (idx > 0) {
        final st = idx <= styles.length ? styles[idx - 1] : null;
        line = _line(st, c, ph: lnRefColor, defaultWidth: 0.75) ??
            SlideLine(color: lnRefColor ?? 0xFF000000);
        final own = Ox.child(spPr, 'ln');
        final w = Ox.doubleAttr(own, 'w');
        if (w != null) {
          line = SlideLine(color: line.color, width: Units.emu(w), dash: line.dash);
        }
      }
    }
    line ??= _line(Ox.child(layoutPr, 'ln'), c) ?? _line(Ox.child(masterPr, 'ln'), c);

    String geometry = 'rect';
    double? adjust;
    List<SlideCustomPath>? custom;
    final prst = Ox.child(spPr, 'prstGeom');
    if (prst != null) {
      geometry = Ox.attr(prst, 'prst') ?? 'rect';
      final gd = Ox.child(Ox.child(prst, 'avLst'), 'gd');
      final fmla = Ox.attr(gd, 'fmla');
      if (fmla != null && fmla.startsWith('val ')) {
        adjust = (double.tryParse(fmla.substring(4)) ?? 0) / 100000;
      }
    } else if (Ox.child(spPr, 'custGeom') != null) {
      geometry = 'custom';
      custom = _customGeometry(Ox.child(spPr, 'custGeom')!);
    }
    if (e.name.local == 'cxnSp' && prst == null) geometry = 'line';

    final cNvPr = _cNvPr(e);
    final text = _textBody(Ox.child(e, 'txBody'), c, ph, layoutSp, masterSp, fontColor);
    final type = ph == null ? null : (Ox.attr(ph, 'type') ?? 'obj');
    // Date/footer/slide-number placeholders on slides show their text;
    // empty placeholders (prompt text) aren't drawn.
    return SlideAutoShape(
      frame: frame,
      rotation: rot,
      flipH: Ox.attr(x, 'flipH') == '1',
      flipV: Ox.attr(x, 'flipV') == '1',
      id: Ox.attr(cNvPr, 'id'),
      name: Ox.attr(cNvPr, 'name'),
      fromSlide: c.fromSlide,
      placeholder: type,
      geometry: geometry,
      adjust: adjust,
      customPaths: custom,
      fill: fill,
      line: line,
      text: text,
    );
  }

  List<SlideCustomPath> _customGeometry(XmlElement cust) {
    final out = <SlideCustomPath>[];
    for (final p in Ox.children(Ox.child(cust, 'pathLst'), 'path')) {
      final w = Ox.doubleAttr(p, 'w') ?? 0, h = Ox.doubleAttr(p, 'h') ?? 0;
      final cmds = <SlidePathCommand>[];
      for (final cmd in Ox.elements(p)) {
        final pts = <double>[];
        for (final pt in Ox.children(cmd, 'pt')) {
          pts
            ..add(Ox.doubleAttr(pt, 'x') ?? 0)
            ..add(Ox.doubleAttr(pt, 'y') ?? 0);
        }
        switch (cmd.name.local) {
          case 'moveTo':
            cmds.add(SlidePathCommand('M', pts));
          case 'lnTo':
            cmds.add(SlidePathCommand('L', pts));
          case 'cubicBezTo':
            cmds.add(SlidePathCommand('C', pts));
          case 'quadBezTo':
            cmds.add(SlidePathCommand('Q', pts));
          case 'arcTo':
            cmds.add(SlidePathCommand('A', [
              Ox.doubleAttr(cmd, 'wR') ?? 0,
              Ox.doubleAttr(cmd, 'hR') ?? 0,
              (Ox.doubleAttr(cmd, 'stAng') ?? 0) / 60000,
              (Ox.doubleAttr(cmd, 'swAng') ?? 0) / 60000,
            ]));
          case 'close':
            cmds.add(const SlidePathCommand('Z', []));
        }
      }
      out.add(SlideCustomPath(w, h, cmds,
          fill: Ox.attr(p, 'fill') != 'none', stroke: Ox.attr(p, 'stroke') != 'false'));
    }
    return out;
  }

  SlidePicture? _picture(XmlElement e, _Ctx c, _Xf xf, XmlElement? ph) {
    final spPr = Ox.child(e, 'spPr');
    XmlElement? layoutSp, masterSp;
    if (ph != null) (layoutSp, masterSp) = _placeholderSources(ph, c);
    var frame = _xfrm(spPr) ?? _xfrm(Ox.child(layoutSp, 'spPr')) ?? _xfrm(Ox.child(masterSp, 'spPr'));
    if (frame == null) return null;
    frame = xf.apply(frame);
    final blipFill = Ox.child(e, 'blipFill');
    final blip = Ox.child(blipFill, 'blip');
    final id = _image(Ox.attrQ(blip, 'r:embed'), c);
    if (id == null) return null;
    final src = Ox.child(blipFill, 'srcRect');
    double crop(String a) => (Ox.doubleAttr(src, a) ?? 0) / 100000;
    final x = Ox.child(spPr, 'xfrm');
    final cNvPr = _cNvPr(e);
    return SlidePicture(
      frame: frame,
      rotation: (Ox.doubleAttr(x, 'rot') ?? 0) / 60000,
      flipH: Ox.attr(x, 'flipH') == '1',
      flipV: Ox.attr(x, 'flipV') == '1',
      id: Ox.attr(cNvPr, 'id'),
      name: Ox.attr(cNvPr, 'name'),
      fromSlide: c.fromSlide,
      imageId: id,
      cropLeft: crop('l'),
      cropTop: crop('t'),
      cropRight: crop('r'),
      cropBottom: crop('b'),
      geometry: Ox.attr(Ox.child(spPr, 'prstGeom'), 'prst') ?? 'rect',
      line: _line(Ox.child(spPr, 'ln'), c),
    );
  }

  void _graphicFrame(XmlElement e, _Ctx c, _Xf xf, List<SlideShape> out) {
    final x = Ox.child(e, 'xfrm');
    final off = Ox.child(x, 'off'), ext = Ox.child(x, 'ext');
    final frame = xf.apply(SlideRect(
      Units.emu(Ox.doubleAttr(off, 'x') ?? 0),
      Units.emu(Ox.doubleAttr(off, 'y') ?? 0),
      Units.emu(Ox.doubleAttr(ext, 'cx') ?? 0),
      Units.emu(Ox.doubleAttr(ext, 'cy') ?? 0),
    ));
    final gd = Ox.path(e, ['graphic', 'graphicData']);
    final uri = Ox.attr(gd, 'uri') ?? '';
    final cNvPr = _cNvPr(e);
    if (uri.endsWith('/table')) {
      final t = _table(Ox.child(gd, 'tbl'), frame, c);
      if (t != null) {
        t
          ..id = Ox.attr(cNvPr, 'id')
          ..fromSlide = c.fromSlide;
        out.add(t);
      }
      return;
    }
    if (uri.contains('diagram')) {
      final before = out.length;
      _diagram(gd!, frame, c, out);
      if (out.length > before) return;
    }
    // OLE objects / charts with a fallback picture.
    final pic = Ox.firstDescendant(gd, 'pic');
    if (pic != null) {
      final blip = Ox.firstDescendant(pic, 'blip');
      final id = _image(Ox.attrQ(blip, 'r:embed'), c);
      if (id != null) {
        out.add(SlidePicture(frame: frame, imageId: id, fromSlide: c.fromSlide));
        return;
      }
    }
    final label = uri.contains('chart') ? 'Chart' : uri.contains('ole') ? 'Embedded object' : 'Object';
    out.add(SlideAutoShape(
      frame: frame,
      fromSlide: c.fromSlide,
      geometry: 'rect',
      fill: const SlideFill(color: 0x14000000),
      line: const SlideLine(color: 0x33000000),
      text: SlideTextBody(anchor: 'ctr', paragraphs: [
        SlideParagraph(align: SlideAlign.center, runs: [
          SlideRun(text: label, size: math.max(10, math.min(24, frame.h / 6)), color: 0x99000000, italic: true),
        ]),
      ]),
    ));
  }

  void _diagram(XmlElement gd, SlideRect frame, _Ctx c, List<SlideShape> out) {
    final relIds = Ox.child(gd, 'relIds');
    final dm = Ox.attrQ(relIds, 'r:dm');
    final dmRel = dm == null ? null : c.rels[dm];
    String? drawingPart;
    if (dmRel != null) {
      final data = pkg.xml(OfficePackage.resolve(c.part, dmRel.target));
      final ext = Ox.firstDescendant(data?.rootElement, 'dataModelExt');
      final rid = Ox.attr(ext, 'relId');
      final rel = rid == null ? null : c.rels[rid];
      if (rel != null) drawingPart = OfficePackage.resolve(c.part, rel.target);
    }
    if (drawingPart == null) return;
    final doc = pkg.xml(drawingPart);
    final tree = Ox.firstDescendant(doc?.rootElement, 'spTree');
    if (tree == null) return;
    final dctx = _Ctx(
      part: drawingPart,
      rels: pkg.relMap(drawingPart),
      master: c.master,
      layout: c.layout,
      fromSlide: false,
      slideNumber: c.slideNumber,
    );
    _shapes(tree, dctx, _Xf(1, 1, frame.x, frame.y), out);
  }

  // ---------------------------------------------------------------------------
  // Tables

  SlideTable? _table(XmlElement? tbl, SlideRect frame, _Ctx c) {
    if (tbl == null) return null;
    final cols = [
      for (final g in Ox.children(Ox.child(tbl, 'tblGrid'), 'gridCol'))
        Units.emu(Ox.doubleAttr(g, 'w') ?? 0),
    ];
    final tblPr = Ox.child(tbl, 'tblPr');
    final styleId = Ox.child(tblPr, 'tableStyleId')?.innerText.trim();
    final style = styleId == null ? null : _tableStyles[styleId];
    final firstRow = Ox.attr(tblPr, 'firstRow') == '1';
    final bandRow = Ox.attr(tblPr, 'bandRow') == '1';
    final firstCol = Ox.attr(tblPr, 'firstCol') == '1';
    final lastRow = Ox.attr(tblPr, 'lastRow') == '1';

    int? styleFill(String part) {
      final el = Ox.child(style, part);
      return _colorIn(Ox.path(el, ['tcStyle', 'fill', 'solidFill']), c);
    }

    (int?, bool?) styleText(String part) {
      final el = Ox.child(Ox.child(style, part), 'tcTxStyle');
      if (el == null) return (null, null);
      final b = Ox.attr(el, 'b');
      return (_colorIn(el, c), b == null ? null : b == 'on');
    }

    final accent = c.master.theme.colors['accent1'] ?? 0xFF4472C4;
    final rows = <List<SlideTableCell>>[];
    final heights = <double>[];
    final trs = Ox.children(tbl, 'tr').toList();
    for (var r = 0; r < trs.length; r++) {
      final tr = trs[r];
      heights.add(Units.emu(Ox.doubleAttr(tr, 'h') ?? 0));
      final row = <SlideTableCell>[];
      var col = 0;
      for (final tc in Ox.children(tr, 'tc')) {
        final tcPr = Ox.child(tc, 'tcPr');
        final isHeader = firstRow && r == 0;
        final isLast = lastRow && r == trs.length - 1;
        final isFirstCol = firstCol && col == 0;
        final part = isHeader
            ? 'firstRow'
            : isLast
                ? 'lastRow'
                : isFirstCol
                    ? 'firstCol'
                    : bandRow
                        ? ((firstRow ? r - 1 : r) % 2 == 0 ? 'band1H' : 'band2H')
                        : 'wholeTbl';
        var fill = _fill(tcPr, c);
        if (fill == null) {
          final sc = style != null ? (styleFill(part) ?? styleFill('wholeTbl')) : null;
          if (sc != null) {
            fill = SlideFill(color: sc);
          } else if (style == null) {
            // Default "Medium Style 2 – Accent 1".
            if (isHeader) {
              fill = SlideFill(color: accent);
            } else {
              final band = (firstRow ? r - 1 : r) % 2 == 0;
              fill = SlideFill(color: _tint(accent, band && bandRow ? 0.4 : 0.2));
            }
          }
        }
        var (txtColor, bold) = style != null ? styleText(part) : (null, null);
        if (style != null && txtColor == null) (txtColor, _) = styleText('wholeTbl');
        if (style == null && isHeader) {
          txtColor = 0xFFFFFFFF;
          bold = true;
        }
        final body = _textBody(Ox.child(tc, 'txBody'), c, null, null, null, txtColor,
                tableCell: true, forceBold: bold) ??
            SlideTextBody();
        body
          ..insetLeft = Units.emu(Ox.doubleAttr(tcPr, 'marL') ?? 91440)
          ..insetRight = Units.emu(Ox.doubleAttr(tcPr, 'marR') ?? 91440)
          ..insetTop = Units.emu(Ox.doubleAttr(tcPr, 'marT') ?? 45720)
          ..insetBottom = Units.emu(Ox.doubleAttr(tcPr, 'marB') ?? 45720)
          ..anchor = Ox.attr(tcPr, 'anchor') ?? 't';
        final border = _colorIn(Ox.child(Ox.child(tcPr, 'lnB') ?? Ox.child(tcPr, 'lnL'), 'solidFill'), c) ??
            (style == null ? 0xFFFFFFFF : null);
        row.add(SlideTableCell(
          text: body,
          fill: fill,
          colSpan: Ox.intAttr(tc, 'gridSpan') ?? 1,
          rowSpan: Ox.intAttr(tc, 'rowSpan') ?? 1,
          merged: Ox.attr(tc, 'hMerge') == '1' || Ox.attr(tc, 'vMerge') == '1',
          borderColor: border,
        ));
        col++;
      }
      rows.add(row);
    }
    if (rows.isEmpty) return null;
    return SlideTable(frame: frame, columns: cols, rows: rows, rowHeights: heights);
  }

  static int _tint(int c, double v) {
    int t(int ch) => (ch + (255 - ch) * (1 - v)).round().clamp(0, 255);
    return 0xFF000000 | (t((c >> 16) & 0xFF) << 16) | (t((c >> 8) & 0xFF) << 8) | t(c & 0xFF);
  }

  // ---------------------------------------------------------------------------
  // Text

  SlideTextBody? _textBody(XmlElement? txBody, _Ctx c, XmlElement? ph, XmlElement? layoutSp,
      XmlElement? masterSp, int? fontRefColor,
      {bool tableCell = false, bool? forceBold}) {
    final layoutBody = Ox.child(layoutSp, 'txBody');
    final masterBody = Ox.child(masterSp, 'txBody');
    if (txBody == null) return null;
    final type = ph == null ? null : (Ox.attr(ph, 'type') ?? 'obj');
    XmlElement? styleRoot;
    final tx = c.master.txStyles;
    if (type == 'title' || type == 'ctrTitle') {
      styleRoot = Ox.child(tx, 'titleStyle');
    } else if (type == null || type == 'dt' || type == 'ftr' || type == 'sldNum' || type == 'hdr') {
      styleRoot = Ox.child(tx, 'otherStyle');
    } else {
      styleRoot = Ox.child(tx, 'bodyStyle');
    }

    // bodyPr inheritance.
    final bodyPrs = [
      Ox.child(txBody, 'bodyPr'),
      Ox.child(layoutBody, 'bodyPr'),
      Ox.child(masterBody, 'bodyPr'),
    ];
    String? bAttr(String a) {
      for (final b in bodyPrs) {
        final v = Ox.attr(b, a);
        if (v != null) return v;
      }
      return null;
    }

    double inset(String a, double def) {
      final v = bAttr(a);
      return v == null ? def : Units.emu(double.tryParse(v) ?? 0);
    }

    var fontScale = 1.0;
    var lnReduction = 0.0;
    for (final b in bodyPrs) {
      final na = Ox.child(b, 'normAutofit');
      if (na != null) {
        fontScale = (Ox.doubleAttr(na, 'fontScale') ?? 100000) / 100000;
        lnReduction = (Ox.doubleAttr(na, 'lnSpcReduction') ?? 0) / 100000;
        break;
      }
      if (Ox.child(b, 'noAutofit') != null || Ox.child(b, 'spAutoFit') != null) break;
    }

    final body = SlideTextBody(
      insetLeft: inset('lIns', 7.2),
      insetTop: inset('tIns', 3.6),
      insetRight: inset('rIns', 7.2),
      insetBottom: inset('bIns', 3.6),
      anchor: bAttr('anchor') ?? (type == 'title' || type == 'ctrTitle' ? 'ctr' : 't'),
      wrap: bAttr('wrap') != 'none',
      fontScale: fontScale,
      vertical: (bAttr('vert') ?? 'horz').startsWith('vert'),
    );

    final lists = [
      Ox.child(txBody, 'lstStyle'),
      Ox.child(layoutBody, 'lstStyle'),
      Ox.child(masterBody, 'lstStyle'),
      if (!tableCell) styleRoot,
      if (type == null || tableCell) _defaultTextStyle,
    ];
    final counters = <int, int>{};
    for (final p in Ox.children(txBody, 'p')) {
      final pPr = Ox.child(p, 'pPr');
      final level = (int.tryParse(Ox.attr(pPr, 'lvl') ?? '0') ?? 0).clamp(0, 8);
      final lvlName = 'lvl${level + 1}pPr';
      final chain = <XmlElement>[
        ?pPr,
        for (final l in lists)
          if (Ox.child(l, lvlName) != null) Ox.child(l, lvlName)!,
      ];
      String? pAttr(String a) {
        for (final e in chain) {
          final v = Ox.attr(e, a);
          if (v != null) return v;
        }
        return null;
      }

      XmlElement? pChild(String local) {
        for (final e in chain) {
          final v = Ox.child(e, local);
          if (v != null) return v;
        }
        return null;
      }

      final defRPrs = [for (final e in chain) ?Ox.child(e, 'defRPr')];

      SlideRun makeRun(XmlElement? rPr, String text, {String? link}) {
        final rs = [?rPr, ...defRPrs];
        String? rAttr(String a) {
          for (final e in rs) {
            final v = Ox.attr(e, a);
            if (v != null) return v;
          }
          return null;
        }

        XmlElement? rChild(String local) {
          for (final e in rs) {
            final v = Ox.child(e, local);
            if (v != null) return v;
          }
          return null;
        }

        final size = (double.tryParse(rAttr('sz') ?? '') ?? 1800) / 100;
        var font = Ox.attr(rChild('latin'), 'typeface') ?? Ox.attr(rChild('ea'), 'typeface');
        if (font == '+mj-lt' || font == '+mj-ea') font = c.master.theme.major;
        if (font == null || font == '+mn-lt' || font == '+mn-ea') font = c.master.theme.minor;
        if (type == 'title' || type == 'ctrTitle') {
          final f = Ox.attr(rChild('latin'), 'typeface');
          if (f == null || f == '+mj-lt') font = c.master.theme.major ?? font;
        }
        int? color;
        for (final e in rs) {
          final fill = Ox.child(e, 'solidFill');
          if (fill != null) {
            color = _colorIn(fill, c);
            break;
          }
          final grad = Ox.child(e, 'gradFill');
          if (grad != null) {
            color = _colorIn(Ox.child(Ox.child(grad, 'gsLst'), 'gs'), c);
            break;
          }
        }
        color ??= fontRefColor ?? _baseColor(XmlElement(XmlName('schemeClr'), [XmlAttribute(XmlName('val'), 'tx1')]), c);
        final u = rAttr('u');
        final strike = rAttr('strike');
        final b = rAttr('b');
        return SlideRun(
          text: text,
          size: size * body.fontScale,
          bold: forceBold ?? (b == '1' || b == 'true'),
          italic: rAttr('i') == '1' || rAttr('i') == 'true',
          underline: u != null && u != 'none',
          strike: strike != null && strike != 'noStrike',
          color: color ?? 0xFF000000,
          font: font,
          link: link,
          highlight: _colorIn(rChild('highlight'), c),
          baseline: (double.tryParse(rAttr('baseline') ?? '') ?? 0) / 1000,
          caps: rAttr('cap') == 'all',
        );
      }

      final runs = <SlideRun>[];
      for (final r in Ox.elements(p)) {
        switch (r.name.local) {
          case 'r':
            final rPr = Ox.child(r, 'rPr');
            final hl = Ox.child(rPr, 'hlinkClick');
            final rid = Ox.attrQ(hl, 'r:id');
            final link = rid == null ? null : c.rels[rid]?.target;
            runs.add(makeRun(rPr, Ox.child(r, 't')?.innerText ?? '', link: link));
          case 'br':
            runs.add(makeRun(Ox.child(r, 'rPr'), '\n'));
          case 'fld':
            final t = Ox.attr(r, 'type') ?? '';
            var text = Ox.child(r, 't')?.innerText ?? '';
            if (t == 'slidenum') text = '${c.slideNumber}';
            runs.add(makeRun(Ox.child(r, 'rPr'), text));
        }
      }
      final endSize = (double.tryParse(Ox.attr(Ox.child(p, 'endParaRPr'), 'sz') ??
                  Ox.attr(defRPrs.firstOrNull, 'sz') ??
                  '') ??
              1800) /
          100 *
          body.fontScale;

      // Paragraph properties.
      final algn = pAttr('algn');
      double spacing(String local, double size) {
        final el = pChild(local);
        final pts = Ox.child(el, 'spcPts');
        if (pts != null) return (Ox.doubleAttr(pts, 'val') ?? 0) / 100;
        final pct = Ox.child(el, 'spcPct');
        if (pct != null) return (Ox.doubleAttr(pct, 'val') ?? 0) / 100000 * size * 1.2;
        return 0;
      }

      final size = runs.isEmpty ? endSize : runs.map((r) => r.size).reduce(math.max);
      var lineSpacing = 1.0;
      final ln = pChild('lnSpc');
      if (Ox.child(ln, 'spcPct') != null) {
        lineSpacing = (Ox.doubleAttr(Ox.child(ln, 'spcPct'), 'val') ?? 100000) / 100000;
      } else if (Ox.child(ln, 'spcPts') != null) {
        lineSpacing = ((Ox.doubleAttr(Ox.child(ln, 'spcPts'), 'val') ?? 0) / 100) / (size * 1.2);
      }
      lineSpacing = (lineSpacing * (1 - lnReduction)).clamp(0.5, 4.0);

      SlideBullet? bullet;
      String? label;
      final hasText = runs.any((r) => r.text.trim().isNotEmpty);
      XmlElement? buType;
      for (final e in chain) {
        for (final k in Ox.elements(e)) {
          if (k.name.local == 'buNone' || k.name.local == 'buChar' || k.name.local == 'buAutoNum' || k.name.local == 'buBlip') {
            buType = k;
            break;
          }
        }
        if (buType != null) break;
      }
      if (buType != null && buType.name.local != 'buNone' && hasText) {
        final buClr = pChild('buClr');
        final buSz = Ox.doubleAttr(pChild('buSzPct'), 'val');
        final buFont = Ox.attr(pChild('buFont'), 'typeface');
        if (buType.name.local == 'buAutoNum') {
          final scheme = Ox.attr(buType, 'type') ?? 'arabicPeriod';
          final start = Ox.intAttr(buType, 'startAt') ?? 1;
          final n = counters[level] = (counters[level] ?? (start - 1)) + 1;
          for (final k in counters.keys.toList()) {
            if (k > level) counters.remove(k);
          }
          label = slideAutoNumber(scheme, n);
          bullet = SlideBullet(autoNumber: scheme, startAt: start);
        } else {
          final ch = Ox.attr(buType, 'char') ?? '•';
          label = _bulletChar(ch, buFont);
          bullet = SlideBullet(
            char: label,
            color: buClr == null ? null : _colorIn(buClr, c),
            sizePercent: buSz == null ? 1 : buSz / 100000,
            font: buFont,
          );
        }
      } else if (hasText) {
        counters.remove(level);
      }

      body.paragraphs.add(SlideParagraph(
        runs: runs,
        align: switch (algn) {
          'ctr' => SlideAlign.center,
          'r' => SlideAlign.right,
          'just' || 'dist' => SlideAlign.justify,
          _ => SlideAlign.left,
        },
        level: level,
        bullet: bullet,
        bulletLabel: label,
        marginLeft: Units.emu(double.tryParse(pAttr('marL') ?? '0') ?? 0),
        indent: Units.emu(double.tryParse(pAttr('indent') ?? '0') ?? 0),
        spaceBefore: spacing('spcBef', size),
        spaceAfter: spacing('spcAft', size),
        lineSpacing: lineSpacing,
        endSize: endSize,
      ));
    }
    return body;
  }

  static String _bulletChar(String ch, String? font) {
    if (ch.isEmpty) return '•';
    final f = (font ?? '').toLowerCase();
    final code = ch.runes.first;
    if (f.contains('wingdings')) {
      const m = {
        0xA7: '▪', 0xD8: '➢', 0xFC: '✓', 0x76: '❖', 0x6C: '●',
        0x6E: '■', 0x71: '❑', 0x75: '◆', 0xA1: '○', 0xE0: '➔',
        0xE8: '➔', 0xF0: '⇨', 0x9F: '•', 0x77: '⬥',
      };
      return m[code >= 0xF000 ? code - 0xF000 : code] ?? '•';
    }
    if (f.contains('symbol') && (code == 0xB7 || code == 0xF0B7)) return '•';
    if (code >= 0xF000) return '•';
    return ch;
  }
}
