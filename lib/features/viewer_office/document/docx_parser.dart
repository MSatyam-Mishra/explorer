import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import '../common/office_package.dart';
import '../common/office_xml.dart';
import 'doc_model.dart';

/// Parses DOCX/DOCM/DOTX/DOTM bytes. Runs fine in a background isolate.
DocModel parseDocxBytes(Uint8List bytes) =>
    DocxParser(OfficePackage.decode(bytes)).parse();

class _Style {
  _Style(
    this.id,
    this.type,
    this.name,
    this.basedOn,
    this.pPr,
    this.rPr,
    this.tblPr,
    this.tblStylePr,
    this.isDefault,
  );
  final String id;
  final String type;
  final String? name;
  final String? basedOn;
  final XmlElement? pPr;
  final XmlElement? rPr;
  final XmlElement? tblPr;
  final List<XmlElement> tblStylePr;
  final bool isDefault;
}

class _Lvl {
  _Lvl(this.numFmt, this.lvlText, this.start, this.pPr, this.rPr);
  final String numFmt;
  final String lvlText;
  final int start;
  final XmlElement? pPr;
  final XmlElement? rPr;
}

class _Num {
  _Num(this.abstractId);
  final String abstractId;
  final Map<int, int> startOverrides = {};
  final Map<int, _Lvl> lvlOverrides = {};
}

class _PProps {
  DocAlign align = DocAlign.left;
  double left = 0, right = 0, firstLine = 0;
  double before = 0, after = 0;
  double line = 1.0;
  double? lineExact;
  String? numId;
  int ilvl = 0;
  int? shading;
  DocBorder? top, bottom;
  bool keepNext = false,
      pageBreakBefore = false,
      bidi = false,
      contextual = false;
  int? outline;
}

/// Context of the part being parsed (main document, header, footer).
class _PartCtx {
  _PartCtx(this.partName, this.rels);
  final String partName;
  final Map<String, OfficeRel> rels;
}

class _TableCtx {
  _TableCtx(this.styleId, this.pPrs, this.rPrs);
  final String? styleId;
  final List<XmlElement> pPrs;
  final List<XmlElement> rPrs;
}

class _Field {
  bool separated = false;
  final StringBuffer instr = StringBuffer();
  String? link;
  String? code;
}

class DocxParser {
  DocxParser(this.pkg);

  final OfficePackage pkg;

  final Map<String, _Style> _styles = {};
  String? _defaultParaStyle;
  String? _defaultTableStyle;
  XmlElement? _defaultPPr;
  XmlElement? _defaultRPr;
  String? _majorFont;
  String? _minorFont;
  final Map<String, Map<int, _Lvl>> _abstractNums = {};
  final Map<String, _Num> _nums = {};
  final Map<String, List<int?>> _counters = {};
  final Set<String> _seenNums = {};
  final Map<String, DocImageData> _images = {};
  final List<String> _warnings = [];
  final List<_Field> _fields = [];
  int _footnoteNo = 0;
  int _endnoteNo = 0;

  final Map<String, List<XmlElement>> _pChainCache = {};
  final Map<String, List<XmlElement>> _rChainCache = {};
  final Map<String, int?> _headingCache = {};
  final Map<String, DocRunStyle> _baseCache = {};

