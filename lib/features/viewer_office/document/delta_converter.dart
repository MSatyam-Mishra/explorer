import 'doc_model.dart';

/// Converts between [DocModel] and Quill Delta JSON (`List<Map>` ops).
///
/// Tables, images, objects and breaks become embeds whose payload is an id
/// into [DeltaSideTable], so they survive editing untouched. Paragraph and
/// run templates (spacing, raw DOCX markup, …) ride along as hidden
/// attributes (`office-p`, `office-r`) that Quill keeps but doesn't render.
abstract final class OfficeEmbeds {
  static const table = 'office-table';
  static const image = 'office-image';
  static const object = 'office-object';
  static const pageBreak = 'office-pagebreak';
  static const section = 'office-section';

  static const paraAttr = 'office-p';
  static const runAttr = 'office-r';
}

class DeltaSideTable {
  final Map<String, DocTable> tables = {};
  final Map<String, DocImage> images = {};
  final Map<String, DocObject> objects = {};
  final Map<String, DocSectionBreak> sections = {};
  final List<DocParagraph> paragraphs = [];
  final List<DocText> runs = [];
  int _next = 0;

  String id(String prefix) => '$prefix${_next++}';
}

class DeltaDocument {
  DeltaDocument(this.ops, this.side);
  final List<Map<String, dynamic>> ops;
  final DeltaSideTable side;
}

