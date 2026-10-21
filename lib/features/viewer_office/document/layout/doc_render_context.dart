import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

import '../../common/office_package.dart';
import '../doc_model.dart';

/// A search hit inside one paragraph's plain text.
class DocHighlight {
  const DocHighlight(this.start, this.end, {this.current = false});
  final int start;
  final int end;
  final bool current;
}

/// Everything the renderer needs besides the laid-out geometry. Changing
/// any of these never changes layout, so pages don't need re-measuring.
class DocRenderContext {
  DocRenderContext({
    required this.model,
    required this.images,
    this.darkPage = false,
    this.highlights = const {},
    this.onLink,
    this.pageNumber,
    this.pageCount,
  });

  final DocModel model;
  final DocImageCache images;
  final bool darkPage;
  final Map<DocParagraph, List<DocHighlight>> highlights;
  final ValueChanged<String>? onLink;
  final int? pageNumber;
  final int? pageCount;

  DocRenderContext forPage(int number, int count) => DocRenderContext(
    model: model,
    images: images,
    darkPage: darkPage,
    highlights: highlights,
    onLink: onLink,
    pageNumber: number,
    pageCount: count,
  );

  Color get pageColor => darkPage ? const Color(0xFF1F1F22) : Colors.white;

  Color get defaultText =>
      darkPage ? const Color(0xFFE6E6E6) : const Color(0xFF000000);

  Color textColor(int? argb) {
    if (argb == null) return defaultText;
    final c = Color(argb);
    if (!darkPage) return c;
    // Lift dark text so it stays readable on a dark page.
    final hsl = HSLColor.fromColor(c);
    if (hsl.lightness < 0.55) {
      return hsl.withLightness((1 - hsl.lightness).clamp(0.6, 0.92)).toColor();
    }
    return c;
  }

  Color fillColor(int argb) {
    final c = Color(argb);
    if (!darkPage) return c;
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((1 - hsl.lightness).clamp(0.08, 0.35)).toColor();
  }

  Color highlightColor(int argb) {
    final c = Color(argb);
    return darkPage ? c.withValues(alpha: 0.45) : c;
  }

  Color get borderColor =>
      darkPage ? const Color(0xFF8A8A8A) : const Color(0xFF000000);
}

/// Decoded-image cache keyed by image id.
class DocImageCache {
  DocImageCache(this.model);
  final DocModel model;
  final Map<String, ImageProvider> _providers = {};

  /// Provider for picture [id] shown [width] points wide. Pictures are
  /// decoded at about 3 px per point (sharp up to roughly 2× zoom on a
  /// phone) instead of at full camera resolution, which saves decode time
  /// and memory; nothing is decoded until the picture is on screen.
  ImageProvider? provider(String id, {double? width}) {
    final data = model.images[id];
    if (data == null || !isDisplayableImage(data.extension)) return null;
    // Round up to share one decode between slightly different sizes.
    final px = width == null || width <= 0
        ? 0
        : ((width * 3 / 256).ceil() * 256).clamp(256, 4096);
    return _providers.putIfAbsent('$id@$px', () {
      final image = MemoryImage(data.bytes);
      return px == 0 ? image : ResizeImage(image, width: px);
    });
  }

  String extensionOf(String id) => model.images[id]?.extension ?? '?';
}

const _serifHints = [
  'times',
  'cambria',
  'georgia',
  'garamond',
  'antiqua',
  'palatino',
  'constantia',
  'baskerville',
  'bookman',
  'century',
  'minion',
  'serif',
  'caladea',
  'didot',
  'bodoni',
  'perpetua',
  'rockwell',
  'sylfaen',
];
const _monoHints = ['courier', 'consolas', 'mono', 'menlo', 'lucida console'];

List<String>? fontFallbackFor(String? family) {
  if (family == null) return null;
  final f = family.toLowerCase();
  if (_monoHints.any(f.contains)) {
    return const ['Courier New', 'Menlo', 'monospace'];
  }
  if (_serifHints.any(f.contains) && !f.contains('sans')) {
    return const ['Times New Roman', 'Georgia', 'serif', 'Noto Serif'];
  }
  return null;
}