  DocModel parse() {
    final main = pkg.mainPart() ?? 'word/document.xml';
    final doc = pkg.xml(main);
    if (doc == null) {
      throw const FormatException('This document has no readable body.');
    }
    _loadTheme(main);
    _loadStyles(main);
    _loadNumbering(main);

    final root = doc.rootElement;
    final body = Ox.child(root, 'body');
    if (body == null) {
      throw const FormatException('This document has no body.');
    }
    final mainRels = pkg.relMap(main);
    final ctx = _PartCtx(main, mainRels);

    final blocks = _parseBlocks(body, ctx, null);
    final sectPr = Ox.child(body, 'sectPr');
    final page = _pageSetup(sectPr);

    // Header & footer of the final section.
    final header = <DocBlock>[];
    final footer = <DocBlock>[];
    if (sectPr != null) {
      final h = _headerFooterPart(sectPr, 'headerReference', mainRels, main);
      if (h != null) header.addAll(h);
      final f = _headerFooterPart(sectPr, 'footerReference', mainRels, main);
      if (f != null) footer.addAll(f);
    }

    final headingIds = <int, String>{};
    final headingSet = <String>{};
    for (final s in _styles.values) {
      if (s.type != 'paragraph') continue;
      final lvl = _styleHeading(s.id);
      if (lvl == null) continue;
      headingSet.add(s.id);
      final existing = headingIds[lvl];
      // Prefer the canonical built-in names.
      if (existing == null || (s.name ?? '').toLowerCase() == 'heading $lvl') {
        headingIds[lvl] = s.id;
      }
    }

    final base = _runBase(null, _defaultParaStyle);
    final headingStyles = <int, DocRunStyle>{};
    final headingSpacing = <int, double>{};
    final defaults = DocModel.defaultHeadingStyles(base);
    for (var l = 1; l <= 6; l++) {
      final id = headingIds[l];
      if (id == null) {
        headingStyles[l] = defaults[l]!;
      } else {
        headingStyles[l] = _runBase(null, id);
        final pp = _computePProps(null, id, null);
        headingSpacing[l] = pp.before;
      }
    }

    final hyperlinks = <String, String>{
      for (final r in mainRels.values)
        if (r.kind == 'hyperlink') r.id: r.target,
    };

    return DocModel(
      format: 'docx',
      blocks: blocks,
      images: _images,
      page: page,
      baseStyle: base,
      headingStyles: headingStyles,
      headingSpacing: headingSpacing,
      header: header,
      footer: footer,
      warnings: _warnings,
      docx: DocxSourceInfo(
        mainPart: main,
        headingStyleIds: headingIds,
        normalStyleId: _defaultParaStyle,
        wPrefix: root.name.prefix ?? '',
        bodySectPr: sectPr?.toXmlString(),
        hyperlinkTargets: hyperlinks,
        headingStyleSet: headingSet,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Theme, styles, numbering

  void _loadTheme(String main) {
    for (final r in pkg.rels(main)) {
      if (r.kind != 'theme') continue;
      final doc = pkg.xml(OfficePackage.resolve(main, r.target));
      if (doc == null) return;
      final scheme = Ox.firstDescendant(doc.rootElement, 'fontScheme');
      _majorFont = Ox.attr(Ox.path(scheme, ['majorFont', 'latin']), 'typeface');
      _minorFont = Ox.attr(Ox.path(scheme, ['minorFont', 'latin']), 'typeface');
      return;
    }
  }

  void _loadStyles(String main) {
    String? path;
    for (final r in pkg.rels(main)) {
      if (r.kind == 'styles') path = OfficePackage.resolve(main, r.target);
    }
    final doc = pkg.xml(path ?? 'word/styles.xml');
    if (doc == null) return;
    final root = doc.rootElement;
    final dd = Ox.child(root, 'docDefaults');
    _defaultRPr = Ox.path(dd, ['rPrDefault', 'rPr']);
    _defaultPPr = Ox.path(dd, ['pPrDefault', 'pPr']);
    for (final s in Ox.children(root, 'style')) {
      final id = Ox.attr(s, 'styleId');
      if (id == null) continue;
      final type = Ox.attr(s, 'type') ?? 'paragraph';
      final isDefault =
          Ox.toggle(Ox.child(s, 'default')) == true ||
          ['1', 'true', 'on'].contains(Ox.attr(s, 'default'));
      final style = _Style(
        id,
        type,
        Ox.attr(Ox.child(s, 'name'), 'val'),
        Ox.attr(Ox.child(s, 'basedOn'), 'val'),
        Ox.child(s, 'pPr'),
        Ox.child(s, 'rPr'),
        Ox.child(s, 'tblPr'),
        Ox.children(s, 'tblStylePr').toList(),
        isDefault,
      );
      _styles[id] = style;
      if (isDefault && type == 'paragraph') _defaultParaStyle = id;
      if (isDefault && type == 'table') _defaultTableStyle = id;
    }
    if (_defaultParaStyle == null && _styles.containsKey('Normal')) {
      _defaultParaStyle = 'Normal';
    }
  }

  void _loadNumbering(String main) {
    String? path;
    for (final r in pkg.rels(main)) {
      if (r.kind == 'numbering') path = OfficePackage.resolve(main, r.target);
    }
    final doc = pkg.xml(path ?? 'word/numbering.xml');
    if (doc == null) return;
    final root = doc.rootElement;
    final styleLinks = <String, String>{};
    for (final a in Ox.children(root, 'abstractNum')) {
      final id = Ox.attr(a, 'abstractNumId');
      if (id == null) continue;
      final lvls = <int, _Lvl>{};
      for (final l in Ox.children(a, 'lvl')) {
        final il = int.tryParse(Ox.attr(l, 'ilvl') ?? '') ?? 0;
        lvls[il] = _parseLvl(l);
      }
      _abstractNums[id] = lvls;
      final link = Ox.attr(Ox.child(a, 'numStyleLink'), 'val');
      if (link != null) styleLinks[id] = link;
    }
    for (final n in Ox.children(root, 'num')) {
      final id = Ox.attr(n, 'numId');
      final abs = Ox.attr(Ox.child(n, 'abstractNumId'), 'val');
      if (id == null || abs == null) continue;
      final num = _Num(abs);
      for (final o in Ox.children(n, 'lvlOverride')) {
        final il = int.tryParse(Ox.attr(o, 'ilvl') ?? '') ?? 0;
        final so = Ox.intAttr(Ox.child(o, 'startOverride'), 'val');
        if (so != null) num.startOverrides[il] = so;
        final lvl = Ox.child(o, 'lvl');
        if (lvl != null) num.lvlOverrides[il] = _parseLvl(lvl);
      }
      _nums[id] = num;
    }
    // numStyleLink: the abstract num defers to a numbering style's numId.
    styleLinks.forEach((absId, styleId) {
      if ((_abstractNums[absId] ?? const {}).isNotEmpty) return;
      final st = _styles[styleId];
      final numId = Ox.attr(Ox.path(st?.pPr, ['numPr', 'numId']), 'val');
      final target = numId == null ? null : _nums[numId]?.abstractId;
      if (target != null && _abstractNums[target] != null) {
        _abstractNums[absId] = _abstractNums[target]!;
      }
    });
  }

  _Lvl _parseLvl(XmlElement l) => _Lvl(
    Ox.attr(Ox.child(l, 'numFmt'), 'val') ?? 'decimal',
    Ox.attr(Ox.child(l, 'lvlText'), 'val') ?? '',
    Ox.intAttr(Ox.child(l, 'start'), 'val') ?? 1,
    Ox.child(l, 'pPr'),
    Ox.child(l, 'rPr'),
  );

  _Lvl? _lvl(String numId, int ilvl) {
    final num = _nums[numId];
    if (num == null) return null;
    return num.lvlOverrides[ilvl] ?? _abstractNums[num.abstractId]?[ilvl];
  }

  /// Chain of [prop] elements from the root ancestor style down to [id].
  List<XmlElement> _chain(String? id, String prop) {
    if (id == null) return const [];
    final key = '$prop|$id';
    final cached = prop == 'pPr' ? _pChainCache[key] : _rChainCache[key];
    if (cached != null) return cached;
    final out = <XmlElement>[];
    final seen = <String>{};
    var cur = _styles[id];
    final stack = <_Style>[];
    while (cur != null && seen.add(cur.id)) {
      stack.add(cur);
      cur = cur.basedOn == null ? null : _styles[cur.basedOn];
    }
    for (final s in stack.reversed) {
      final e = prop == 'pPr' ? s.pPr : s.rPr;
      if (e != null) out.add(e);
    }
    (prop == 'pPr' ? _pChainCache : _rChainCache)[key] = out;
    return out;
  }

  int? _styleHeading(String? id) {
    if (id == null) return null;
    if (_headingCache.containsKey(id)) return _headingCache[id];
    int? level;
    final seen = <String>{};
    var cur = _styles[id];
    while (cur != null && seen.add(cur.id)) {
      final name = (cur.name ?? '').toLowerCase().trim();
      final m = RegExp(r'^heading\s*([1-9])$').firstMatch(name);
      if (m != null) {
        level = int.parse(m.group(1)!);
        break;
      }
      final ol = Ox.intAttr(Ox.child(cur.pPr, 'outlineLvl'), 'val');
      if (ol != null && ol < 9) {
        level = ol + 1;
        break;
      }
      cur = cur.basedOn == null ? null : _styles[cur.basedOn];
    }
    if (level != null && level > 6) level = 6;
    _headingCache[id] = level;
    return level;
  }

  // -------------------------------------------------------------------------
  // Property application

  void _applyPPr(_PProps p, XmlElement? pPr) {
    if (pPr == null) return;
    for (final e in Ox.elements(pPr)) {
      switch (e.name.local) {
        case 'jc':
          p.align = _align(Ox.attr(e, 'val'));
        case 'ind':
          final l = Ox.doubleAttr(e, 'left') ?? Ox.doubleAttr(e, 'start');
          final r = Ox.doubleAttr(e, 'right') ?? Ox.doubleAttr(e, 'end');
          final f = Ox.doubleAttr(e, 'firstLine');
          final h = Ox.doubleAttr(e, 'hanging');
          if (l != null) p.left = Units.twips(l);
          if (r != null) p.right = Units.twips(r);
          if (f != null) p.firstLine = Units.twips(f);
          if (h != null) p.firstLine = -Units.twips(h);
        case 'spacing':
          final b = Ox.doubleAttr(e, 'before');
          final a = Ox.doubleAttr(e, 'after');
          if (b != null) p.before = Units.twips(b);
          if (a != null) p.after = Units.twips(a);
          if (_on(Ox.attr(e, 'beforeAutospacing'))) p.before = 14;
          if (_on(Ox.attr(e, 'afterAutospacing'))) p.after = 14;
          final line = Ox.doubleAttr(e, 'line');
          if (line != null) {
            final rule = Ox.attr(e, 'lineRule') ?? 'auto';
            if (rule == 'exact') {
              p.lineExact = Units.twips(line);
            } else if (rule == 'atLeast') {
              p.lineExact = null;
              p.line = 1.0;
              final pt = Units.twips(line);
              if (pt > 16) p.lineExact = pt;
            } else {
              p.lineExact = null;
              p.line = (line / 240).clamp(0.5, 5.0);
            }
          }
        case 'numPr':
          final il = Ox.intAttr(Ox.child(e, 'ilvl'), 'val');
          final id = Ox.attr(Ox.child(e, 'numId'), 'val');
          if (il != null) p.ilvl = il.clamp(0, 8);
          if (id != null) p.numId = id;
        case 'shd':
          final fill = Ox.hexColor(Ox.attr(e, 'fill'));
          p.shading = fill == 0xFFFFFFFF ? null : fill;
        case 'pBdr':
          final t = _border(Ox.child(e, 'top'));
          final b = _border(Ox.child(e, 'bottom'));
          if (Ox.child(e, 'top') != null) p.top = t;
          if (Ox.child(e, 'bottom') != null) p.bottom = b;
        case 'keepNext':
          p.keepNext = Ox.toggle(e) ?? false;
        case 'pageBreakBefore':
          p.pageBreakBefore = Ox.toggle(e) ?? false;
        case 'bidi':
          p.bidi = Ox.toggle(e) ?? false;
        case 'contextualSpacing':
          p.contextual = Ox.toggle(e) ?? false;
        case 'outlineLvl':
          p.outline = Ox.intAttr(e, 'val');
      }
    }
  }

  static bool _on(String? v) => v == '1' || v == 'true' || v == 'on';

  DocBorder? _border(XmlElement? e) {
    if (e == null) return null;
    final v = Ox.attr(e, 'val') ?? 'none';
    if (v == 'none' || v == 'nil') return null;
    final sz = Ox.doubleAttr(e, 'sz') ?? 4;
    return DocBorder(
      color: Ox.hexColor(Ox.attr(e, 'color')) ?? 0xFF000000,
      width: (sz / 8).clamp(0.25, 6),
      space: Ox.doubleAttr(e, 'space') ?? 1,
    );
  }

  static DocAlign _align(String? v) {
    switch (v) {
      case 'center':
        return DocAlign.center;
      case 'right':
      case 'end':
        return DocAlign.right;
      case 'both':
      case 'distribute':
      case 'thaiDistribute':
      case 'mediumKashida':
      case 'highKashida':
      case 'lowKashida':
        return DocAlign.justify;
      default:
        return DocAlign.left;
    }
  }

  static const _highlights = {
    'yellow': 0xFFFFFF00,
    'green': 0xFF00FF00,
    'cyan': 0xFF00FFFF,
    'magenta': 0xFFFF00FF,
    'blue': 0xFF0000FF,
    'red': 0xFFFF0000,
    'darkBlue': 0xFF000080,
    'darkCyan': 0xFF008080,
    'darkGreen': 0xFF008000,
    'darkMagenta': 0xFF800080,
    'darkRed': 0xFF800000,
    'darkYellow': 0xFF808000,
    'darkGray': 0xFF808080,
    'lightGray': 0xFFC0C0C0,
    'black': 0xFF000000,
    'white': 0xFFFFFFFF,
  };

  String? _themeFont(String? theme) {
    if (theme == null) return null;
    return theme.startsWith('major') ? _majorFont : _minorFont;
  }

  DocRunStyle _applyRPr(DocRunStyle s, XmlElement? rPr, [List<bool>? hidden]) {
    if (rPr == null) return s;
    var out = s;
    int? shd;
    var hasHighlight = false;
    for (final e in Ox.elements(rPr)) {
      switch (e.name.local) {
        case 'b':
          out = out.copyWith(bold: Ox.toggle(e));
        case 'i':
          out = out.copyWith(italic: Ox.toggle(e));
        case 'u':
          final v = Ox.attr(e, 'val') ?? 'single';
          out = out.copyWith(underline: v != 'none' && v != '0');
        case 'strike':
        case 'dstrike':
          out = out.copyWith(strike: Ox.toggle(e));
        case 'caps':
          out = out.copyWith(allCaps: Ox.toggle(e));
        case 'smallCaps':
          out = out.copyWith(smallCaps: Ox.toggle(e));
        case 'color':
          out = out.copyWith(color: Ox.hexColor(Ox.attr(e, 'val')));
        case 'highlight':
          hasHighlight = true;
          out = out.copyWith(highlight: _highlights[Ox.attr(e, 'val')]);
        case 'shd':
          shd = Ox.hexColor(Ox.attr(e, 'fill'));
        case 'sz':
          final v = Ox.doubleAttr(e, 'val');
          if (v != null && v > 0) out = out.copyWith(fontSize: v / 2);
        case 'rFonts':
          final f =
              Ox.attr(e, 'ascii') ??
              Ox.attr(e, 'hAnsi') ??
              _themeFont(
                Ox.attr(e, 'asciiTheme') ?? Ox.attr(e, 'hAnsiTheme'),
              ) ??
              Ox.attr(e, 'cs') ??
              Ox.attr(e, 'eastAsia');
          if (f != null) out = out.copyWith(fontFamily: f);
        case 'vertAlign':
          final v = Ox.attr(e, 'val');
          out = out.copyWith(
            vertAlign: v == 'superscript'
                ? DocVertAlign.superscript
                : v == 'subscript'
                ? DocVertAlign.subscript
                : DocVertAlign.baseline,
          );
        case 'vanish':
          if (hidden != null && (Ox.toggle(e) ?? false)) hidden[0] = true;
      }
    }
    if (!hasHighlight &&
        shd != null &&
        shd != 0xFFFFFFFF &&
        out.highlight == null) {
      out = out.copyWith(highlight: shd);
    }
    return out;
  }

  DocRunStyle get _rootRun {
    var s = const DocRunStyle(fontSize: 10, fontFamily: 'Times New Roman');
    s = _applyRPr(s, _defaultRPr);
    return s;
  }

  /// Run formatting inherited by text in a paragraph of [styleId].
  DocRunStyle _runBase(_TableCtx? t, String? styleId) {
    final key = '${t?.styleId}|$styleId';
    final cached = _baseCache[key];
    if (cached != null) return cached;
    var s = _rootRun;
    if (t != null) {
      for (final r in t.rPrs) {
        s = _applyRPr(s, r);
      }
    }
    for (final r in _chain(styleId, 'rPr')) {
      s = _applyRPr(s, r);
    }
    _baseCache[key] = s;
    return s;
  }

  _PProps _computePProps(_TableCtx? t, String? styleId, XmlElement? direct) {
    // First pass: find numbering (style chain + direct).
    final probe = _PProps();
    for (final p in _chain(styleId, 'pPr')) {
      _applyPPr(probe, Ox.child(p, 'numPr') == null ? null : p);
    }
    if (direct != null && Ox.child(direct, 'numPr') != null) {
      final np = Ox.child(direct, 'numPr')!;
      final il = Ox.intAttr(Ox.child(np, 'ilvl'), 'val');
      final id = Ox.attr(Ox.child(np, 'numId'), 'val');
      if (il != null) probe.ilvl = il.clamp(0, 8);
      if (id != null) probe.numId = id;
    }

    final p = _PProps();
    _applyPPr(p, _defaultPPr);
    if (t != null) {
      for (final e in t.pPrs) {
        _applyPPr(p, e);
      }
    }
    for (final e in _chain(styleId, 'pPr')) {
      _applyPPr(p, e);
    }
    if (probe.numId != null && probe.numId != '0') {
      final lvl = _lvl(probe.numId!, probe.ilvl);
      _applyPPr(p, lvl?.pPr);
    }
    _applyPPr(p, direct);
    p.numId = probe.numId;
    p.ilvl = probe.ilvl;
    return p;
  }

  // -------------------------------------------------------------------------
  // Sections, headers, footers

  DocPageSetup _pageSetup(XmlElement? sectPr) {
    if (sectPr == null) return DocPageSetup.letter;
    final sz = Ox.child(sectPr, 'pgSz');
    final mar = Ox.child(sectPr, 'pgMar');
    double tw(XmlElement? e, String a, double def) {
      final v = Ox.doubleAttr(e, a);
      return v == null ? def : Units.twips(v).abs();
    }

    var w = tw(sz, 'w', 612);
    var h = tw(sz, 'h', 792);
    if (w < 72) w = 612;
    if (h < 72) h = 792;
    return DocPageSetup(
      width: w,
      height: h,
      marginTop: tw(mar, 'top', 72),
      marginBottom: tw(mar, 'bottom', 72),
      marginLeft: tw(mar, 'left', 72),
      marginRight: tw(mar, 'right', 72),
      headerDistance: tw(mar, 'header', 36),
      footerDistance: tw(mar, 'footer', 36),
    );
  }

  List<DocBlock>? _headerFooterPart(
    XmlElement sectPr,
    String refName,
    Map<String, OfficeRel> rels,
    String main,
  ) {
    XmlElement? chosen;
    for (final r in Ox.children(sectPr, refName)) {
      final type = Ox.attr(r, 'type') ?? 'default';
      if (type == 'default') chosen = r;
      chosen ??= r;
    }
    final id = Ox.attrQ(chosen, 'r:id');
    final rel = id == null ? null : rels[id];
    if (rel == null) return null;
    final part = OfficePackage.resolve(main, rel.target);
    final doc = pkg.xml(part);
    if (doc == null) return null;
    final saved = List.of(_fields);
    _fields.clear();
    final blocks = _parseBlocks(
      doc.rootElement,
      _PartCtx(part, pkg.relMap(part)),
      null,
    );
    _fields
      ..clear()
      ..addAll(saved);
    return blocks;
  }

  // -------------------------------------------------------------------------
  // Blocks

  List<DocBlock> _parseBlocks(
    XmlElement container,
    _PartCtx ctx,
    _TableCtx? t,
  ) {
    final out = <DocBlock>[];
    for (final e in Ox.elements(container)) {
      switch (e.name.local) {
        case 'p':
          _parseParagraph(e, ctx, t, out);
        case 'tbl':
          final table = _parseTable(e, ctx);
          if (table != null) out.add(table);
        case 'sdt':
          final c = Ox.child(e, 'sdtContent');
          if (c != null) out.addAll(_parseBlocks(c, ctx, t));
        case 'customXml':
        case 'ins':
        case 'moveTo':
        case 'smartTag':
          out.addAll(_parseBlocks(e, ctx, t));
        case 'altChunk':
          if (!_warnings.contains('altChunk')) {
            _warnings.add('altChunk');
          }
      }
    }
    return out;
  }

  void _parseParagraph(
    XmlElement p,
    _PartCtx ctx,
    _TableCtx? t,
    List<DocBlock> out,
  ) {
    final pPr = Ox.child(p, 'pPr');
    final styleId =
        Ox.attr(Ox.child(pPr, 'pStyle'), 'val') ?? _defaultParaStyle;
    final props = _computePProps(t, styleId, pPr);
    final base = _runBase(t, styleId);
    final markStyle = _applyRPr(base, Ox.child(pPr, 'rPr'));

    var heading = _styleHeading(styleId);
    if (heading == null) {
      final ol = Ox.intAttr(Ox.child(pPr, 'outlineLvl'), 'val');
      if (ol != null && ol < 6) heading = ol + 1;
    }

    String? raw;
    final sectPr = Ox.child(pPr, 'sectPr');
    if (pPr != null) {
      if (sectPr != null) {
        final copy = pPr.copy();
        copy.children.removeWhere(
          (n) => n is XmlElement && n.name.local == 'sectPr',
        );
        raw = copy.toXmlString();
      } else {
        raw = pPr.toXmlString();
      }
    }

    DocListInfo? list;
    if (props.numId != null && props.numId != '0') {
      list = _listInfo(props.numId!, props.ilvl, markStyle);
    }

    DocParagraph make() => DocParagraph(
      styleId: styleId,
      headingLevel: heading,
      align: props.align,
      indentLeft: props.left,
      indentRight: props.right,
      firstLine: props.firstLine,
      spaceBefore: props.before,
      spaceAfter: props.after,
      lineSpacing: props.line,
      lineExact: props.lineExact,
      shading: props.shading,
      borderTop: props.top,
      borderBottom: props.bottom,
      keepNext: props.keepNext,
      pageBreakBefore: props.pageBreakBefore,
      rtl: props.bidi,
      contextualSpacing: props.contextual,
      markStyle: markStyle,
      raw: raw,
    );

    var cur = make()..list = list;
    final frames = <DocBlock>[];
    var broke = false;

    void onPageBreak() {
      _mergeRuns(cur.inlines);
      if (cur.inlines.isNotEmpty) out.add(cur);
      out.add(DocPageBreak());
      broke = true;
      cur = make();
    }

    final sink = _InlineSink(() => cur.inlines, onPageBreak);
    _parseInlines(p, ctx, base, sink, frames);
    _mergeRuns(cur.inlines);
    if (!(broke && cur.inlines.isEmpty)) out.add(cur);
    out.addAll(frames);
    if (sectPr != null) {
      out.add(
        DocSectionBreak(
          page: _pageSetup(sectPr),
          newPage:
              (Ox.attr(Ox.child(sectPr, 'type'), 'val') ?? 'nextPage') !=
              'continuous',
          raw: sectPr.toXmlString(),
        ),
      );
    }
  }

  DocListInfo? _listInfo(String numId, int ilvl, DocRunStyle markStyle) {
    final num = _nums[numId];
    final lvl = _lvl(numId, ilvl);
    if (num == null || lvl == null) return null;
    final absId = num.abstractId;
    final counters = _counters.putIfAbsent(absId, () => List.filled(9, null));
    if (_seenNums.add(numId)) {
      num.startOverrides.forEach((l, s) {
        if (l >= 0 && l < 9) counters[l] = s - 1;
      });
    }
    counters[ilvl] = (counters[ilvl] ?? (lvl.start - 1)) + 1;
    for (var i = ilvl + 1; i < 9; i++) {
      counters[i] = null;
    }
    final bullet = lvl.numFmt == 'bullet';
    String label;
    final labelStyle = _applyRPr(
      markStyle,
      lvl.rPr,
    ).copyWith(underline: false, highlight: null);
    if (bullet) {
      final font =
          Ox.attr(Ox.child(lvl.rPr, 'rFonts'), 'ascii') ??
          Ox.attr(Ox.child(lvl.rPr, 'rFonts'), 'hAnsi');
      label = _bulletText(lvl.lvlText, font);
    } else if (lvl.numFmt == 'none') {
      label = lvl.lvlText.replaceAll(RegExp(r'%[1-9]'), '');
    } else {
      label = lvl.lvlText.replaceAllMapped(RegExp(r'%([1-9])'), (m) {
        final k = int.parse(m.group(1)!) - 1;
        final kl = _lvl(numId, k);
        final n = counters[k] ?? kl?.start ?? 1;
        return formatListNumber(n, kl?.numFmt ?? 'decimal');
      });
    }
    return DocListInfo(
      ordered: !bullet,
      level: ilvl,
      numId: numId,
      format: lvl.numFmt,
      label: label,
      labelStyle: bullet
          ? labelStyle.copyWith(fontFamily: markStyle.fontFamily)
          : labelStyle,
    );
  }

  static String _bulletText(String text, String? font) {
    if (text.isEmpty) return '';
    final f = (font ?? '').toLowerCase();
    final c = text.runes.first;
    if (f.contains('courier') && text == 'o') return '◦';
    if (c >= 0xF000 || f.contains('symbol') || f.contains('wingdings')) {
      return mapSymbolChar(c, font);
    }
    if (text == '-') return '–';
    return text;
  }

  // -------------------------------------------------------------------------
  // Inline content

  void _parseInlines(
    XmlElement container,
    _PartCtx ctx,
    DocRunStyle base,
    _InlineSink sink,
    List<DocBlock> frames, {
    String? link,
  }) {
    for (final e in Ox.elements(container)) {
      switch (e.name.local) {
        case 'r':
          _parseRun(e, ctx, base, sink, frames, link);
        case 'hyperlink':
          final id = Ox.attrQ(e, 'r:id');
          final anchor = Ox.attr(e, 'anchor');
          String? target;
          if (id != null) target = ctx.rels[id]?.target;
          if (target == null && anchor != null) target = '#$anchor';
          _parseInlines(e, ctx, base, sink, frames, link: target ?? link);
        case 'fldSimple':
          final instr = (Ox.attr(e, 'instr') ?? '').trim();
          final f = _Field()..separated = true;
          _interpretField(f, instr);
          _fields.add(f);
          _parseInlines(e, ctx, base, sink, frames, link: f.link ?? link);
          _fields.remove(f);
        case 'ins':
        case 'moveTo':
        case 'smartTag':
        case 'customXml':
        case 'dir':
        case 'bdo':
          _parseInlines(e, ctx, base, sink, frames, link: link);
        case 'sdt':
          final c = Ox.child(e, 'sdtContent');
          if (c != null) {
            _parseInlines(c, ctx, base, sink, frames, link: link);
          }
        case 'oMath':
        case 'oMathPara':
          final text = Ox.descendants(e, 't').map((t) => t.innerText).join();
          sink.add(
            DocObject(
              kind: 'Equation',
              displayText: text,
              raw: e.toXmlString(),
              style: base.copyWith(italic: true),
            ),
          );
        case 'del':
        case 'moveFrom':
        case 'pPr':
        case 'bookmarkStart':
        case 'bookmarkEnd':
        case 'proofErr':
        case 'permStart':
        case 'permEnd':
        case 'commentRangeStart':
        case 'commentRangeEnd':
          break;
      }
    }
  }

  bool get _inFieldInstruction => _fields.any((f) => !f.separated);

  String? get _fieldLink {
    for (final f in _fields.reversed) {
      if (f.link != null) return f.link;
    }
    return null;
  }

  String? get _fieldCode {
    for (final f in _fields.reversed) {
      if (f.code != null) return f.code;
    }
    return null;
  }

  void _interpretField(_Field f, String instr) {
    final m = RegExp(r'^\s*(\w+)').firstMatch(instr);
    final code = m?.group(1)?.toUpperCase();
    if (code == 'HYPERLINK') {
      final url = RegExp(r'"([^"]*)"').firstMatch(instr)?.group(1);
      final anchor = RegExp(r'\\l\s+"([^"]*)"').firstMatch(instr)?.group(1);
      if (anchor != null &&
          (url == null || instr.indexOf('\\l') < instr.indexOf('"'))) {
        f.link = '#$anchor';
      } else if (url != null) {
        f.link = anchor != null ? '$url#$anchor' : url;
      }
    } else if (code == 'PAGE' || code == 'NUMPAGES' || code == 'SECTIONPAGES') {
      f.code = code == 'SECTIONPAGES' ? 'NUMPAGES' : code;
    }
  }

  void _parseRun(
    XmlElement r,
    _PartCtx ctx,
    DocRunStyle base,
    _InlineSink sink,
    List<DocBlock> frames,
    String? link,
  ) {
    final rPr = Ox.child(r, 'rPr');
    var style = base;
    final rStyle = Ox.attr(Ox.child(rPr, 'rStyle'), 'val');
    if (rStyle != null) {
      for (final e in _chain(rStyle, 'rPr')) {
        style = _applyRPr(style, e);
      }
    }
    final hidden = [false];
    style = _applyRPr(style, rPr, hidden);
    final rawRPr = rPr?.toXmlString();
    final prefix = r.name.prefix;
    final rTag = prefix == null || prefix.isEmpty ? 'r' : '$prefix:r';

    String objectRaw(XmlElement child) =>
        '<$rTag>${rawRPr ?? ''}${child.toXmlString()}</$rTag>';

    void addText(String text) {
      if (text.isEmpty || hidden[0]) return;
      if (_inFieldInstruction) return;
      sink.add(
        DocText(
          text,
          style,
          link: _fieldLink ?? link,
          raw: rawRPr,
          field: _fieldCode,
        ),
      );
    }

    for (final c in Ox.elements(r)) {
      switch (c.name.local) {
        case 't':
          addText(c.innerText);
        case 'tab':
        case 'ptab':
          addText('\t');
        case 'br':
          final type = Ox.attr(c, 'type');
          if (type == 'page') {
            if (!_inFieldInstruction) sink.pageBreak();
          } else if (type != 'column') {
            addText('\n');
          }
        case 'cr':
          addText('\n');
        case 'noBreakHyphen':
          addText('\u2011');
        case 'sym':
          final ch = int.tryParse(Ox.attr(c, 'char') ?? '', radix: 16);
          if (ch != null) addText(mapSymbolChar(ch, Ox.attr(c, 'font')));
        case 'fldChar':
          final type = Ox.attr(c, 'fldCharType');
          if (type == 'begin') {
            _fields.add(_Field());
          } else if (type == 'separate') {
            if (_fields.isNotEmpty) {
              final f = _fields.last;
              f.separated = true;
              _interpretField(f, f.instr.toString());
            }
          } else if (type == 'end') {
            if (_fields.isNotEmpty) _fields.removeLast();
          }
        case 'instrText':
          if (_fields.isNotEmpty && !_fields.last.separated) {
            _fields.last.instr.write(c.innerText);
          }
        case 'drawing':
          if (_inFieldInstruction) break;
          _parseDrawing(c, ctx, style, sink, frames, objectRaw(c));
        case 'pict':
        case 'object':
          if (_inFieldInstruction) break;
          _parseVml(c, ctx, style, sink, frames, objectRaw(c));
        case 'AlternateContent':
          if (_inFieldInstruction) break;
          _parseAlternate(c, ctx, style, sink, frames, objectRaw(c));
        case 'footnoteReference':
        case 'endnoteReference':
          final foot = c.name.local == 'footnoteReference';
          final n = foot ? ++_footnoteNo : ++_endnoteNo;
          sink.add(
            DocObject(
              kind: foot ? 'Footnote' : 'Endnote',
              displayText: foot ? '$n' : _romanLower(n),
              raw: objectRaw(c),
              style: style.copyWith(vertAlign: DocVertAlign.superscript),
            ),
          );
      }
    }
  }

  static String _romanLower(int n) => formatListNumber(n, 'lowerRoman');

  void _parseAlternate(
    XmlElement ac,
    _PartCtx ctx,
    DocRunStyle style,
    _InlineSink sink,
    List<DocBlock> frames,
    String raw,
  ) {
    XmlElement? chosen;
    for (final ch in Ox.children(ac, 'Choice')) {
      if (Ox.firstDescendant(ch, 'drawing') != null) {
        chosen = ch;
        break;
      }
    }
    chosen ??= Ox.child(ac, 'Fallback') ?? Ox.child(ac, 'Choice');
    if (chosen == null) return;
    final drawing = Ox.child(chosen, 'drawing');
    if (drawing != null) {
      _parseDrawing(drawing, ctx, style, sink, frames, raw);
      return;
    }
    final pict = Ox.child(chosen, 'pict') ?? Ox.child(chosen, 'object');
    if (pict != null) _parseVml(pict, ctx, style, sink, frames, raw);
  }

  void _parseDrawing(
    XmlElement d,
    _PartCtx ctx,
    DocRunStyle style,
    _InlineSink sink,
    List<DocBlock> frames,
    String raw,
  ) {
    final holder = Ox.child(d, 'inline') ?? Ox.child(d, 'anchor');
    if (holder == null) return;
    final ext = Ox.child(holder, 'extent');
    final w = Units.emu(Ox.doubleAttr(ext, 'cx') ?? 0);
    final h = Units.emu(Ox.doubleAttr(ext, 'cy') ?? 0);
    final descr = Ox.attr(Ox.child(holder, 'docPr'), 'descr');
    final gd = Ox.path(holder, ['graphic', 'graphicData']);
    final uri = Ox.attr(gd, 'uri') ?? '';

    if (uri.endsWith('/picture')) {
      final id = _imageFromBlip(Ox.firstDescendant(gd, 'blip'), ctx);
      if (id != null) {
        final size = _sizeOr(id, w, h);
        sink.add(
          DocImage(
            imageId: id,
            width: size.$1,
            height: size.$2,
            raw: raw,
            description: descr,
            float: holder.name.local == 'anchor'
                ? _anchorFloat(holder, Ox.firstDescendant(gd, 'blip'))
                : null,
          ),
        );
        return;
      }
    }
    if (uri.endsWith('/chart') || uri.contains('chart')) {
      sink.add(
        DocObject(kind: 'Chart', displayText: '', raw: raw, style: style),
      );
      frames.add(
        DocFrame(
          blocks: [
            DocParagraph(
              inlines: [DocText('Chart', style.copyWith(italic: true))],
            ),
          ],
          label: 'Chart',
        ),
      );
      return;
    }
    if (uri.contains('diagram')) {
      sink.add(
        DocObject(kind: 'SmartArt', displayText: '', raw: raw, style: style),
      );
      return;
    }

    // Shapes, groups, canvases: collect pictures and text boxes.
    final content = <DocBlock>[];
    _collectShapeContent(gd, ctx, content);
    sink.add(
      DocObject(
        kind: content.isEmpty ? 'Shape' : 'Text box',
        displayText: '',
        raw: raw,
        style: style,
        content: content,
      ),
    );
    if (content.isNotEmpty) frames.add(DocFrame(blocks: content));
  }

  void _collectShapeContent(XmlElement? e, _PartCtx ctx, List<DocBlock> out) {
    if (e == null) return;
    for (final c in Ox.elements(e)) {
      final local = c.name.local;
      if (local == 'txbxContent') {
        final saved = List.of(_fields);
        _fields.clear();
        out.addAll(_parseBlocks(c, ctx, null));
        _fields
          ..clear()
          ..addAll(saved);
      } else if (local == 'pic') {
        final id = _imageFromBlip(Ox.firstDescendant(c, 'blip'), ctx);
        final ext = Ox.firstDescendant(c, 'ext');
        if (id != null) {
          out.add(
            DocParagraph(
              inlines: [
                DocImage(
                  imageId: id,
                  width: Units.emu(Ox.doubleAttr(ext, 'cx') ?? 0),
                  height: Units.emu(Ox.doubleAttr(ext, 'cy') ?? 0),
                ),
              ],
            ),
          );
        }
      } else {
        _collectShapeContent(c, ctx, out);
      }
    }
  }

  void _parseVml(
    XmlElement pict,
    _PartCtx ctx,
    DocRunStyle style,
    _InlineSink sink,
    List<DocBlock> frames,
    String raw,
  ) {
    final imageData = Ox.firstDescendant(pict, 'imagedata');
    final shape =
        Ox.firstDescendant(pict, 'shape') ??
        Ox.firstDescendant(pict, 'rect') ??
        Ox.firstDescendant(pict, 'roundrect');
    double w = 0, h = 0;
    final css = <String, String>{};
    for (final part in (Ox.attr(shape, 'style') ?? '').split(';')) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      css[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
    w = Units.length(css['width']) ?? 0;
    h = Units.length(css['height']) ?? 0;
    if (imageData != null) {
      final rid = Ox.attrQ(imageData, 'r:id') ?? Ox.attr(imageData, 'id');
      final id = _imageFromRel(rid, ctx);
      if (id != null) {
        final size = _sizeOr(id, w, h);
        sink.add(
          DocImage(
            imageId: id,
            width: size.$1,
            height: size.$2,
            raw: raw,
            float: _vmlFloat(css, Ox.firstDescendant(pict, 'wrap'), imageData),
          ),
        );
        return;
      }
    }
    final content = <DocBlock>[];
    final txbx = Ox.firstDescendant(pict, 'txbxContent');
    if (txbx != null) {
      final saved = List.of(_fields);
      _fields.clear();
      content.addAll(_parseBlocks(txbx, ctx, null));
      _fields
        ..clear()
        ..addAll(saved);
    }
    sink.add(
      DocObject(
        kind: content.isEmpty ? 'Object' : 'Text box',
        displayText: '',
        raw: raw,
        style: style,
        content: content,
      ),
    );
    if (content.isNotEmpty) frames.add(DocFrame(blocks: content));
  }

  /// Float placement for a `wp:anchor` that doesn't wrap text (pictures
  /// that wrap are kept in the flow, which never hides text).
  DocFloat? _anchorFloat(XmlElement anchor, XmlElement? blip) {
    if (Ox.child(anchor, 'wrapNone') == null) return null;
    final behind = ['1', 'true', 'on'].contains(Ox.attr(anchor, 'behindDoc'));
    final ph = Ox.child(anchor, 'positionH');
    final pv = Ox.child(anchor, 'positionV');
    double? off(XmlElement? e) {
      final t = Ox.child(e, 'posOffset');
      return t == null
          ? null
          : Units.emu(double.tryParse(t.innerText.trim()) ?? 0);
    }

    var opacity = 1.0;
    final alpha = Ox.intAttr(Ox.firstDescendant(blip, 'alphaModFix'), 'amt');
    if (alpha != null) opacity = (alpha / 100000).clamp(0.05, 1.0);
    final lum = Ox.firstDescendant(blip, 'lum');
    if ((Ox.intAttr(lum, 'bright') ?? 0) > 0) opacity = opacity.clamp(0, 0.4);
    if (['1', 'true'].contains(Ox.attr(anchor, 'simplePos'))) {
      final sp = Ox.child(anchor, 'simplePos');
      return DocFloat(
        hRelative: 'page',
        hOffset: Units.emu(Ox.doubleAttr(sp, 'x') ?? 0),
        vRelative: 'page',
        vOffset: Units.emu(Ox.doubleAttr(sp, 'y') ?? 0),
        behindText: behind,
        opacity: opacity,
      );
    }
    return DocFloat(
      hRelative: Ox.attr(ph, 'relativeFrom') ?? 'column',
      hAlign: Ox.child(ph, 'align')?.innerText.trim(),
      hOffset: off(ph) ?? 0,
      vRelative: Ox.attr(pv, 'relativeFrom') ?? 'paragraph',
      vAlign: Ox.child(pv, 'align')?.innerText.trim(),
      vOffset: off(pv) ?? 0,
      behindText: behind,
      opacity: opacity,
    );
  }

  /// Float placement for an absolutely positioned VML picture (classic
  /// watermarks and floating pictures in older documents).
  DocFloat? _vmlFloat(
    Map<String, String> css,
    XmlElement? wrap,
    XmlElement? imageData,
  ) {
    if (css['position'] != 'absolute') return null;
    final wrapType = Ox.attr(wrap, 'type');
    if (wrapType != null && wrapType != 'none') return null;
    String rel(String? v, {required bool horizontal}) {
      switch (v) {
        case 'page':
          return 'page';
        case 'margin':
          return 'margin';
        case 'char':
          return 'character';
        case 'line':
          return 'line';
        case 'left-margin-area':
          return 'leftMargin';
        case 'right-margin-area':
          return 'rightMargin';
        case 'top-margin-area':
          return 'topMargin';
        case 'bottom-margin-area':
          return 'bottomMargin';
        default:
          return horizontal ? 'column' : 'paragraph';
      }
    }

    String? align(String? v) => v == null || v == 'absolute' ? null : v;
    final gainText = Ox.attr(imageData, 'gain');
    var opacity = 1.0;
    if (gainText != null) {
      final g = double.tryParse(gainText.replaceAll('f', ''));
      if (g != null) {
        final gain = gainText.endsWith('f') ? g / 65536 : g;
        if (gain < 0.9) opacity = 0.35;
      }
    }
    final z = int.tryParse(css['z-index'] ?? '') ?? 0;
    return DocFloat(
      hRelative: rel(css['mso-position-horizontal-relative'], horizontal: true),
      hAlign: align(css['mso-position-horizontal']),
      hOffset: Units.length(css['margin-left'] ?? css['left']) ?? 0,
      vRelative: rel(css['mso-position-vertical-relative'], horizontal: false),
      vAlign: align(css['mso-position-vertical']),
      vOffset: Units.length(css['margin-top'] ?? css['top']) ?? 0,
      behindText: z < 0,
      opacity: opacity,
    );
  }

  /// Explicit size, or the image's pixel size (at 96 dpi) when missing.
  (double, double) _sizeOr(String id, double w, double h) {
    if (w > 0 && h > 0) return (w, h);
    final px = imagePixelSize(_images[id]!.bytes);
    if (px == null) return (w > 0 ? w : 144, h > 0 ? h : 108);
    final pw = px.$1 * 0.75, ph = px.$2 * 0.75;
    if (w > 0) return (w, w * ph / pw);
    if (h > 0) return (h * pw / ph, h);
    return (pw, ph);
  }

  String? _imageFromBlip(XmlElement? blip, _PartCtx ctx) {
    if (blip == null) return null;
    return _imageFromRel(Ox.attrQ(blip, 'r:embed'), ctx);
  }

  String? _imageFromRel(String? rid, _PartCtx ctx) {
    if (rid == null) return null;
    final rel = ctx.rels[rid];
    if (rel == null || rel.external) return null;
    final path = OfficePackage.resolve(ctx.partName, rel.target);
    if (_images.containsKey(path)) return path;
    final bytes = pkg.bytes(path);
    if (bytes == null) return null;
    _images[path] = loadImageData(bytes, path);
    return path;
  }

  void _mergeRuns(List<DocInline> inlines) {
    for (var i = inlines.length - 1; i > 0; i--) {
      final a = inlines[i - 1];
      final b = inlines[i];
      if (a is DocText &&
          b is DocText &&
          a.style == b.style &&
          a.link == b.link &&
          a.raw == b.raw &&
          a.field == b.field) {
        a.text += b.text;
        inlines.removeAt(i);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Tables

  DocTable? _parseTable(XmlElement tbl, _PartCtx ctx) {
    final tblPr = Ox.child(tbl, 'tblPr');
    final styleId =
        Ox.attr(Ox.child(tblPr, 'tblStyle'), 'val') ?? _defaultTableStyle;

    // Table style chain (pPr/rPr apply to content).
    final pPrs = <XmlElement>[];
    final rPrs = <XmlElement>[];
    final tblPrs = <XmlElement>[];
    final stylePr = <String, XmlElement>{};
    {
      final seen = <String>{};
      final stack = <_Style>[];
      var cur = styleId == null ? null : _styles[styleId];
      while (cur != null && seen.add(cur.id)) {
        stack.add(cur);
        cur = cur.basedOn == null ? null : _styles[cur.basedOn];
      }
      for (final s in stack.reversed) {
        if (s.pPr != null) pPrs.add(s.pPr!);
        if (s.rPr != null) rPrs.add(s.rPr!);
        if (s.tblPr != null) tblPrs.add(s.tblPr!);
        for (final c in s.tblStylePr) {
          final type = Ox.attr(c, 'type');
          if (type != null) stylePr[type] = c;
        }
      }
    }
    if (tblPr != null) tblPrs.add(tblPr);
    final tctx = _TableCtx(styleId, pPrs, rPrs);

    var borders = false;
    var borderColor = 0xFF000000;
    var padding = 5.4;
    var align = DocAlign.left;
    var indent = 0.0;
    double? width;
    for (final p in tblPrs) {
      final b = Ox.child(p, 'tblBorders');
      if (b != null) {
        var any = false;
        for (final side in Ox.elements(b)) {
          final v = Ox.attr(side, 'val') ?? 'none';
          if (v != 'none' && v != 'nil') {
            any = true;
            borderColor = Ox.hexColor(Ox.attr(side, 'color')) ?? borderColor;
          }
        }
        borders = any;
      }
      final mar = Ox.child(p, 'tblCellMar');
      final l = Ox.doubleAttr(
        Ox.child(mar, 'left') ?? Ox.child(mar, 'start'),
        'w',
      );
      if (l != null) padding = Units.twips(l);
      final jc = Ox.attr(Ox.child(p, 'jc'), 'val');
      if (jc != null) align = _align(jc);
      final ind = Ox.doubleAttr(Ox.child(p, 'tblInd'), 'w');
      if (ind != null) indent = Units.twips(ind);
      final tw = Ox.child(p, 'tblW');
      if (tw != null && Ox.attr(tw, 'type') == 'dxa') {
        final v = Ox.doubleAttr(tw, 'w');
        if (v != null && v > 0) width = Units.twips(v);
      }
    }

    final grid = <double>[
      for (final g in Ox.children(Ox.child(tbl, 'tblGrid'), 'gridCol'))
        Units.twips(Ox.doubleAttr(g, 'w') ?? 0),
    ];

    final look = Ox.child(tblPr, 'tblLook');
    final firstRowLook =
        Ox.attr(look, 'firstRow') == '1' ||
        ((int.tryParse(Ox.attr(look, 'val') ?? '', radix: 16) ?? 0) & 0x20) !=
            0;
    final firstRowStyle = firstRowLook ? stylePr['firstRow'] : null;

    final rows = <DocTableRow>[];
    final vMerge =
        <List<String?>>[]; // per row, per grid col: restart/continue/null
    for (final tr in _rowsOf(tbl)) {
      final trPr = Ox.child(tr, 'trPr');
      final hEl = Ox.child(trPr, 'trHeight');
      final hVal = Ox.doubleAttr(hEl, 'val');
      final row = DocTableRow(
        height: hVal == null ? null : Units.twips(hVal),
        exactHeight: Ox.attr(hEl, 'hRule') == 'exact',
        header: Ox.toggle(Ox.child(trPr, 'tblHeader')) ?? false,
      );
      final merges = <String?>[];
      final before = Ox.intAttr(Ox.child(trPr, 'gridBefore'), 'val') ?? 0;
      if (before > 0) {
        row.cells.add(DocTableCell(colSpan: before, covered: true));
        merges.addAll(List.filled(before, null));
      }
      final isFirst = rows.isEmpty;
      for (final tc in _cellsOf(tr)) {
        final tcPr = Ox.child(tc, 'tcPr');
        final span = (Ox.intAttr(Ox.child(tcPr, 'gridSpan'), 'val') ?? 1).clamp(
          1,
          64,
        );
        final vm = Ox.child(tcPr, 'vMerge');
        String? vmState;
        if (vm != null) {
          vmState = Ox.attr(vm, 'val') == 'restart' ? 'restart' : 'continue';
        }
        var shading = Ox.hexColor(Ox.attr(Ox.child(tcPr, 'shd'), 'fill'));
        final va = Ox.attr(Ox.child(tcPr, 'vAlign'), 'val');
        var cellCtx = tctx;
        if (isFirst && firstRowStyle != null) {
          shading ??= Ox.hexColor(
            Ox.attr(Ox.path(firstRowStyle, ['tcPr', 'shd']), 'fill'),
          );
          final frp = Ox.child(firstRowStyle, 'rPr');
          final fpp = Ox.child(firstRowStyle, 'pPr');
          cellCtx = _TableCtx(
            '${styleId}_firstRow',
            [...pPrs, ?fpp],
            [...rPrs, ?frp],
          );
        }
        final cell = DocTableCell(
          blocks: _parseBlocks(tc, ctx, cellCtx),
          colSpan: span,
          shading: shading == 0xFFFFFFFF ? null : shading,
          vAlign: va == 'center'
              ? DocCellVAlign.center
              : va == 'bottom'
              ? DocCellVAlign.bottom
              : DocCellVAlign.top,
        );
        row.cells.add(cell);
        merges.add(vmState);
        for (var i = 1; i < span; i++) {
          merges.add(vmState == null ? null : '_span');
        }
      }
      rows.add(row);
      vMerge.add(merges);
    }

    // Resolve vertical merges into rowSpan / covered.
    for (var r = 0; r < rows.length; r++) {
      var col = 0;
      for (final cell in rows[r].cells) {
        final state = col < vMerge[r].length ? vMerge[r][col] : null;
        if (state == 'continue') {
          cell.covered = true;
        } else if (state == 'restart') {
          var span = 1;
          for (var rr = r + 1; rr < rows.length; rr++) {
            final s = col < vMerge[rr].length ? vMerge[rr][col] : null;
            if (s == 'continue') {
              span++;
            } else {
              break;
            }
          }
          cell.rowSpan = span;
        }
        col += cell.colSpan;
      }
    }
    if (rows.isEmpty) return null;

    return DocTable(
      rows: rows,
      columnWidths: grid.every((w) => w > 0) ? grid : [],
      width: width,
      borders: borders,
      borderColor: borderColor,
      align: align,
      indent: indent,
      cellPadding: padding,
      raw: tbl.toXmlString(),
    );
  }

  Iterable<XmlElement> _rowsOf(XmlElement tbl) sync* {
    for (final e in Ox.elements(tbl)) {
      switch (e.name.local) {
        case 'tr':
          yield e;
        case 'sdt':
          final c = Ox.child(e, 'sdtContent');
          if (c != null) yield* _rowsOf(c);
        case 'customXml':
          yield* _rowsOf(e);
      }
    }
  }

  Iterable<XmlElement> _cellsOf(XmlElement tr) sync* {
    for (final e in Ox.elements(tr)) {
      switch (e.name.local) {
        case 'tc':
          yield e;
        case 'sdt':
          final c = Ox.child(e, 'sdtContent');
          if (c != null) yield* _cellsOf(c);
        case 'customXml':
          yield* _cellsOf(e);
      }
    }
  }
}

/// Receives inline content; supports page breaks that split paragraphs.
class _InlineSink {
  _InlineSink(this.target, this._onPageBreak);

  final List<DocInline> Function() target;
  final void Function() _onPageBreak;

  void add(DocInline i) => target().add(i);
  void pageBreak() => _onPageBreak();
}

/// Wraps image bytes, converting TIFF to PNG so Flutter can show it.
DocImageData loadImageData(Uint8List bytes, String path) {
  var ext = sniffImageExtension(bytes);
  if (ext == null) {
    final dot = path.lastIndexOf('.');
    ext = dot < 0 ? 'bin' : path.substring(dot + 1).toLowerCase();
  }
  if (ext == 'tiff' || ext == 'tif') {
    try {
      final decoded = img.decodeTiff(bytes);
      if (decoded != null) {
        return DocImageData(
          Uint8List.fromList(img.encodePng(decoded)),
          'png',
          sourcePath: path,
        );
      }
    } catch (_) {}
  }
  return DocImageData(bytes, ext == 'jpg' ? 'jpeg' : ext, sourcePath: path);
}

/// Maps a Symbol/Wingdings private-use character to a Unicode look-alike.
String mapSymbolChar(int code, String? font) {
  final c = code >= 0xF000 ? code - 0xF000 : code;
  final f = (font ?? '').toLowerCase();
  if (f.contains('wingdings')) {
    const m = {
      0xA7: '▪',
      0xA8: '◻',
      0xD8: '➢',
      0xFC: '✓',
      0x76: '❖',
      0x6C: '●',
      0x6E: '■',
      0x71: '❑',
      0x75: '◆',
      0xA1: '○',
      0x9F: '•',
      0xE0: '➔',
      0xE8: '➔',
      0xF0: '⇨',
      0x77: '⬥',
      0xFB: '✗',
      0xFE: '☑',
      0x6F: '☐',
      0x4A: '☺',
      0x4C: '☹',
      0xAB: '★',
      0x9E: '·',
      0x3F: '✍',
      0x46: '☞',
      0xF8: '✘',
      0xFD: '☒',
    };
    return m[c] ?? '•';
  }
  if (f.contains('symbol') || code >= 0xF000) {
    const greek = 'ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ';
    if (c >= 0x41 && c <= 0x5A) return greek[c - 0x41];
    const lower = 'αβχδεφγηιϕκλμνοπθρστυϖωξψζ';
    if (c >= 0x61 && c <= 0x7A) return lower[c - 0x61];
    const m = {
      0xB7: '•',
      0xB0: '°',
      0xB1: '±',
      0xA3: '≤',
      0xB3: '≥',
      0xB9: '≠',
      0xBB: '≈',
      0xA5: '∞',
      0xD6: '√',
      0xE5: '∑',
      0xD5: '∏',
      0xF2: '∫',
      0xAE: '→',
      0xAC: '←',
      0xAD: '↑',
      0xAF: '↓',
      0xDE: '⇒',
      0xDC: '⇐',
      0xDB: '⇔',
      0xA2: '′',
      0xB2: '″',
      0xB4: '×',
      0xB8: '÷',
      0xD7: '⋅',
      0x2D: '−',
      0xE3: '©',
      0xE2: '®',
      0xE4: '™',
      0xA7: '♣',
      0xA8: '♦',
      0xA9: '♥',
      0xAA: '♠',
      0x6F: 'ο',
      0xC6: '∅',
      0xCE: '∈',
      0xCF: '∉',
      0xC7: '∩',
      0xC8: '∪',
      0xD1: '∇',
      0xB6: '∂',
      0x22: '∀',
      0x24: '∃',
    };
    final mapped = m[c];
    if (mapped != null) return mapped;
    if (code >= 0xF000) {
      return c >= 0x20 && c < 0x7F ? String.fromCharCode(c) : '•';
    }
  }
  return String.fromCharCode(code);
}
