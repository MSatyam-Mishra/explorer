import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../common/office_package.dart';
import '../common/office_xml.dart';
import 'doc_model.dart';
import 'docx_parser.dart' show loadImageData;

/// Parses OpenDocument text (`.odt`, `.ott`) or flat XML (`.fodt`).
DocModel parseOdtBytes(Uint8List bytes) {
  if (OfficePackage.isZip(bytes)) {
    final pkg = OfficePackage.decode(bytes);
    final content = pkg.xml('content.xml');
    if (content == null) {
      throw const FormatException('This OpenDocument file has no content.');
    }
    return _OdtParser(pkg, content, pkg.xml('styles.xml')).parse();
  }
  final doc = XmlDocument.parse(decodeXmlBytes(bytes));
  return _OdtParser(null, doc, doc).parse();
}

class _TextProps {
  bool? bold, italic, underline, strike, caps, smallCaps;
  int? color;
  int? background;
  double? size;
  double? sizePercent;
  String? font;
  int? vert;
  bool hidden = false;

  void merge(_TextProps o) {
    bold = o.bold ?? bold;
    italic = o.italic ?? italic;
    underline = o.underline ?? underline;
    strike = o.strike ?? strike;
    caps = o.caps ?? caps;
    smallCaps = o.smallCaps ?? smallCaps;
    color = o.color ?? color;
    background = o.background ?? background;
    if (o.size != null) {
      size = o.size;
      sizePercent = null;
    } else if (o.sizePercent != null) {
      sizePercent = o.sizePercent;
    }
    font = o.font ?? font;
    vert = o.vert ?? vert;
    hidden = hidden || o.hidden;
  }

  DocRunStyle apply(DocRunStyle s) {
    var size = this.size ?? s.fontSize;
    if (sizePercent != null && size != null) size = size * sizePercent!;
    return s.copyWith(
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      allCaps: caps,
      smallCaps: smallCaps,
      color: color ?? s.color,
      highlight: background ?? s.highlight,
      fontSize: size,
      fontFamily: font ?? s.fontFamily,
      vertAlign: vert == null
          ? null
          : vert == 1
              ? DocVertAlign.superscript
              : vert == 2
                  ? DocVertAlign.subscript
                  : DocVertAlign.baseline,
    );
  }
}

class _ParaProps {
  DocAlign? align;
  double? left, right, indent, before, after, line, lineExact;
  bool? breakBefore, keepNext;
  int? background;
  int? outline;
  bool? border;

  void merge(_ParaProps o) {
    align = o.align ?? align;
    left = o.left ?? left;
    right = o.right ?? right;
    indent = o.indent ?? indent;
    before = o.before ?? before;
    after = o.after ?? after;
    line = o.line ?? line;
    lineExact = o.lineExact ?? lineExact;
    breakBefore = o.breakBefore ?? breakBefore;
    keepNext = o.keepNext ?? keepNext;
    background = o.background ?? background;
    outline = o.outline ?? outline;
    border = o.border ?? border;
  }
}

class _Style {
  _Style(this.name, this.family, this.parent, this.display);
  final String name;
  final String family;
  final String? parent;
  final String? display;
  final _TextProps text = _TextProps();
  final _ParaProps para = _ParaProps();
  int? cellBackground;
  bool? cellBorder;
  double? columnWidth;
  String? listStyle;
}

class _ListLevel {
  _ListLevel(this.bullet, this.format, this.prefix, this.suffix, this.bulletChar, this.start);
  final bool bullet;
  final String format;
  final String prefix;
  final String suffix;
  final String bulletChar;
  final int start;
}

class _OdtParser {
  _OdtParser(this.pkg, this.content, this.styles);

  final OfficePackage? pkg;
  final XmlDocument content;
  final XmlDocument? styles;