/// Text style for a run, shared by measuring and painting.
TextStyle docTextStyle(
  DocRunStyle s,
  DocRenderContext ctx, {
  double? lineHeight,
  bool link = false,
  double sizeFactor = 1,
}) {
  final size = (s.fontSize ?? 11) * sizeFactor;
  final decorations = <TextDecoration>[
    if (s.underline) TextDecoration.underline,
    if (s.strike) TextDecoration.lineThrough,
  ];
  return TextStyle(
    inherit: false,
    fontSize: size,
    fontFamily: s.fontFamily,
    fontFamilyFallback: fontFallbackFor(s.fontFamily),
    fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
    color: ctx.textColor(s.color),
    backgroundColor: s.highlight == null
        ? null
        : ctx.highlightColor(s.highlight!),
    decoration: decorations.isEmpty
        ? TextDecoration.none
        : TextDecoration.combine(decorations),
    decorationColor: ctx.textColor(s.color),
    height: lineHeight,
    textBaseline: TextBaseline.alphabetic,
    fontFeatures: s.smallCaps ? const [FontFeature.enable('smcp')] : null,
  );
}

/// Result of building a paragraph's inline span.
class DocSpan {
  DocSpan(this.span, this.placeholders);
  final InlineSpan span;
  final List<PlaceholderDimensions> placeholders;
}

const double kDocTabWidth = 28;

/// Builds the inline span for [p]. With [measure] true the widget children
/// are cheap placeholders (only their sizes matter).
DocSpan buildParagraphSpan(
  DocParagraph p,
  DocRenderContext ctx, {
  required double maxWidth,
  bool measure = false,
  List<GestureRecognizer>? recognizers,
}) {
  final children = <InlineSpan>[];
  final dims = <PlaceholderDimensions>[];
  final hl = ctx.highlights[p];
  final multiple = p.lineExact == null && (p.lineSpacing - 1).abs() > 0.01
      ? 1.17 * p.lineSpacing
      : null;
  var offset = 0;

  void placeholder(
    Size size,
    PlaceholderAlignment align,
    Widget Function() child,
  ) {
    dims.add(PlaceholderDimensions(size: size, alignment: align));
    children.add(
      WidgetSpan(
        alignment: align,
        child: measure
            ? SizedBox(width: size.width, height: size.height)
            : child(),
      ),
    );
  }

  if (p.firstLine > 0 && p.list == null) {
    placeholder(
      Size(p.firstLine, 0),
      PlaceholderAlignment.bottom,
      () => SizedBox(width: p.firstLine, height: 0),
    );
  }

  void addText(
    String text,
    TextStyle style,
    DocRunStyle run,
    String? link,
    int start,
  ) {
    if (text.isEmpty) return;
    GestureRecognizer? recognizer;
    if (link != null && !measure && ctx.onLink != null) {
      final r = TapGestureRecognizer()..onTap = () => ctx.onLink!(link);
      recognizers?.add(r);
      recognizer = r;
    }
    if (run.vertAlign != DocVertAlign.baseline) {
      final small = style.copyWith(
        fontSize: (style.fontSize ?? 11) * 0.62,
        height: 1,
      );
      final tp = TextPainter(
        text: TextSpan(text: text, style: small),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        maxLines: 1,
      )..layout();
      final size = Size(tp.width, tp.height);
      tp.dispose();
      final align = run.vertAlign == DocVertAlign.superscript
          ? PlaceholderAlignment.top
          : PlaceholderAlignment.bottom;
      placeholder(size, align, () {
        final w = RichText(
          text: TextSpan(text: text, style: small, recognizer: recognizer),
          textScaler: TextScaler.noScaling,
          maxLines: 1,
          softWrap: false,
        );
        return w;
      });
      return;
    }
    if (hl == null || hl.isEmpty) {
      children.add(TextSpan(text: text, style: style, recognizer: recognizer));
      return;
    }
    // Split around highlights.
    var pos = 0;
    final end = text.length;
    final ranges = [
      for (final h in hl)
        if (h.end > start && h.start < start + end) h,
    ];
    for (final h in ranges) {
      final s = (h.start - start).clamp(0, end);
      final e = (h.end - start).clamp(0, end);
      if (s > pos) {
        children.add(
          TextSpan(
            text: text.substring(pos, s),
            style: style,
            recognizer: recognizer,
          ),
        );
      }
      if (e > s) {
        children.add(
          TextSpan(
            text: text.substring(s, e),
            style: style.copyWith(
              backgroundColor: h.current
                  ? const Color(0xFFFF9632)
                  : const Color(0xFFFFEB3B),
              color: Colors.black,
            ),
            recognizer: recognizer,
          ),
        );
      }
      pos = e > pos ? e : pos;
    }
    if (pos < end) {
      children.add(
        TextSpan(
          text: text.substring(pos),
          style: style,
          recognizer: recognizer,
        ),
      );
    }
  }

  for (final inline in p.inlines) {
    switch (inline) {
      case DocText():
        var text = inline.text;
        final originalLength = text.length;
        if (inline.field == 'PAGE' && ctx.pageNumber != null) {
          text = '${ctx.pageNumber}';
        } else if (inline.field == 'NUMPAGES' && ctx.pageCount != null) {
          text = '${ctx.pageCount}';
        }
        var run = inline.style;
        if (inline.link != null && run.color == null) {
          run = run.copyWith(color: 0xFF0563C1, underline: true);
        }
        if (run.allCaps) text = text.toUpperCase();
        final style = docTextStyle(run, ctx, lineHeight: multiple);
        // Tabs become fixed-width gaps.
        var segStart = offset;
        final parts = text.split('\t');
        for (var i = 0; i < parts.length; i++) {
          addText(parts[i], style, run, inline.link, segStart);
          segStart += parts[i].length;
          if (i < parts.length - 1) {
            placeholder(
              const Size(kDocTabWidth, 0),
              PlaceholderAlignment.bottom,
              () => const SizedBox(width: kDocTabWidth, height: 0),
            );
            segStart += 1;
          }
        }
        offset += originalLength;
      case DocImage():
        if (inline.float != null) {
          // Floating pictures are painted by the page, not the text flow.
          offset += 1;
          continue;
        }
        var w = inline.width <= 0 ? 144.0 : inline.width;
        var h = inline.height <= 0 ? 108.0 : inline.height;
        if (w > maxWidth && maxWidth > 0) {
          h = h * maxWidth / w;
          w = maxWidth;
        }
        final id = inline.imageId;
        placeholder(
          Size(w, h),
          PlaceholderAlignment.bottom,
          () => DocImageBox(id: id, width: w, height: h, ctx: ctx),
        );
        offset += 1;
      case DocObject():
        final t = inline.displayText ?? '';
        if (t.isNotEmpty) {
          addText(
            t,
            docTextStyle(inline.style, ctx, lineHeight: multiple),
            inline.style,
            null,
            offset,
          );
        }
        offset += t.length;
    }
  }

  final rootStyle = docTextStyle(p.markStyle, ctx, lineHeight: multiple);
  if (children.isEmpty) {
    children.add(TextSpan(text: '\u200B', style: rootStyle));
  }
  return DocSpan(TextSpan(style: rootStyle, children: children), dims);
}

