import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../common/office_package.dart';
import '../common/office_xml.dart';
import 'slide_model.dart';

/// Parses OpenDocument presentations (`.odp`, `.otp`, flat `.fodp`).
SlideDeck parseOdpBytes(Uint8List bytes) {
  if (OfficePackage.isZip(bytes)) {
    final pkg = OfficePackage.decode(bytes);
    final content = pkg.xml('content.xml');
    if (content == null) {
      throw const FormatException('This presentation has no content.');
    }
    return _OdpParser(pkg, content, pkg.xml('styles.xml')).parse();
  }
  final doc = XmlDocument.parse(decodeXmlBytes(bytes));
  return _OdpParser(null, doc, doc).parse();
}

class _Style {
  _Style(this.parent);
  final String? parent;
  final Map<String, String> graphic = {};
  final Map<String, String> text = {};
  final Map<String, String> paragraph = {};
  final Map<String, String> page = {};
}

class _OdpParser {
  _OdpParser(this.pkg, this.content, this.styles);

  final OfficePackage? pkg;
  final XmlDocument content;
  final XmlDocument? styles;
  final Map<String, _Style> _styles = {};
  final Map<String, String> _fonts = {};
  final Map<String, String> _masterLayouts = {};
  final Map<String, String> _masterStyles = {};
  final Map<String, Map<String, String>> _pageLayouts = {};
  final Map<String, SlideImageData> _images = {};
  int _imageNo = 0;

  SlideDeck parse() {
    final sroot = styles?.rootElement;
    final croot = content.rootElement;
    for (final root in {sroot, croot}) {
      if (root == null) continue;
      for (final f in Ox.children(
        Ox.child(root, 'font-face-decls'),
        'font-face',
      )) {
        final n = Ox.attr(f, 'name');
        final fam = Ox.attr(f, 'font-family');
        if (n != null && fam != null) _fonts[n] = fam.replaceAll("'", '');
      }
      _readStyles(Ox.child(root, 'styles'));
      _readStyles(Ox.child(root, 'automatic-styles'));
      for (final m in Ox.children(
        Ox.child(root, 'master-styles'),
        'master-page',
      )) {
        final name = Ox.attr(m, 'name');
        if (name == null) continue;
        final layout = Ox.attr(m, 'page-layout-name');
        if (layout != null) _masterLayouts[name] = layout;
        final st = Ox.attr(m, 'style-name');
        if (st != null) _masterStyles[name] = st;
      }
    }

    final pres = Ox.path(croot, ['body', 'presentation']);
    if (pres == null) {
      throw const FormatException('This file has no presentation body.');
    }
    final pages = Ox.children(pres, 'page').toList();
    var width = 720.0, height = 540.0;
    if (pages.isNotEmpty) {
      final master = Ox.attr(pages.first, 'master-page-name');
      final layout =
          _pageLayouts[_masterLayouts[master]] ??
          (_pageLayouts.isEmpty ? null : _pageLayouts.values.first);
      width = Units.length(layout?['page-width']) ?? width;
      height = Units.length(layout?['page-height']) ?? height;
    }
    final slides = <Slide>[];
    for (var i = 0; i < pages.length; i++) {
      slides.add(_slide(pages[i], i, width, height));
    }
    return SlideDeck(
      format: 'odp',
      width: width,
      height: height,
      slides: slides,
      images: _images,
    );
  }

  void _readStyles(XmlElement? container) {
    for (final e in Ox.elements(container)) {
      final name = Ox.attr(e, 'name');
      if (name == null) continue;
      if (e.name.local == 'page-layout') {
        final props = Ox.child(e, 'page-layout-properties');
        _pageLayouts[name] = {
          for (final a in props?.attributes ?? <XmlAttribute>[])
            a.name.local: a.value,
        };
        continue;
      }
      if (e.name.local != 'style' && e.name.local != 'default-style') continue;
      final st = _Style(Ox.attr(e, 'parent-style-name'));
      void fill(Map<String, String> m, XmlElement? props) {
        for (final a in props?.attributes ?? <XmlAttribute>[]) {
          m[a.name.local] = a.value;
        }
      }

      fill(st.graphic, Ox.child(e, 'graphic-properties'));
      fill(st.text, Ox.child(e, 'text-properties'));
      fill(st.paragraph, Ox.child(e, 'paragraph-properties'));
      fill(st.page, Ox.child(e, 'drawing-page-properties'));
      _styles[name] = st;
    }
  }