  final Map<String, _Style> _styles = {};
  final Map<String, _Style> _autoStyles = {};
  final Map<String, String> _fontFaces = {};
  final Map<String, Map<int, _ListLevel>> _lists = {};
  final Map<String, DocImageData> _images = {};
  _TextProps _defaultText = _TextProps();
  _ParaProps _defaultPara = _ParaProps();
  DocPageSetup _page = DocPageSetup.a4;
  int _imageNo = 0;
  int _noteNo = 0;

  DocModel parse() {
    final sroot = styles?.rootElement;
    final croot = content.rootElement;
    for (final root in [sroot, croot]) {
      if (root == null) continue;
      _readFontFaces(Ox.child(root, 'font-face-decls'));
    }
    if (sroot != null) {
      _readStyles(Ox.child(sroot, 'styles'), _styles);
      _readStyles(Ox.child(sroot, 'automatic-styles'), _styles);
      _readPage(sroot);
    }
    if (!identical(sroot, croot)) {
      _readStyles(Ox.child(croot, 'styles'), _styles);
    }
    _readStyles(Ox.child(croot, 'automatic-styles'), _autoStyles);

    final text = Ox.path(croot, ['body', 'text']);
    if (text == null) {
      throw const FormatException('This OpenDocument file has no text body.');
    }
    final base = _baseRun();
    final blocks = _blocks(text, base, const []);
    final headings = <int, DocRunStyle>{};
    for (var l = 1; l <= 6; l++) {
      final st = _findStyle('Heading_20_$l') ?? _findStyle('Heading $l');
      if (st != null) headings[l] = _resolveText(st.name, base, auto: false);
    }
    final defaults = DocModel.defaultHeadingStyles(base);
    for (var l = 1; l <= 6; l++) {
      headings.putIfAbsent(l, () => defaults[l]!);
    }
    return DocModel(
      format: 'odt',
      blocks: blocks.isEmpty ? [DocParagraph()] : blocks,
      images: _images,
      page: _page,
      baseStyle: base,
      headingStyles: headings,
    );
  }

  DocRunStyle _baseRun() {
    var s = const DocRunStyle(fontSize: 12, fontFamily: 'Liberation Serif');
    final t = _TextProps()..merge(_defaultText);
    final std = _findStyle('Standard');
    if (std != null) t.merge(_chainText(std.name, auto: false));
    s = t.apply(s);
    return s;
  }

  _Style? _findStyle(String name) => _styles[name];

  void _readFontFaces(XmlElement? decls) {
    for (final f in Ox.children(decls, 'font-face')) {
      final name = Ox.attr(f, 'name');
      var family = Ox.attr(f, 'font-family') ?? name;
      if (name == null || family == null) continue;
      family = family.replaceAll("'", '').replaceAll('"', '');
      _fontFaces[name] = family;
    }
  }

  void _readPage(XmlElement root) {
    final master = Ox.firstDescendant(Ox.child(root, 'master-styles'), 'master-page');
    final layoutName = Ox.attr(master, 'page-layout-name');
    XmlElement? layout;
    for (final l in Ox.descendants(Ox.child(root, 'automatic-styles'), 'page-layout')) {
      if (Ox.attr(l, 'name') == layoutName || layout == null) layout = l;
    }
    final p = Ox.child(layout, 'page-layout-properties');
    if (p == null) return;
    final w = Units.length(Ox.attr(p, 'page-width'));
    final h = Units.length(Ox.attr(p, 'page-height'));
    _page = DocPageSetup(
      width: w ?? 595.3,
      height: h ?? 841.9,
      marginTop: Units.length(Ox.attr(p, 'margin-top')) ?? 56.7,
      marginBottom: Units.length(Ox.attr(p, 'margin-bottom')) ?? 56.7,
      marginLeft: Units.length(Ox.attr(p, 'margin-left')) ?? 56.7,
      marginRight: Units.length(Ox.attr(p, 'margin-right')) ?? 56.7,
    );
  }