/// Strut forcing exact line heights.
StrutStyle? paragraphStrut(DocParagraph p) {
  final exact = p.lineExact;
  if (exact == null) return null;
  return StrutStyle(
    fontSize: exact,
    height: 1,
    forceStrutHeight: true,
    leading: 0,
  );
}

TextAlign paragraphAlign(DocParagraph p) {
  switch (p.align) {
    case DocAlign.center:
      return TextAlign.center;
    case DocAlign.right:
      return p.rtl ? TextAlign.left : TextAlign.right;
    case DocAlign.justify:
      return TextAlign.justify;
    case DocAlign.left:
      return p.rtl ? TextAlign.right : TextAlign.left;
  }
}

/// Picture (or a placeholder for formats Flutter can't decode).
class DocImageBox extends StatelessWidget {
  const DocImageBox({
    super.key,
    required this.id,
    required this.width,
    required this.height,
    required this.ctx,
  });

  final String id;
  final double width;
  final double height;
  final DocRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final provider = ctx.images.provider(id, width: width);
    if (provider == null) {
      return _placeholder(ctx.images.extensionOf(id).toUpperCase());
    }
    return SizedBox(
      width: width,
      height: height,
      child: Image(
        image: provider,
        width: width,
        height: height,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder('Image'),
      ),
    );
  }

  Widget _placeholder(String label) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0x14000000),
        border: Border.all(color: const Color(0x33000000), width: 0.5),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                LucideIcons.imageOff,
                size: 18,
                color: Color(0x88000000),
              ),
              Text(
                '$label image',
                style: const TextStyle(
                  fontSize: 9,
                  color: Color(0x88000000),
                  inherit: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