  String? _prop(String? style, String group, String key) {
    var cur = style;
    final seen = <String>{};
    while (cur != null && seen.add(cur)) {
      final st = _styles[cur];
      if (st == null) return null;
      final m = switch (group) {
        'graphic' => st.graphic,
        'text' => st.text,
        'paragraph' => st.paragraph,
        _ => st.page,
      };
      final v = m[key];
      if (v != null) return v;
      cur = st.parent;
    }
    return null;
  }

  Slide _slide(XmlElement page, int index, double w, double h) {
    final shapes = <SlideShape>[];
    for (final e in Ox.elements(page)) {
      _shape(e, shapes, w, h);
    }
    final st = Ox.attr(page, 'style-name');
    final masterStyle = _masterStyles[Ox.attr(page, 'master-page-name')];
    SlideFill? bg;
    for (final s in [st, masterStyle]) {
      if (s == null) continue;
      final fill = _prop(s, 'page', 'fill');
      final color = Ox.hexColor(_prop(s, 'page', 'fill-color'));
      if (fill == 'solid' && color != null) {
        bg = SlideFill(color: color);
        break;
      }
    }
    var notes = '';
    final n = Ox.child(page, 'notes');
    if (n != null) {
      final parts = <String>[];
      for (final f in Ox.descendants(n, 'frame')) {
        if (Ox.attr(f, 'class') == 'notes') {
          for (final p in Ox.descendants(f, 'p')) {
            parts.add(Ox.text(p));
          }
        }
      }
      notes = parts.join('\n').trim();
    }
    return Slide(
      index: index,
      shapes: shapes,
      background: bg ?? const SlideFill(color: 0xFFFFFFFF),
      notes: notes,
    );
  }

  SlideRect? _frame(XmlElement e) {
    final x = Units.length(Ox.attr(e, 'x'));
    final y = Units.length(Ox.attr(e, 'y'));
    final w = Units.length(Ox.attr(e, 'width'));
    final h = Units.length(Ox.attr(e, 'height'));
    if (w == null || h == null) return null;
    var fx = x ?? 0, fy = y ?? 0;
    final tr = Ox.attr(e, 'transform');
    if (tr != null) {
      final t = RegExp(
        r'translate\s*\(\s*([^\s,)]+)[\s,]+([^\s,)]+)\s*\)',
      ).firstMatch(tr);
      if (t != null) {
        fx = Units.length(t.group(1)) ?? fx;
        fy = Units.length(t.group(2)) ?? fy;
      }
    }
    return SlideRect(fx, fy, w, h);
  }

  double _rotation(XmlElement e) {
    final tr = Ox.attr(e, 'transform');
    if (tr == null) return 0;
    final m = RegExp(r'rotate\s*\(\s*([-0-9.eE]+)\s*\)').firstMatch(tr);
    if (m == null) return 0;
    return -(double.tryParse(m.group(1)!) ?? 0) * 180 / math.pi;
  }