  void _readStyles(XmlElement? container, Map<String, _Style> into) {
    for (final e in Ox.elements(container)) {
      switch (e.name.local) {
        case 'default-style':
          if (Ox.attr(e, 'family') == 'paragraph') {
            _defaultText = _textProps(Ox.child(e, 'text-properties'));
            _defaultPara = _paraProps(Ox.child(e, 'paragraph-properties'));
          }
        case 'style':
          final name = Ox.attr(e, 'name');
          if (name == null) continue;
          final st = _Style(name, Ox.attr(e, 'family') ?? 'paragraph',
              Ox.attr(e, 'parent-style-name'), Ox.attr(e, 'display-name'));
          st.text.merge(_textProps(Ox.child(e, 'text-properties')));
          st.para.merge(_paraProps(Ox.child(e, 'paragraph-properties')));
          final ol = int.tryParse(Ox.attr(e, 'default-outline-level') ?? '');
          if (ol != null) st.para.outline = ol;
          st.listStyle = Ox.attr(e, 'list-style-name');
          final cell = Ox.child(e, 'table-cell-properties');
          if (cell != null) {
            st.cellBackground = _color(Ox.attr(cell, 'background-color'));
            final b = Ox.attr(cell, 'border') ??
                Ox.attr(cell, 'border-top') ??
                Ox.attr(cell, 'border-left');
            if (b != null) st.cellBorder = b != 'none';
          }
          final col = Ox.child(e, 'table-column-properties');
          if (col != null) st.columnWidth = Units.length(Ox.attr(col, 'column-width'));
          into[name] = st;
        case 'list-style':
          final name = Ox.attr(e, 'name');
          if (name == null) continue;
          final levels = <int, _ListLevel>{};
          for (final l in Ox.elements(e)) {
            final lvl = (int.tryParse(Ox.attr(l, 'level') ?? '1') ?? 1) - 1;
            if (l.name.local == 'list-level-style-bullet') {
              levels[lvl] = _ListLevel(true, 'bullet', '', '', Ox.attr(l, 'bullet-char') ?? '•', 1);
            } else if (l.name.local == 'list-level-style-number') {
              levels[lvl] = _ListLevel(
                false,
                switch (Ox.attr(l, 'num-format') ?? '1') {
                  'a' => 'lowerLetter',
                  'A' => 'upperLetter',
                  'i' => 'lowerRoman',
                  'I' => 'upperRoman',
                  '' => 'none',
                  _ => 'decimal',
                },
                Ox.attr(l, 'num-prefix') ?? '',
                Ox.attr(l, 'num-suffix') ?? '.',
                '',
                int.tryParse(Ox.attr(l, 'start-value') ?? '1') ?? 1,
              );
            }
          }
          _lists[name] = levels;
      }
    }
  }

  int? _color(String? v) {
    if (v == null || v == 'transparent') return null;
    return Ox.hexColor(v);
  }

  _TextProps _textProps(XmlElement? e) {
    final t = _TextProps();
    if (e == null) return t;
    final weight = Ox.attr(e, 'font-weight');
    if (weight != null) {
      t.bold = weight == 'bold' || (int.tryParse(weight) ?? 400) >= 600;
    }
    final style = Ox.attr(e, 'font-style');
    if (style != null) t.italic = style == 'italic' || style == 'oblique';
    final ul = Ox.attr(e, 'text-underline-style');
    if (ul != null) t.underline = ul != 'none';
    final lt = Ox.attr(e, 'text-line-through-style');
    if (lt != null) t.strike = lt != 'none';
    t.color = _color(Ox.attr(e, 'color'));
    t.background = _color(Ox.attr(e, 'background-color'));
    final size = Ox.attr(e, 'font-size');
    if (size != null) {
      if (size.endsWith('%')) {
        t.sizePercent = (double.tryParse(size.substring(0, size.length - 1)) ?? 100) / 100;
      } else {
        t.size = Units.length(size);
      }
    }
    final fontName = Ox.attr(e, 'font-name');
    if (fontName != null) t.font = _fontFaces[fontName] ?? fontName;
    final family = Ox.attr(e, 'font-family');
    if (family != null) t.font = family.replaceAll("'", '');
    final pos = Ox.attr(e, 'text-position');
    if (pos != null) {
      final first = pos.split(' ').first;
      if (first == 'super' || (double.tryParse(first.replaceAll('%', '')) ?? 0) > 0) {
        t.vert = 1;
      } else if (first == 'sub' || (double.tryParse(first.replaceAll('%', '')) ?? 0) < 0) {
        t.vert = 2;
      } else {
        t.vert = 0;
      }
    }
    final variant = Ox.attr(e, 'font-variant');
    if (variant != null) t.smallCaps = variant == 'small-caps';
    final transform = Ox.attr(e, 'text-transform');
    if (transform != null) t.caps = transform == 'uppercase';
    if (Ox.attr(e, 'display') == 'none') t.hidden = true;
    return t;
  }