String _fmtNum(double v) {
  final r = (v * 2).roundToDouble() / 2;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

int? _parseColor(Object? v) {
  if (v is! String) return null;
  var s = v.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 8) s = s.substring(2); // AARRGGBB
  if (s.length == 3) s = '${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}';
  if (s.length != 6) return null;
  final n = int.tryParse(s, radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

double? _parseSize(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    switch (v) {
      case 'small':
        return 9;
      case 'large':
        return 18;
      case 'huge':
        return 26;
    }
    return double.tryParse(v);
  }
  return null;
}

/// Inline Quill attributes of [s] relative to [base].
Map<String, dynamic> runAttributes(DocRunStyle s, DocRunStyle base,
    {String? link}) {
  final a = <String, dynamic>{};
  if (s.bold && !base.bold) a['bold'] = true;
  if (s.italic && !base.italic) a['italic'] = true;
  if (s.underline && !base.underline && link == null) a['underline'] = true;
  if (s.strike && !base.strike) a['strike'] = true;
  if (s.color != base.color) {
    a['color'] = _hex(s.color ?? 0xFF000000);
  }
  if (s.highlight != null) a['background'] = _hex(s.highlight!);
  final size = s.fontSize ?? base.fontSize;
  if (size != null && size != base.fontSize) a['size'] = _fmtNum(size);
  if (s.fontFamily != null && s.fontFamily != base.fontFamily) {
    a['font'] = s.fontFamily;
  }
  if (s.vertAlign == DocVertAlign.superscript) a['script'] = 'super';
  if (s.vertAlign == DocVertAlign.subscript) a['script'] = 'sub';
  if (link != null) a['link'] = link;
  return a;
}

DeltaDocument modelToDelta(DocModel m) {
  final side = DeltaSideTable();
  final ops = <Map<String, dynamic>>[];

  void insert(Object data, [Map<String, dynamic>? attrs]) {
    ops.add({
      'insert': data,
      if (attrs != null && attrs.isNotEmpty) 'attributes': attrs,
    });
  }

  void blockEmbed(String type, String id) {
    insert(<String, dynamic>{type: id});
    insert('\n');
  }

  for (final b in m.blocks) {
    switch (b) {
      case DocParagraph():
        _paragraphOps(b, m, side, insert);
      case DocTable():
        final id = side.id('t');
        side.tables[id] = b;
        blockEmbed(OfficeEmbeds.table, id);
      case DocPageBreak():
        blockEmbed(OfficeEmbeds.pageBreak, 'page');
      case DocSectionBreak():
        final id = side.id('s');
        side.sections[id] = b;
        blockEmbed(OfficeEmbeds.section, id);
      case DocFrame():
        break; // Derived from preserved objects.
    }
  }
  if (ops.isEmpty) insert('\n');
  return DeltaDocument(ops, side);
}

void _paragraphOps(DocParagraph p, DocModel m, DeltaSideTable side,
    void Function(Object, [Map<String, dynamic>?]) insert) {
  final base = m.editorBaseFor(p.headingLevel);
  final pIndex = side.paragraphs.length;
  side.paragraphs.add(p);
  for (final i in p.inlines) {
    switch (i) {
      case DocText():
        if (i.text.isEmpty) continue;
        final rIndex = side.runs.length;
        side.runs.add(i);
        final attrs = runAttributes(i.style, base, link: i.link)
          ..[OfficeEmbeds.runAttr] = rIndex;
        insert(i.text.replaceAll('\n', '\u2028'), attrs);
      case DocImage():
        final id = side.id('i');
        side.images[id] = i;
        insert(<String, dynamic>{OfficeEmbeds.image: id});
      case DocObject():
        final id = side.id('o');
        side.objects[id] = i;
        insert(<String, dynamic>{OfficeEmbeds.object: id});
    }
  }
  final line = <String, dynamic>{OfficeEmbeds.paraAttr: pIndex};
  if (p.headingLevel != null) line['header'] = p.headingLevel!.clamp(1, 6);
  switch (p.align) {
    case DocAlign.center:
      line['align'] = 'center';
    case DocAlign.right:
      line['align'] = 'right';
    case DocAlign.justify:
      line['align'] = 'justify';
    case DocAlign.left:
      break;
  }
  if (p.list != null) {
    line['list'] = p.list!.ordered ? 'ordered' : 'bullet';
    if (p.list!.level > 0) line['indent'] = p.list!.level.clamp(1, 8);
  } else {
    final lvl = (p.indentLeft / 36).round();
    if (lvl > 0) line['indent'] = lvl.clamp(1, 8);
  }
  if (p.rtl) line['direction'] = 'rtl';
  insert('\n', line);
}

/// Rebuilds a model from edited Delta ops.
DocModel deltaToModel(
    List<Map<String, dynamic>> ops, DocModel original, DeltaSideTable side) {
  final blocks = <DocBlock>[];
  var pending = <Object>[]; // DocInline or DocBlock (block embeds)

  void finishLine(Map<String, dynamic>? attrs) {
    final a = attrs ?? const <String, dynamic>{};
    var cur = <DocInline>[];
    final order = <Object>[];
    for (final item in pending) {
      if (item is DocBlock) {
        if (cur.isNotEmpty) order.add(cur);
        order.add(item);
        cur = <DocInline>[];
      } else {
        cur.add(item as DocInline);
      }
    }
    if (cur.isNotEmpty || order.isEmpty) order.add(cur);
    for (final o in order) {
      if (o is DocBlock) {
        blocks.add(o);
      } else {
        blocks.add(_paragraphFrom(o as List<DocInline>, a, original, side));
      }
    }
    pending = <Object>[];
  }

  for (final op in ops) {
    final data = op['insert'];
    final attrs = (op['attributes'] as Map?)?.cast<String, dynamic>();
    if (data is String) {
      final parts = data.split('\n');
      for (var i = 0; i < parts.length; i++) {
        final text = parts[i];
        if (text.isNotEmpty) {
          pending.add(_runFrom(text, attrs, original, side));
        }
        if (i < parts.length - 1) finishLine(attrs);
      }
    } else if (data is Map) {
      final key = data.keys.isEmpty ? '' : data.keys.first.toString();
      final value = data.values.isEmpty ? null : data.values.first;
      switch (key) {
        case OfficeEmbeds.table:
          final t = side.tables[value];
          if (t != null) pending.add(t);
        case OfficeEmbeds.image:
          final img = side.images[value];
          if (img != null) pending.add(img);
        case OfficeEmbeds.object:
          final o = side.objects[value];
          if (o != null) pending.add(o);
        case OfficeEmbeds.pageBreak:
          pending.add(DocPageBreak());
        case OfficeEmbeds.section:
          final s = side.sections[value];
          if (s != null) pending.add(s);
      }
    }
  }
  if (pending.isNotEmpty) finishLine(null);
  // Quill always ends with an empty line; drop it if the source didn't.
  if (blocks.length > 1) {
    final last = blocks.last;
    if (last is DocParagraph && last.isEmpty && last.list == null) {
      final origLast = original.blocks.isEmpty ? null : original.blocks.last;
      if (!(origLast is DocParagraph && origLast.isEmpty)) blocks.removeLast();
    }
  }
  renumberLists(blocks);
  return DocModel(
    format: original.format,
    blocks: blocks,
    images: original.images,
    page: original.page,
    baseStyle: original.baseStyle,
    headingStyles: original.headingStyles,
    headingSpacing: original.headingSpacing,
    header: original.header,
    footer: original.footer,
    warnings: original.warnings,
    docx: original.docx,
    title: original.title,
  );
}

int? _header(Map<String, dynamic>? a) {
  final h = a?['header'];
  if (h is int && h >= 1 && h <= 6) return h;
  if (h is String) return int.tryParse(h);
  return null;
}

DocText _runFrom(String text, Map<String, dynamic>? a, DocModel m,
    DeltaSideTable side) {
  final idx = a?[OfficeEmbeds.runAttr];
  final template =
      idx is int && idx >= 0 && idx < side.runs.length ? side.runs[idx] : null;
  // Run attrs are relative to the editor base of the line, which we don't
  // know yet; store raw attrs and resolve when the line finishes.
  final run = DocText(
    text.replaceAll('\u2028', '\n'),
    template?.style ?? m.baseStyle,
    link: a?['link'] as String?,
    raw: template?.raw,
    field: template?.field,
    origin: template == null ? null : (template.origin ?? template.style),
  );
  _pendingAttrs[run] = a ?? const {};
  return run;
}

final Expando<Map<String, dynamic>> _pendingAttrs = Expando();

DocRunStyle _resolveStyle(Map<String, dynamic> a, DocRunStyle base, DocText? run) {
  final template = run?.style;
  final script = a['script'];
  return DocRunStyle(
    bold: a['bold'] == true || base.bold,
    italic: a['italic'] == true || base.italic,
    underline: a['underline'] == true ||
        (base.underline) ||
        (a['link'] != null && (template?.underline ?? true)),
    strike: a['strike'] == true || base.strike,
    allCaps: template?.allCaps ?? false,
    smallCaps: template?.smallCaps ?? false,
    color: a.containsKey('color')
        ? _parseColor(a['color'])
        : (a['link'] != null ? template?.color ?? base.color : base.color),
    highlight: _parseColor(a['background']),
    fontSize: _parseSize(a['size']) ?? base.fontSize,
    fontFamily: (a['font'] as String?) ?? base.fontFamily,
    vertAlign: script == 'super'
        ? DocVertAlign.superscript
        : script == 'sub'
            ? DocVertAlign.subscript
            : DocVertAlign.baseline,
  );
}

DocParagraph _paragraphFrom(List<DocInline> inlines, Map<String, dynamic> a,
    DocModel m, DeltaSideTable side) {
  final idx = a[OfficeEmbeds.paraAttr];
  final t = idx is int && idx >= 0 && idx < side.paragraphs.length
      ? side.paragraphs[idx]
      : null;
  final header = _header(a);
  final base = m.editorBaseFor(header);
  for (final i in inlines) {
    if (i is DocText) {
      final attrs = _pendingAttrs[i] ?? const <String, dynamic>{};
      i.style = _resolveStyle(attrs, base, i);
      _pendingAttrs[i] = null;
    }
  }

  final listType = a['list'];
  final indentAttr = a['indent'];
  final indent = indentAttr is int
      ? indentAttr
      : (indentAttr is String ? int.tryParse(indentAttr) ?? 0 : 0);
  DocListInfo? list;
  if (listType == 'bullet' || listType == 'ordered') {
    final ordered = listType == 'ordered';
    final tl = t?.list;
    final same = tl != null && tl.ordered == ordered;
    list = DocListInfo(
      ordered: ordered,
      level: indent,
      numId: same ? tl.numId : null,
      format: same && tl.level == indent
          ? tl.format
          : (ordered ? defaultOrderedFormat(indent) : 'bullet'),
      labelStyle: tl?.labelStyle,
    );
  }

  final align = switch (a['align']) {
    'center' => DocAlign.center,
    'right' => DocAlign.right,
    'justify' => DocAlign.justify,
    _ => DocAlign.left,
  };

  double indentLeft;
  double firstLine;
  if (list != null) {
    final tl = t?.list;
    if (tl != null && tl.level == list.level && t!.indentLeft > 0) {
      indentLeft = t.indentLeft;
      firstLine = t.firstLine < 0 ? t.firstLine : -18;
    } else {
      indentLeft = 36.0 * (list.level + 1);
      firstLine = -18;
    }
  } else if (t != null && t.list == null && (t.indentLeft / 36).round() == indent) {
    indentLeft = t.indentLeft;
    firstLine = t.firstLine;
  } else {
    indentLeft = 36.0 * indent;
    firstLine = t?.list == null ? (t?.firstLine ?? 0) : 0;
  }

  String? styleId = t?.styleId;
  final docx = m.docx;
  if (header != null) {
    if (t?.headingLevel != header) {
      styleId = docx?.headingStyleIds[header] ?? 'Heading$header';
    }
  } else if (t?.headingLevel != null ||
      (styleId != null && (docx?.headingStyleSet.contains(styleId) ?? false))) {
    styleId = docx?.normalStyleId;
  }

  final headingChanged = header != t?.headingLevel;
  return DocParagraph(
    inlines: inlines,
    styleId: styleId,
    headingLevel: header,
    align: align,
    indentLeft: indentLeft,
    indentRight: t?.indentRight ?? 0,
    firstLine: firstLine,
    spaceBefore: headingChanged
        ? (header == null ? 0 : (m.headingSpacing[header] ?? 12))
        : (t?.spaceBefore ?? 0),
    spaceAfter: headingChanged && header != null ? 4 : (t?.spaceAfter ?? 6),
    lineSpacing: t?.lineSpacing ?? 1.0,
    lineExact: t?.lineExact,
    list: list,
    shading: t?.shading,
    borderTop: t?.borderTop,
    borderBottom: t?.borderBottom,
    keepNext: header != null || (t?.keepNext ?? false),
    pageBreakBefore: t?.pageBreakBefore ?? false,
    rtl: a['direction'] == 'rtl',
    contextualSpacing: t?.contextualSpacing ?? false,
    markStyle: headingChanged ? base : (t?.markStyle ?? base),
    raw: t?.raw,
  )..origin = t == null ? null : (t.origin ?? t);
}