  void _shape(XmlElement e, List<SlideShape> out, double w, double h) {
    switch (e.name.local) {
      case 'g':
        for (final c in Ox.elements(e)) {
          _shape(c, out, w, h);
        }
      case 'frame':
        final frame = _frame(e);
        if (frame == null) return;
        final cls = Ox.attr(e, 'class');
        final image = Ox.child(e, 'image');
        final box = Ox.child(e, 'text-box');
        if (box != null) {
          out.add(
            SlideAutoShape(
              frame: frame,
              rotation: _rotation(e),
              placeholder: cls,
              fill: _fill(Ox.attr(e, 'style-name')),
              line: _line(Ox.attr(e, 'style-name'), defaultNone: true),
              text: _text(box, cls, Ox.attr(e, 'style-name')),
            ),
          );
        } else if (image != null) {
          final id = _image(image);
          if (id != null) {
            out.add(
              SlidePicture(frame: frame, imageId: id, rotation: _rotation(e)),
            );
          }
        } else if (Ox.child(e, 'table') != null) {
          out.add(_table(Ox.child(e, 'table')!, frame));
        } else {
          out.add(
            SlideAutoShape(
              frame: frame,
              fill: const SlideFill(color: 0x14000000),
              text: SlideTextBody(
                anchor: 'ctr',
                paragraphs: [
                  SlideParagraph(
                    align: SlideAlign.center,
                    runs: [
                      SlideRun(
                        text: 'Object',
                        size: 14,
                        italic: true,
                        color: 0x99000000,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
      case 'custom-shape':
      case 'rect':
      case 'ellipse':
      case 'circle':
      case 'polygon':
        final frame = _frame(e);
        if (frame == null) return;
        var geometry = switch (e.name.local) {
          'ellipse' || 'circle' => 'ellipse',
          _ => 'rect',
        };
        final eg = Ox.child(e, 'enhanced-geometry');
        final type = Ox.attr(eg, 'type');
        if (type != null) {
          geometry = switch (type) {
            'ellipse' || 'circle' => 'ellipse',
            'round-rectangle' || 'round-square' => 'roundRect',
            'isosceles-triangle' => 'triangle',
            'right-triangle' => 'rtTriangle',
            'diamond' => 'diamond',
            'parallelogram' => 'parallelogram',
            'trapezoid' => 'trapezoid',
            'hexagon' => 'hexagon',
            'octagon' => 'octagon',
            'pentagon' => 'pentagon',
            'right-arrow' => 'rightArrow',
            'left-arrow' => 'leftArrow',
            'up-arrow' => 'upArrow',
            'down-arrow' => 'downArrow',
            'star5' => 'star5',
            'heart' => 'heart',
            'cross' => 'plus',
            'ring' => 'donut',
            _ => 'rect',
          };
        }
        final st = Ox.attr(e, 'style-name');
        final hasText =
            Ox.children(e, 'p').isNotEmpty || Ox.children(e, 'list').isNotEmpty;
        out.add(
          SlideAutoShape(
            frame: frame,
            rotation: _rotation(e),
            geometry: geometry,
            fill: _fill(st) ?? const SlideFill(color: 0xFF729FCF),
            line: _line(st),
            text: hasText
                ? _text(e, null, st, anchor: 'ctr', align: SlideAlign.center)
                : null,
          ),
        );
      case 'line':
      case 'connector':
        final x1 = Units.length(Ox.attr(e, 'x1')) ?? 0,
            y1 = Units.length(Ox.attr(e, 'y1')) ?? 0;
        final x2 = Units.length(Ox.attr(e, 'x2')) ?? 0,
            y2 = Units.length(Ox.attr(e, 'y2')) ?? 0;
        out.add(
          SlideAutoShape(
            frame: SlideRect(
              math.min(x1, x2),
              math.min(y1, y2),
              (x2 - x1).abs(),
              (y2 - y1).abs(),
            ),
            flipH: x2 < x1,
            flipV: y2 < y1,
            geometry: 'line',
            line:
                _line(Ox.attr(e, 'style-name')) ??
                const SlideLine(color: 0xFF000000),
          ),
        );
    }
  }

  SlideFill? _fill(String? st) {
    if (st == null) return null;
    final fill = _prop(st, 'graphic', 'fill');
    if (fill == 'none') return const SlideFill();
    final color = Ox.hexColor(_prop(st, 'graphic', 'fill-color'));
    if (fill == 'solid' || (fill == null && color != null)) {
      final opacity = _prop(st, 'graphic', 'opacity');
      var c = color ?? 0xFF729FCF;
      if (opacity != null && opacity.endsWith('%')) {
        final a =
            ((double.tryParse(opacity.replaceAll('%', '')) ?? 100) / 100 * 255)
                .round()
                .clamp(0, 255);
        c = (a << 24) | (c & 0xFFFFFF);
      }
      return SlideFill(color: c);
    }
    if (fill == 'gradient') return SlideFill(color: color ?? 0xFF729FCF);
    return null;
  }

  SlideLine? _line(String? st, {bool defaultNone = false}) {
    if (st == null) {
      return defaultNone ? null : const SlideLine(color: 0xFF3465A4);
    }
    final stroke = _prop(st, 'graphic', 'stroke');
    if (stroke == 'none') return null;
    if (stroke == null && defaultNone) return null;
    return SlideLine(
      color: Ox.hexColor(_prop(st, 'graphic', 'stroke-color')) ?? 0xFF3465A4,
      width: Units.length(_prop(st, 'graphic', 'stroke-width')) ?? 0.75,
      dash: stroke == 'dash' ? 'dash' : null,
    );
  }

  String? _image(XmlElement image) {
    Uint8List? bytes;
    final href = Ox.attr(image, 'href');
    if (href != null && pkg != null) {
      bytes = pkg!.bytes(href.startsWith('./') ? href.substring(2) : href);
    }
    final bin = Ox.child(image, 'binary-data');
    if (bytes == null && bin != null) {
      try {
        bytes = base64.decode(Ox.text(bin).replaceAll(RegExp(r'\s'), ''));
      } catch (_) {}
    }
    if (bytes == null) return null;
    final id = 'odp_image_${_imageNo++}';
    _images[id] = SlideImageData(bytes, sniffImageExtension(bytes) ?? 'png');
    return id;
  }

  SlideTextBody _text(
    XmlElement box,
    String? cls,
    String? frameStyle, {
    String? anchor,
    SlideAlign? align,
  }) {
    final defaultSize = switch (cls) {
      'title' => 40.0,
      'subtitle' => 28.0,
      'outline' => 24.0,
      _ => 18.0,
    };
    final va = _prop(frameStyle, 'graphic', 'textarea-vertical-align');
    final body = SlideTextBody(
      anchor:
          anchor ??
          (va == 'middle'
              ? 'ctr'
              : va == 'bottom'
              ? 'b'
              : (cls == 'title' ? 'ctr' : 't')),
    );
    void addParagraph(XmlElement p, int level, String? bullet) {
      final runs = <SlideRun>[];
      SlideRun run(String text, String? style) {
        String? tp(String k) =>
            _prop(style, 'text', k) ??
            _prop(Ox.attr(p, 'style-name'), 'text', k) ??
            _prop(frameStyle, 'text', k);
        final weight = tp('font-weight');
        final fontName = tp('font-name');
        return SlideRun(
          text: text,
          size: Units.length(tp('font-size')) ?? defaultSize,
          bold: weight == 'bold' || (int.tryParse(weight ?? '') ?? 400) >= 600,
          italic: tp('font-style') == 'italic',
          underline: (tp('text-underline-style') ?? 'none') != 'none',
          strike: (tp('text-line-through-style') ?? 'none') != 'none',
          color: Ox.hexColor(tp('color')) ?? 0xFF000000,
          font: fontName == null
              ? tp('font-family')
              : (_fonts[fontName] ?? fontName),
        );
      }

      void walk(XmlElement e, String? style) {
        for (final n in e.children) {
          if (n is XmlText) {
            final t = n.value.replaceAll(RegExp(r'[\r\n]+'), ' ');
            if (t.isNotEmpty) runs.add(run(t, style));
          } else if (n is XmlElement) {
            switch (n.name.local) {
              case 'span':
              case 'a':
                walk(n, Ox.attr(n, 'style-name') ?? style);
              case 's':
                runs.add(
                  run(' ' * (int.tryParse(Ox.attr(n, 'c') ?? '1') ?? 1), style),
                );
              case 'tab':
                runs.add(run('\t', style));
              case 'line-break':
                runs.add(run('\n', style));
              default:
                walk(n, style);
            }
          }
        }
      }

      walk(p, null);
      final pa = _prop(Ox.attr(p, 'style-name'), 'paragraph', 'text-align');
      final size = runs.isEmpty ? defaultSize : runs.first.size;
      body.paragraphs.add(
        SlideParagraph(
          runs: runs,
          level: level,
          align:
              align ??
              switch (pa) {
                'center' => SlideAlign.center,
                'end' || 'right' => SlideAlign.right,
                'justify' => SlideAlign.justify,
                _ =>
                  cls == 'title' || cls == 'subtitle'
                      ? SlideAlign.center
                      : SlideAlign.left,
              },
          bulletLabel:
              bullet != null && runs.any((r) => r.text.trim().isNotEmpty)
              ? bullet
              : null,
          marginLeft: bullet != null ? size * (1.2 + level * 1.2) : 0,
          indent: bullet != null ? -size * 1.0 : 0,
          spaceBefore: bullet != null ? size * 0.15 : 0,
          endSize: size,
        ),
      );
    }

    void walkBlocks(XmlElement container, int level, bool inList) {
      for (final e in Ox.elements(container)) {
        switch (e.name.local) {
          case 'p':
          case 'h':
            addParagraph(e, level, inList || cls == 'outline' ? '•' : null);
          case 'list':
            for (final item in Ox.elements(e)) {
              walkBlocks(item, inList ? level + 1 : level, true);
            }
        }
      }
    }

    walkBlocks(box, 0, false);
    return body;
  }

  SlideTable _table(XmlElement t, SlideRect frame) {
    final rows = <List<SlideTableCell>>[];
    for (final r in Ox.descendants(t, 'table-row')) {
      final row = <SlideTableCell>[];
      for (final c in Ox.elements(r)) {
        if (c.name.local != 'table-cell' &&
            c.name.local != 'covered-table-cell') {
          continue;
        }
        final text = _text(c, null, null);
        for (final p in text.paragraphs) {
          for (final run in p.runs) {
            run.size = 14;
          }
        }
        row.add(
          SlideTableCell(
            text: text,
            merged: c.name.local == 'covered-table-cell',
            colSpan:
                int.tryParse(Ox.attr(c, 'number-columns-spanned') ?? '1') ?? 1,
          ),
        );
      }
      rows.add(row);
    }
    final cols = rows.isEmpty ? 1 : rows.map((r) => r.length).reduce(math.max);
    return SlideTable(
      frame: frame,
      columns: List.filled(cols, frame.w / math.max(1, cols)),
      rows: rows,
      rowHeights: List.filled(rows.length, 0),
    );
  }
}