  _ParaProps _paraProps(XmlElement? e) {
    final p = _ParaProps();
    if (e == null) return p;
    switch (Ox.attr(e, 'text-align')) {
      case 'center':
        p.align = DocAlign.center;
      case 'end':
      case 'right':
        p.align = DocAlign.right;
      case 'justify':
        p.align = DocAlign.justify;
      case 'start':
      case 'left':
        p.align = DocAlign.left;
    }
    p.left = Units.length(Ox.attr(e, 'margin-left'));
    p.right = Units.length(Ox.attr(e, 'margin-right'));
    p.indent = Units.length(Ox.attr(e, 'text-indent'));
    p.before = Units.length(Ox.attr(e, 'margin-top'));
    p.after = Units.length(Ox.attr(e, 'margin-bottom'));
    final lh = Ox.attr(e, 'line-height');
    if (lh != null) {
      if (lh.endsWith('%')) {
        p.line = (double.tryParse(lh.substring(0, lh.length - 1)) ?? 100) / 100;
      } else {
        p.lineExact = Units.length(lh);
      }
    }
    final bb = Ox.attr(e, 'break-before');
    if (bb != null) p.breakBefore = bb == 'page';
    final kn = Ox.attr(e, 'keep-with-next');
    if (kn != null) p.keepNext = kn == 'always';
    p.background = _color(Ox.attr(e, 'background-color'));
    final border = Ox.attr(e, 'border-bottom') ?? Ox.attr(e, 'border');
    if (border != null) p.border = border != 'none';
    return p;
  }

  _Style? _style(String? name, {bool auto = true}) {
    if (name == null) return null;
    return (auto ? _autoStyles[name] : null) ?? _styles[name];
  }

  _TextProps _chainText(String? name, {bool auto = true}) {
    final chain = <_Style>[];
    var cur = _style(name, auto: auto);
    final seen = <String>{};
    while (cur != null && seen.add(cur.name)) {
      chain.add(cur);
      cur = _style(cur.parent, auto: false);
    }
    final t = _TextProps();
    for (final s in chain.reversed) {
      t.merge(s.text);
    }
    return t;
  }

  _ParaProps _chainPara(String? name) {
    final chain = <_Style>[];
    var cur = _style(name);
    final seen = <String>{};
    while (cur != null && seen.add(cur.name)) {
      chain.add(cur);
      cur = _style(cur.parent, auto: false);
    }
    final p = _ParaProps()..merge(_defaultPara);
    for (final s in chain.reversed) {
      p.merge(s.para);
    }
    return p;
  }

  int? _headingFromStyle(String? name) {
    var cur = _style(name);
    final seen = <String>{};
    while (cur != null && seen.add(cur.name)) {
      final n = (cur.display ?? cur.name).replaceAll('_20_', ' ').toLowerCase();
      final m = RegExp(r'^heading\s*([1-9])$').firstMatch(n);
      if (m != null) return int.parse(m.group(1)!).clamp(1, 6);
      cur = _style(cur.parent, auto: false);
    }
    return null;
  }

