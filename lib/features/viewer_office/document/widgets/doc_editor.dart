import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../delta_converter.dart';
import '../doc_model.dart';
import '../layout/doc_layout.dart';
import '../layout/doc_render_context.dart';

/// One editing session: the Quill controller plus everything needed to turn
/// its contents back into a [DocModel].
class DocEditorSession {
  DocEditorSession(this.model) {
    final d = modelToDelta(model);
    side = d.side;
    controller = QuillController(
      document: Document.fromJson(d.ops),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _sub = controller.document.changes.listen((_) {
      changed = true;
      revision++;
      if (!dirty) {
        dirty = true;
        onDirty?.call();
      }
    });
  }

  final DocModel model;
  late final DeltaSideTable side;
  late final QuillController controller;
  late final StreamSubscription<DocChange> _sub;
  bool dirty = false;

  /// Counts edits; a save clears [dirty] only if nothing changed since its
  /// [snapshot] was taken.
  int revision = 0;

  /// Whether anything was edited during the session (survives saving).
  bool changed = false;
  VoidCallback? onDirty;

  bool get hasPreservedObjects =>
      side.tables.isNotEmpty ||
      side.images.isNotEmpty ||
      side.objects.isNotEmpty;

  /// The document as currently edited.
  DocModel snapshot() {
    final ops = <Map<String, dynamic>>[];
    for (final op in controller.document.toDelta().toList()) {
      final data = op.data;
      final insert = data is Embeddable ? data.toJson() : data;
      ops.add({
        'insert': insert,
        if (op.attributes != null) 'attributes': op.attributes,
      });
    }
    return deltaToModel(ops, model, side);
  }

  void dispose() {
    _sub.cancel();
    controller.dispose();
  }
}

TextStyle _ts(DocRunStyle s) => TextStyle(
  fontSize: s.fontSize ?? 11,
  fontFamily: s.fontFamily,
  fontFamilyFallback: fontFallbackFor(s.fontFamily),
  fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
  fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
  color: s.color == null ? Colors.black : Color(s.color!),
  decoration: TextDecoration.none,
  height: 1.25,
);

DefaultStyles _editorStyles(DocModel m) {
  final base = _ts(m.baseStyle);
  DefaultTextBlockStyle block(TextStyle t, double top, double bottom) =>
      DefaultTextBlockStyle(
        t,
        HorizontalSpacing.zero,
        VerticalSpacing(top, bottom),
        VerticalSpacing.zero,
        null,
      );
  DefaultTextBlockStyle heading(int l) => block(
    _ts(m.headingStyles[l] ?? m.baseStyle),
    (m.headingSpacing[l] ?? 10).clamp(4, 24),
    4,
  );
  return DefaultStyles(
    paragraph: block(base, 0, 6),
    h1: heading(1),
    h2: heading(2),
    h3: heading(3),
    h4: heading(4),
    h5: heading(5),
    h6: heading(6),
    lists: DefaultListBlockStyle(
      base,
      HorizontalSpacing.zero,
      const VerticalSpacing(0, 4),
      VerticalSpacing.zero,
      null,
      null,
    ),
    link: const TextStyle(
      color: Color(0xFF0563C1),
      decoration: TextDecoration.underline,
    ),
    placeHolder: block(base.copyWith(color: Colors.black38), 0, 0),
  );
}

/// Read-only rendering of preserved blocks inside the editor.
class _TableEmbed extends EmbedBuilder {
  _TableEmbed(this.model, this.side, this.ctx, this.scale);
  final DocModel model;
  final DeltaSideTable side;
  final DocRenderContext ctx;
  final double scale;
  final Map<String, LaidTable> _cache = {};

  @override
  String get key => OfficeEmbeds.table;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final table = side.tables[embedContext.node.value.data];
    if (table == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth.isFinite ? c.maxWidth : 600.0;
        final inner = width / scale;
        final key = '${embedContext.node.value.data}@${inner.round()}';
        final laid = _cache[key] ??= DocLayoutEngine(
          model,
          ctx,
        ).layoutTable(table, inner);
        return Tooltip(
          message: 'Table (kept as is; not editable here)',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              width: width,
              height: laid.height * scale,
              child: FittedBox(
                fit: BoxFit.fill,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: inner,
                  height: laid.height,
                  child: laid.build(ctx),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ImageEmbed extends EmbedBuilder {
  _ImageEmbed(this.side, this.ctx, this.scale);
  final DeltaSideTable side;
  final DocRenderContext ctx;
  final double scale;

  @override
  String get key => OfficeEmbeds.image;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final img = side.images[embedContext.node.value.data];
    if (img == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        var w = (img.width <= 0 ? 144.0 : img.width) * scale;
        var h = (img.height <= 0 ? 108.0 : img.height) * scale;
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 600.0;
        if (w > maxW) {
          h = h * maxW / w;
          w = maxW;
        }
        return DocImageBox(id: img.imageId, width: w, height: h, ctx: ctx);
      },
    );
  }
}

class _ObjectEmbed extends EmbedBuilder {
  _ObjectEmbed(this.side);
  final DeltaSideTable side;

  @override
  String get key => OfficeEmbeds.object;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final o = side.objects[embedContext.node.value.data];
    if (o == null) return const SizedBox.shrink();
    final text = o.displayText ?? '';
    if (o.kind == 'Footnote' || o.kind == 'Endnote') {
      return Transform.translate(
        offset: const Offset(0, -4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 9, color: Color(0xFF0563C1)),
        ),
      );
    }
    final icon = switch (o.kind) {
      'Chart' => Icons.insert_chart_outlined,
      'Equation' => Icons.functions,
      'Text box' => Icons.text_fields,
      'SmartArt' => Icons.account_tree_outlined,
      _ => Icons.category_outlined,
    };
    final label = o.kind == 'Equation' && text.isNotEmpty ? text : o.kind;
    return Tooltip(
      message: '${o.kind} (kept as is)',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0x14000000),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0x22000000)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.black54),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakEmbed extends EmbedBuilder {
  _BreakEmbed(this.key, this.label);
  @override
  final String key;
  final String label;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Colors.black26)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ),
          const Expanded(child: Divider(color: Colors.black26)),
        ],
      ),
    );
  }
}