  DocRunStyle _resolveText(String? name, DocRunStyle base, {bool auto = true}) =>
      _chainText(name, auto: auto).apply(base);

  // -------------------------------------------------------------------------

  List<DocBlock> _blocks(XmlElement container, DocRunStyle base, List<_ListCtx> lists) {
    final out = <DocBlock>[];
    for (final e in Ox.elements(container)) {
      switch (e.name.local) {
        case 'p':
        case 'h':
          _paragraph(e, base, lists, out);
        case 'list':
          _list(e, base, lists, out);
        case 'table':
          final t = _table(e, base);
          if (t != null) out.add(t);
        case 'section':
        case 'index-body':
        case 'table-of-content':
        case 'alphabetical-index':
        case 'illustration-index':
        case 'object-index':
        case 'user-index':
        case 'bibliography':
        case 'table-index':
        case 'deletion':
          if (e.name.local != 'deletion') {
            out.addAll(_blocks(e, base, lists));
          }
        case 'soft-page-break':
          break;
      }
    }
    return out;
  }

  void _list(XmlElement list, DocRunStyle base, List<_ListCtx> parents, List<DocBlock> out) {
    final styleName = Ox.attr(list, 'style-name') ?? (parents.isEmpty ? null : parents.last.style);
    final ctx = _ListCtx(styleName, parents.length);
    if (parents.isNotEmpty) ctx.counters = parents.last.counters;
    final chain = [...parents, ctx];
    for (final item in Ox.elements(list)) {
      if (item.name.local != 'list-item' && item.name.local != 'list-header') continue;
      ctx.header = item.name.local == 'list-header';
      ctx.firstInItem = true;
      out.addAll(_blocks(item, base, chain));
    }
  }

  void _paragraph(XmlElement p, DocRunStyle base, List<_ListCtx> lists, List<DocBlock> out) {
    final styleName = Ox.attr(p, 'style-name');
    final pp = _chainPara(styleName);
    var heading = p.name.local == 'h'
        ? (int.tryParse(Ox.attr(p, 'outline-level') ?? '1') ?? 1).clamp(1, 6)
        : _headingFromStyle(styleName);
    if (heading == null && pp.outline != null && pp.outline! > 0 && p.name.local == 'h') {
      heading = pp.outline!.clamp(1, 6);
    }
    final runBase = _resolveText(styleName, base);
    final inlines = <DocInline>[];
    final extra = <DocBlock>[];
    _inlines(p, runBase, null, inlines, extra);
    _merge(inlines);

    DocListInfo? list;
    if (lists.isNotEmpty) {
      final ctx = lists.last;
      final level = ctx.depth;
      if (!ctx.header && ctx.firstInItem) {
        ctx.firstInItem = false;
        final def = _lists[ctx.style]?[level] ?? _lists[lists.first.style]?[level];
        final bullet = def?.bullet ?? true;
        final counters = ctx.counters;
        while (counters.length <= level) {
          counters.add(0);
        }
        counters[level] = counters[level] == 0 ? (def?.start ?? 1) : counters[level] + 1;
        for (var k = level + 1; k < counters.length; k++) {
          counters[k] = 0;
        }
        final label = bullet
            ? (def?.bulletChar ?? '•')
            : '${def?.prefix ?? ''}${formatListNumber(counters[level], def?.format ?? 'decimal')}${def?.suffix ?? '.'}';
        list = DocListInfo(
          ordered: !bullet,
          level: level,
          format: bullet ? 'bullet' : (def?.format ?? 'decimal'),
          label: label,
        );
      }
    }

    var left = pp.left ?? 0;
    var first = pp.indent ?? 0;
    if (list != null && left <= 0) {
      left = 36.0 * (list.level + 1);
      first = -18;
    }
    if (pp.breakBefore == true && out.isNotEmpty) out.add(DocPageBreak());
    out.add(DocParagraph(
      inlines: inlines,
      headingLevel: heading,
      styleId: styleName,
      align: pp.align ?? DocAlign.left,
      indentLeft: left,
      indentRight: pp.right ?? 0,
      firstLine: first,
      spaceBefore: pp.before ?? 0,
      spaceAfter: pp.after ?? 0,
      lineSpacing: pp.line ?? 1.0,
      lineExact: pp.lineExact,
      list: list,
      shading: pp.background,
      keepNext: pp.keepNext ?? (heading != null),
      borderBottom: pp.border == true ? const DocBorder() : null,
      markStyle: runBase,
    ));
    out.addAll(extra);
  }