class _UnknownEmbed extends EmbedBuilder {
  @override
  String get key => 'unknown';

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const Icon(Icons.help_outline, size: 14, color: Colors.black38);
}

/// Toolbar + editor on a white page.
class DocEditorView extends StatefulWidget {
  const DocEditorView({
    super.key,
    required this.session,
    required this.images,
    this.topPadding = 0,
    this.onLink,
  });

  final DocEditorSession session;
  final DocImageCache images;
  final double topPadding;
  final ValueChanged<String>? onLink;

  @override
  State<DocEditorView> createState() => _DocEditorViewState();
}

class _DocEditorViewState extends State<DocEditorView> {
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  late List<EmbedBuilder> _builders;
  late DefaultStyles _styles;
  double _scale = 1.25;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(DocEditorView old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session)) _init();
  }

  void _init() {
    final s = widget.session;
    final ctx = DocRenderContext(model: s.model, images: widget.images);
    _builders = [
      _TableEmbed(s.model, s.side, ctx, _scale),
      _ImageEmbed(s.side, ctx, _scale),
      _ObjectEmbed(s.side),
      _BreakEmbed(OfficeEmbeds.pageBreak, 'Page break'),
      _BreakEmbed(OfficeEmbeds.section, 'Section break'),
    ];
    _styles = _editorStyles(s.model);
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Map<String, String> _fonts() {
    final fonts = <String>{
      if (widget.session.model.baseStyle.fontFamily != null)
        widget.session.model.baseStyle.fontFamily!,
      'Calibri',
      'Arial',
      'Times New Roman',
      'Georgia',
      'Verdana',
      'Courier New',
    };
    return {for (final f in fonts) f: f, 'Clear': 'Clear'};
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    // Document text is in points; enlarge it a little for comfortable editing.
    final scale = compact ? 1.25 : 1.4;
    if (scale != _scale) {
      _scale = scale;
      _init();
    }
    final controller = widget.session.controller;
    final scheme = Theme.of(context).colorScheme;
    final sizes = <String, String>{
      for (final s in const [
        8,
        9,
        10,
        11,
        12,
        14,
        16,
        18,
        20,
        24,
        28,
        32,
        36,
        48,
        72,
      ])
        '$s': '$s',
      'Clear': '0',
    };

    final toolbar = QuillSimpleToolbar(
      controller: controller,
      config: QuillSimpleToolbarConfig(
        multiRowsDisplay: !compact,
        showFontFamily: true,
        showFontSize: true,
        showBoldButton: true,
        showItalicButton: true,
        showUnderLineButton: true,
        showStrikeThrough: true,
        showInlineCode: false,
        showColorButton: true,
        showBackgroundColorButton: true,
        showClearFormat: true,
        showAlignmentButtons: true,
        showHeaderStyle: true,
        showListNumbers: true,
        showListBullets: true,
        showListCheck: false,
        showCodeBlock: false,
        showQuote: false,
        showIndent: true,
        showLink: true,
        showUndo: true,
        showRedo: true,
        showSearchButton: true,
        showSubscript: true,
        showSuperscript: true,
        showDividers: !compact,
        color: scheme.surfaceContainer,
        buttonOptions: QuillSimpleToolbarButtonOptions(
          fontFamily: QuillToolbarFontFamilyButtonOptions(items: _fonts()),
          fontSize: QuillToolbarFontSizeButtonOptions(items: sizes),
        ),
      ),
    );

    final page = widget.session.model.page;
    final maxW = math.max(480.0, page.width * scale + 96);
    final editor = Theme(
      data: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: scheme.primary),
        useMaterial3: true,
      ),
      child: DefaultTextStyle(
        style: _ts(widget.session.model.baseStyle),
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: QuillEditor(
            controller: controller,
            focusNode: _focus,
            scrollController: _scroll,
            config: QuillEditorConfig(
              padding: EdgeInsets.fromLTRB(
                compact ? 18 : 48,
                24,
                compact ? 18 : 48,
                120,
              ),
              placeholder: 'Start typing…',
              embedBuilders: _builders,
              unknownEmbedBuilder: _UnknownEmbed(),
              customStyles: _styles,
              onLaunchUrl: widget.onLink,
              textCapitalization: TextCapitalization.sentences,
            ),
          ),
        ),
      ),
    );

    return Localizations.override(
      context: context,
      delegates: const [FlutterQuillLocalizations.delegate],
      child: Column(
        children: [
          SizedBox(height: widget.topPadding),
          Material(
            color: scheme.surfaceContainer,
            elevation: 1,
            child: compact
                ? toolbar
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: toolbar,
                  ),
          ),
          Expanded(
            child: Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF2A2A2E)
                  : const Color(0xFFE9E9EE),
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: Material(
                  color: Colors.white,
                  elevation: compact ? 0 : 2,
                  child: editor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