  void _inlines(XmlElement e, DocRunStyle style, String? link, List<DocInline> out, List<DocBlock> extra) {
    for (final n in e.children) {
      if (n is XmlText || n is XmlCDATA) {
        final t = n.value!.replaceAll(RegExp(r'[\r\n]+'), ' ');
        if (t.isNotEmpty) out.add(DocText(t, style, link: link));
        continue;
      }
      if (n is! XmlElement) continue;
      switch (n.name.local) {
        case 'span':
          final st = _style(Ox.attr(n, 'style-name'));
          final s = st == null ? style : _chainText(st.name).apply(style);
          if (_chainText(st?.name).hidden) continue;
          _inlines(n, s, link, out, extra);
        case 'a':
          final href = Ox.attr(n, 'href');
          final st = Ox.attr(n, 'style-name');
          _inlines(n, st == null ? style : _resolveText(st, style), href ?? link, out, extra);
        case 's':
          final c = int.tryParse(Ox.attr(n, 'c') ?? '1') ?? 1;
          out.add(DocText(' ' * c.clamp(1, 200), style, link: link));
        case 'tab':
          out.add(DocText('\t', style, link: link));
        case 'line-break':
          out.add(DocText('\n', style, link: link));
        case 'note':
          _noteNo++;
          final cite = Ox.child(n, 'note-citation');
          out.add(DocObject(
            kind: 'Footnote',
            displayText: cite == null ? '$_noteNo' : Ox.text(cite),
            style: style.copyWith(vertAlign: DocVertAlign.superscript),
          ));
        case 'frame':
          _frame(n, style, out, extra);
        case 'soft-page-break':
        case 'bookmark':
        case 'bookmark-start':
        case 'bookmark-end':
        case 'reference-mark':
        case 'reference-mark-start':
        case 'reference-mark-end':
        case 'annotation':
        case 'annotation-end':
        case 'change':
        case 'change-start':
        case 'change-end':
          break;
        case 'custom-shape':
        case 'rect':
        case 'g':
          for (final tb in Ox.elements(n)) {
            if (tb.name.local == 'p') {
              final ps = <DocBlock>[];
              _paragraph(tb, style, const [], ps);
              extra.addAll(ps);
            }
          }
        default:
          // Fields (date, page-number, sequence, …) and unknown inline
          // elements contribute their text.
          _inlines(n, style, link, out, extra);
      }
    }
  }

  void _frame(XmlElement frame, DocRunStyle style, List<DocInline> out, List<DocBlock> extra) {
    final w = Units.length(Ox.attr(frame, 'width')) ?? 0;
    final h = Units.length(Ox.attr(frame, 'height')) ?? 0;
    final image = Ox.child(frame, 'image');
    if (image != null) {
      Uint8List? bytes;
      String path = 'image';
      final href = Ox.attr(image, 'href');
      if (href != null && pkg != null) {
        path = href.startsWith('./') ? href.substring(2) : href;
        bytes = pkg!.bytes(path);
      }
      final bin = Ox.child(image, 'binary-data');
      if (bytes == null && bin != null) {
        try {
          bytes = base64.decode(Ox.text(bin).replaceAll(RegExp(r'\s'), ''));
        } catch (_) {}
      }
      if (bytes != null) {
        final id = 'odt_image_${_imageNo++}';
        _images[id] = loadImageData(bytes, path);
        var iw = w, ih = h;
        if (iw <= 0 || ih <= 0) {
          final px = imagePixelSize(bytes);
          if (px != null) {
            iw = px.$1 * 0.75;
            ih = px.$2 * 0.75;
          }
        }
        out.add(DocImage(imageId: id, width: iw, height: ih));
      }
      return;
    }
    final box = Ox.child(frame, 'text-box');
    if (box != null) {
      // Text boxes flow after the paragraph so their text isn't lost.
      extra.addAll(_blocks(box, style, const []));
    }
  }

  void _merge(List<DocInline> inlines) {
    for (var i = inlines.length - 1; i > 0; i--) {
      final a = inlines[i - 1], b = inlines[i];
      if (a is DocText && b is DocText && a.style == b.style && a.link == b.link) {
        a.text += b.text;
        inlines.removeAt(i);
      }
    }
  }

  DocTable? _table(XmlElement t, DocRunStyle base) {
    final widths = <double>[];
    var borders = false;
    final rows = <DocTableRow>[];
    final covered = <int, int>{}; // column -> remaining rows covered

    void addRow(XmlElement r, bool header) {
      final repeat = (int.tryParse(Ox.attr(r, 'number-rows-repeated') ?? '1') ?? 1).clamp(1, 50);
      for (var k = 0; k < repeat; k++) {
        final row = DocTableRow(header: header);
        var col = 0;
        var skipHorizontal = 0;
        for (final c in Ox.elements(r)) {
          if (c.name.local == 'covered-table-cell') {
            if (skipHorizontal > 0) {
              skipHorizontal--;
              col++;
              continue;
            }
            row.cells.add(DocTableCell(covered: true));
            col++;
            continue;
          }
          if (c.name.local != 'table-cell') continue;
          final span = (int.tryParse(Ox.attr(c, 'number-columns-spanned') ?? '1') ?? 1).clamp(1, 64);
          final rowSpan = (int.tryParse(Ox.attr(c, 'number-rows-spanned') ?? '1') ?? 1).clamp(1, 1000);
          final colRepeat = (int.tryParse(Ox.attr(c, 'number-columns-repeated') ?? '1') ?? 1).clamp(1, 64);
          final st = _style(Ox.attr(c, 'style-name'));
          if (st?.cellBorder == true) borders = true;
          for (var rep = 0; rep < colRepeat; rep++) {
            row.cells.add(DocTableCell(
              blocks: _blocks(c, base, const []),
              colSpan: span,
              rowSpan: rowSpan,
              shading: st?.cellBackground,
            ));
            col += span;
          }
          skipHorizontal = span - 1;
          if (rowSpan > 1) covered[col - span] = rowSpan - 1;
        }
        rows.add(row);
      }
    }

    void walk(XmlElement e, bool header) {
      for (final c in Ox.elements(e)) {
        switch (c.name.local) {
          case 'table-column':
            final rep = (int.tryParse(Ox.attr(c, 'number-columns-repeated') ?? '1') ?? 1).clamp(1, 256);
            final w = _style(Ox.attr(c, 'style-name'))?.columnWidth ?? 0;
            for (var k = 0; k < rep; k++) {
              widths.add(w);
            }
          case 'table-columns':
          case 'table-column-group':
            walk(c, header);
          case 'table-header-rows':
            walk(c, true);
          case 'table-rows':
          case 'table-row-group':
            walk(c, header);
          case 'table-row':
            addRow(c, header);
        }
      }
    }

    walk(t, false);
    if (rows.isEmpty) return null;
    return DocTable(
      rows: rows,
      columnWidths: widths.isNotEmpty && widths.every((w) => w > 0) ? widths : [],
      borders: borders,
    );
  }
}

class _ListCtx {
  _ListCtx(this.style, this.depth);
  final String? style;
  final int depth;
  List<int> counters = [];
  bool header = false;
  bool firstInItem = true;
}
