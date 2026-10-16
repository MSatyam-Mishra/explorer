import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../common/office_package.dart';
import '../../document/layout/doc_render_context.dart' show fontFallbackFor;
import '../slide_model.dart';
import 'slide_file_image.dart';

/// Image providers for one deck.
class SlideImageCache {
  SlideImageCache(this.deck);
  final SlideDeck deck;
  final Map<String, ImageProvider> _providers = {};

  /// Reuses providers (and so decoded images) from [old] when the image is
  /// unchanged (e.g. after an edit re-reads the same package).
  void adoptFrom(SlideImageCache old) {
    old._providers.forEach((key, provider) {
      final id = key.split('@').first;
      final a = old.deck.images[id], b = deck.images[id];
      if (a == null || b == null) return;
      final same = a.bytes != null
          ? identical(a.bytes, b.bytes)
          : a.ref != null && a.ref == b.ref;
      if (same) _providers[key] = provider;
    });
  }

  /// Provider for image [id] decoded to fit [width] × [height] device
  /// pixels (aspect ratio kept; never upscaled). Null sizes decode at the
  /// image's own size. Null when the image isn't displayable.
  ImageProvider? provider(String id, {int? width, int? height}) {
    final data = deck.images[id];
    if (data == null || !isDisplayableImage(data.extension)) return null;
    final ImageProvider base;
    if (data.bytes != null) {
      base = MemoryImage(data.bytes!);
    } else if (data.ref != null) {
      base = SlideFileImage(data.ref!);
    } else {
      return null;
    }
    if (width == null && height == null) {
      return _providers.putIfAbsent(id, () => base);
    }
    return _providers.putIfAbsent(
      '$id@${width ?? 0}x${height ?? 0}',
      () => ResizeImage(
        base,
        width: width,
        height: height,
        policy: width != null && height != null
            ? ResizeImagePolicy.fit
            : ResizeImagePolicy.exact,
        allowUpscaling: false,
      ),
    );
  }
}

/// Paints a slide at its natural size (points as logical pixels). Wrap in a
/// [SlideFit] to scale it.
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({
    super.key,
    required this.deck,
    required this.slide,
    required this.images,
    this.onShapeTap,
    this.onLink,
    this.selectedShapeId,
    this.pixelScale,
  });

  final SlideDeck deck;
  final Slide slide;
  final SlideImageCache images;
  final ValueChanged<SlideAutoShape>? onShapeTap;
  final ValueChanged<String>? onLink;
  final String? selectedShapeId;

  /// Device pixels per slide point where the slide is shown (see
  /// [SlideFit.builder]); pictures are decoded at that resolution instead
  /// of their own, which is far cheaper for photos. Null decodes them at
  /// full size.
  final double? pixelScale;

  @override
  Widget build(BuildContext context) {
    if (slide.pending) {
      return SizedBox(
        width: deck.width,
        height: deck.height,
        child: const ColoredBox(color: Color(0xFFF1F3F4)),
      );
    }
    final children = <Widget>[
      Positioned.fill(child: _background(slide.background)),
      for (final s in slide.shapes) _shape(s),
    ];
    return SizedBox(
      width: deck.width,
      height: deck.height,
      child: ClipRect(
        child: Stack(clipBehavior: Clip.hardEdge, children: children),
      ),
    );
  }

  /// Device pixels for [points], rounded up to 128 px steps so small layout
  /// changes (e.g. showing the notes panel) reuse the decoded image.
  int? _px(double points) {
    final s = pixelScale;
    if (s == null || !points.isFinite || points <= 0) return null;
    return math.min(8192, math.max(128, (points * s / 128).ceil() * 128));
  }

  /// Provider for an image drawn with [BoxFit.cover] over [w] × [h] points.
  ImageProvider? _coverProvider(String id, double w, double h) {
    final side = _px(math.max(w, h));
    return images.provider(id, width: side, height: side);
  }

  Widget _background(SlideFill? fill) {
    if (fill == null || fill.isEmpty) {
      return const ColoredBox(color: Colors.white);
    }
    if (fill.imageId != null) {
      final p = _coverProvider(fill.imageId!, deck.width, deck.height);
      if (p != null) {
        return DecoratedBox(
          decoration: const BoxDecoration(color: Colors.white),
          child: Image(
            image: p,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        );
      }
    }
    if (fill.gradient != null && fill.gradient!.length > 1) {
      return DecoratedBox(decoration: BoxDecoration(gradient: _gradient(fill)));
    }
    return ColoredBox(color: Color(fill.color ?? 0xFFFFFFFF));
  }

  Widget _shape(SlideShape s) {
    final f = s.frame;
    Widget child;
    switch (s) {
      case SlideAutoShape():
        child = _autoShape(s);
      case SlidePicture():
        child = _picture(s);
      case SlideTable():
        child = _table(s);
    }
    if (s.rotation != 0) {
      child = Transform.rotate(angle: s.rotation * math.pi / 180, child: child);
    }
    final editable =
        onShapeTap != null &&
        s is SlideAutoShape &&
        s.fromSlide &&
        s.text != null &&
        s.id != null;
    if (editable) {
      final selected = s.id == selectedShapeId;
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onShapeTap!(s),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: child),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF1A73E8)
                          : const Color(0x661A73E8),
                      width: selected ? 3 : 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Positioned(
      left: f.x,
      top: f.y,
      width: math.max(f.w, 0.01),
      height: math.max(f.h, 0.01),
      child: child,
    );
  }

  Widget _autoShape(SlideAutoShape s) {
    final layers = <Widget>[];
    final fill = s.fill;
    final hasImageFill = fill?.imageId != null;
    layers.add(
      Positioned.fill(
        child: CustomPaint(painter: _ShapePainter(s, skipFill: hasImageFill)),
      ),
    );
    if (hasImageFill) {
      final p = _coverProvider(fill!.imageId!, s.frame.w, s.frame.h);
      if (p != null) {
        layers.insert(
          0,
          Positioned.fill(
            child: ClipPath(
              clipper: _GeometryClipper(s),
              child: Image(
                image: p,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
      }
    }
    final text = s.text;
    if (text != null && !text.isEmpty) {
      layers.add(
        Positioned.fill(
          child: _SlideTextView(body: text, onLink: onLink),
        ),
      );
    }
    return Stack(clipBehavior: Clip.none, children: layers);
  }

  Widget _picture(SlidePicture p) {
    final f = p.frame;
    final provider = images.provider(
      p.imageId,
      // The whole picture is f.w / visible-fraction wide before cropping.
      width: _px(f.w / (1 - p.cropLeft - p.cropRight).clamp(0.01, 10.0)),
    );
    Widget child;
    if (provider == null) {
      child = Container(
        color: const Color(0x14000000),
        alignment: Alignment.center,
        child: const Icon(
          Icons.image_not_supported_outlined,
          color: Color(0x66000000),
        ),
      );
    } else {
      final vw = (1 - p.cropLeft - p.cropRight).clamp(0.01, 10.0);
      final vh = (1 - p.cropTop - p.cropBottom).clamp(0.01, 10.0);
      final iw = f.w / vw, ih = f.h / vh;
      Widget image = Image(
        image: provider,
        width: iw,
        height: ih,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
      if (p.cropLeft != 0 ||
          p.cropTop != 0 ||
          p.cropRight != 0 ||
          p.cropBottom != 0) {
        image = ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: iw,
            maxWidth: iw,
            minHeight: ih,
            maxHeight: ih,
            child: Transform.translate(
              offset: Offset(-p.cropLeft * iw, -p.cropTop * ih),
              child: image,
            ),
          ),
        );
      }
      if (p.flipH || p.flipV) {
        image = Transform.flip(flipX: p.flipH, flipY: p.flipV, child: image);
      }
      switch (p.geometry) {
        case 'ellipse':
          image = ClipOval(child: image);
        case 'roundRect':
          image = ClipRRect(
            borderRadius: BorderRadius.circular(math.min(f.w, f.h) * 0.16667),
            child: image,
          );
      }
      child = image;
    }
    final line = p.line;
    if (line != null && line.color != 0) {
      child = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: Color(line.color), width: line.width),
          shape: p.geometry == 'ellipse' ? BoxShape.circle : BoxShape.rectangle,
        ),
        child: child,
      );
    }
    return child;
  }

  Widget _table(SlideTable t) {
    final f = t.frame;
    final total = t.columns.fold<double>(0, (a, b) => a + b);
    final scale = total <= 0 ? 1.0 : f.w / total;
    final widths = total <= 0
        ? List<double>.filled(
            t.rows.isEmpty ? 1 : t.rows.first.length,
            f.w / math.max(1, t.rows.first.length),
          )
        : [for (final w in t.columns) w * scale];
    final rows = <Widget>[];
    for (var r = 0; r < t.rows.length; r++) {
      final cells = <Widget>[];
      var c = 0;
      // Both PPTX (hMerge) and ODP (covered-table-cell) list a placeholder
      // for every column a cell spans; those columns are already drawn.
      var covered = 0;
      for (final cell in t.rows[r]) {
        if (covered > 0 && cell.merged) {
          covered--;
          continue;
        }
        covered = math.max(0, cell.colSpan - 1);
        final int span = math.min(
          math.max(1, cell.colSpan),
          math.max(1, widths.length - c),
        );
        var w = 0.0;
        for (var k = c; k < c + span && k < widths.length; k++) {
          w += widths[k];
        }
        c += span;
        if (w == 0) continue;
        cells.add(
          Container(
            width: w,
            constraints: BoxConstraints(
              minHeight: r < t.rowHeights.length ? t.rowHeights[r] : 0,
            ),
            decoration: BoxDecoration(
              color: cell.fill?.color == null ? null : Color(cell.fill!.color!),
              border: Border.all(
                color: Color(cell.borderColor ?? 0xFFBFBFBF),
                width: 0.75,
              ),
            ),
            child: cell.merged
                ? const SizedBox.shrink()
                : _SlideTextView(
                    body: cell.text,
                    onLink: onLink,
                    expand: false,
                  ),
          ),
        );
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    return OverflowBox(
      alignment: Alignment.topLeft,
      minHeight: 0,
      maxHeight: double.infinity,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

LinearGradient _gradient(SlideFill fill) {
  final stops = fill.gradient!;
  final a = fill.gradientAngle * math.pi / 180;
  final dx = math.cos(a), dy = math.sin(a);
  return LinearGradient(
    begin: Alignment(-dx, -dy),
    end: Alignment(dx, dy),
    colors: [for (final s in stops) Color(s.color)],
    stops: [for (final s in stops) s.position.clamp(0.0, 1.0)],
  );
}

/// Scales a slide to fit, keeping its aspect ratio.
class SlideFit extends StatelessWidget {
  const SlideFit({super.key, required this.deck, required Widget this.child})
    : builder = null;

  /// Builds the slide with the device pixels per slide point it's shown at
  /// (pass it to [SlideCanvas.pixelScale]).
  const SlideFit.builder({
    super.key,
    required this.deck,
    required Widget Function(BuildContext context, double pixelScale)
    this.builder,
  }) : child = null;

  final SlideDeck deck;
  final Widget? child;
  final Widget Function(BuildContext context, double pixelScale)? builder;

  @override
  Widget build(BuildContext context) {
    final build = builder;
    return AspectRatio(
      aspectRatio: deck.aspect,
      child: build == null
          ? FittedBox(fit: BoxFit.contain, child: child)
          : LayoutBuilder(
              builder: (context, c) {
                final dpr = MediaQuery.devicePixelRatioOf(context);
                final shown = c.hasBoundedWidth ? c.maxWidth : deck.width;
                final scale = deck.width <= 0 ? dpr : shown / deck.width * dpr;
                return FittedBox(
                  fit: BoxFit.contain,
                  child: build(context, scale),
                );
              },
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Text

class _SlideTextView extends StatefulWidget {
  const _SlideTextView({required this.body, this.onLink, this.expand = true});
  final SlideTextBody body;
  final ValueChanged<String>? onLink;
  final bool expand;

  @override
  State<_SlideTextView> createState() => _SlideTextViewState();
}

class _SlideTextViewState extends State<_SlideTextView> {
  final List<GestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TextStyle _style(SlideRun r, double lineSpacing) => TextStyle(
    inherit: false,
    fontSize: r.baseline != 0 ? r.size * 0.65 : r.size,
    fontFamily: r.font,
    fontFamilyFallback: fontFallbackFor(r.font),
    fontWeight: r.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
    color: Color(r.color),
    backgroundColor: r.highlight == null ? null : Color(r.highlight!),
    decoration: TextDecoration.combine([
      if (r.underline || r.link != null) TextDecoration.underline,
      if (r.strike) TextDecoration.lineThrough,
    ]),
    decorationColor: Color(r.color),
    height: 1.2 * lineSpacing,
    textBaseline: TextBaseline.alphabetic,
  );

  Widget _paragraph(SlideParagraph p) {
    final spans = <InlineSpan>[];
    for (final r in p.runs) {
      GestureRecognizer? rec;
      final link = r.link;
      if (link != null && widget.onLink != null) {
        final g = TapGestureRecognizer()..onTap = () => widget.onLink!(link);
        _recognizers.add(g);
        rec = g;
      }
      final text = r.caps ? r.text.toUpperCase() : r.text;
      final style = _style(r, p.lineSpacing);
      if (r.baseline > 0) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: Text(text, style: style, textScaler: TextScaler.noScaling),
          ),
        );
      } else {
        spans.add(TextSpan(text: text, style: style, recognizer: rec));
      }
    }
    final align = switch (p.align) {
      SlideAlign.center => TextAlign.center,
      SlideAlign.right => TextAlign.right,
      SlideAlign.justify => TextAlign.justify,
      SlideAlign.left => TextAlign.left,
    };
    final firstSize = p.runs.isEmpty ? p.endSize : p.runs.first.size;
    Widget text = p.runs.isEmpty || p.text.isEmpty
        ? SizedBox(height: p.endSize * 1.2 * p.lineSpacing)
        : RichText(
            text: TextSpan(children: spans),
            textAlign: align,
            textScaler: TextScaler.noScaling,
            softWrap: widget.body.wrap,
            overflow: TextOverflow.visible,
          );
    final label = p.bulletLabel;
    if (label != null) {
      final b = p.bullet;
      final color =
          b?.color ?? (p.runs.isEmpty ? 0xFF000000 : p.runs.first.color);
      final bulletStyle = TextStyle(
        inherit: false,
        fontSize: firstSize * (b?.sizePercent ?? 1),
        color: Color(color),
        fontFamily: p.runs.isEmpty ? null : p.runs.first.font,
        height: 1.2 * p.lineSpacing,
      );
      final bulletX = math.max(0.0, p.marginLeft + p.indent);
      final textX = math.max(p.marginLeft, bulletX + firstSize * 0.6);
      text = Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(left: textX),
            child: text,
          ),
          Positioned(
            left: bulletX,
            top: 0,
            child: Text(
              label,
              style: bulletStyle,
              textScaler: TextScaler.noScaling,
            ),
          ),
        ],
      );
    } else {
      final first = p.indent > 0 ? p.indent : 0.0;
      text = Padding(
        padding: EdgeInsets.only(
          left: math.max(0.0, p.marginLeft + math.min(0.0, p.indent)) + first,
        ),
        child: text,
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: p.spaceBefore, bottom: p.spaceAfter),
      child: text,
    );
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final b = widget.body;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final p in b.paragraphs) _paragraph(p)],
    );
    final padding = EdgeInsets.fromLTRB(
      b.insetLeft,
      b.insetTop,
      b.insetRight,
      b.insetBottom,
    );
    if (!widget.expand) {
      return Padding(
        padding: padding,
        child: Align(
          alignment: switch (b.anchor) {
            'ctr' => Alignment.centerLeft,
            'b' => Alignment.bottomLeft,
            _ => Alignment.topLeft,
          },
          widthFactor: 1,
          heightFactor: 1,
          child: column,
        ),
      );
    }
    Widget content = Padding(
      padding: padding,
      child: OverflowBox(
        alignment: switch (b.anchor) {
          'ctr' => Alignment.center,
          'b' => Alignment.bottomCenter,
          _ => Alignment.topCenter,
        },
        minHeight: 0,
        maxHeight: double.infinity,
        child: column,
      ),
    );
    if (b.vertical) content = RotatedBox(quarterTurns: 1, child: content);
    return content;
  }
}

// ---------------------------------------------------------------------------
// Geometry

Path slideGeometryPath(SlideAutoShape s, Size size) {
  final w = size.width, h = size.height;
  final m = math.min(w, h);
  final path = Path();
  Path poly(List<Offset> pts) => Path()..addPolygon(pts, true);
  switch (s.geometry) {
    case 'roundRect':
      return path..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(m * (s.adjust ?? 0.16667)),
        ),
      );
    case 'ellipse':
    case 'flowChartConnector':
    case 'cloud':
    case 'cloudCallout':
    case 'wedgeEllipseCallout':
      return path..addOval(Offset.zero & size);
    case 'triangle':
    case 'flowChartExtract':
      return poly([
        Offset(w * (s.adjust ?? 0.5), 0),
        Offset(w, h),
        Offset(0, h),
      ]);
    case 'rtTriangle':
      return poly([Offset.zero, Offset(0, h), Offset(w, h)]);
    case 'diamond':
    case 'flowChartDecision':
      return poly([
        Offset(w / 2, 0),
        Offset(w, h / 2),
        Offset(w / 2, h),
        Offset(0, h / 2),
      ]);
    case 'parallelogram':
    case 'flowChartInputOutput':
      final a = m * (s.adjust ?? 0.25);
      return poly([Offset(a, 0), Offset(w, 0), Offset(w - a, h), Offset(0, h)]);
    case 'trapezoid':
      final a = m * (s.adjust ?? 0.25);
      return poly([Offset(a, 0), Offset(w - a, 0), Offset(w, h), Offset(0, h)]);
    case 'homePlate':
      final a = m * (s.adjust ?? 0.5);
      return poly([
        Offset.zero,
        Offset(w - a, 0),
        Offset(w, h / 2),
        Offset(w - a, h),
        Offset(0, h),
      ]);
    case 'chevron':
      final a = m * (s.adjust ?? 0.5);
      return poly([
        Offset.zero,
        Offset(w - a, 0),
        Offset(w, h / 2),
        Offset(w - a, h),
        Offset(0, h),
        Offset(a, h / 2),
      ]);
    case 'pentagon':
      return poly([
        for (var i = 0; i < 5; i++)
          Offset(
            w / 2 + w / 2 * math.cos(-math.pi / 2 + i * 2 * math.pi / 5),
            h / 2 + h / 2 * math.sin(-math.pi / 2 + i * 2 * math.pi / 5),
          ),
      ]);
    case 'hexagon':
      final a = m * (s.adjust ?? 0.25);
      return poly([
        Offset(a, 0),
        Offset(w - a, 0),
        Offset(w, h / 2),
        Offset(w - a, h),
        Offset(a, h),
        Offset(0, h / 2),
      ]);
    case 'octagon':
      final a = m * (s.adjust ?? 0.29289);
      return poly([
        Offset(a, 0),
        Offset(w - a, 0),
        Offset(w, a),
        Offset(w, h - a),
        Offset(w - a, h),
        Offset(a, h),
        Offset(0, h - a),
        Offset(0, a),
      ]);
    case 'plus':
    case 'flowChartSummingJunction':
      final a = m * (s.adjust ?? 0.25);
      return poly([
        Offset(a, 0),
        Offset(w - a, 0),
        Offset(w - a, a),
        Offset(w, a),
        Offset(w, h - a),
        Offset(w - a, h - a),
        Offset(w - a, h),
        Offset(a, h),
        Offset(a, h - a),
        Offset(0, h - a),
        Offset(0, a),
        Offset(a, a),
      ]);
    case 'rightArrow':
    case 'leftArrow':
    case 'upArrow':
    case 'downArrow':
      final horizontal =
          s.geometry == 'rightArrow' || s.geometry == 'leftArrow';
      final len = horizontal ? w : h, thick = horizontal ? h : w;
      final head = math.min(len, thick * 0.5);
      final shaft = thick * 0.25;
      var pts = [
        Offset(0, shaft),
        Offset(len - head, shaft),
        Offset(len - head, 0),
        Offset(len, thick / 2),
        Offset(len - head, thick),
        Offset(len - head, thick - shaft),
        Offset(0, thick - shaft),
      ];
      pts = switch (s.geometry) {
        'leftArrow' => [for (final p in pts) Offset(len - p.dx, p.dy)],
        'downArrow' => [for (final p in pts) Offset(p.dy, p.dx)],
        'upArrow' => [for (final p in pts) Offset(p.dy, len - p.dx)],
        _ => pts,
      };
      return poly(pts);
    case 'leftRightArrow':
      final head = math.min(w / 2, h * 0.5);
      return poly([
        Offset(0, h / 2),
        Offset(head, 0),
        Offset(head, h * 0.25),
        Offset(w - head, h * 0.25),
        Offset(w - head, 0),
        Offset(w, h / 2),
        Offset(w - head, h),
        Offset(w - head, h * 0.75),
        Offset(head, h * 0.75),
        Offset(head, h),
      ]);
    case 'donut':
      final t = m * (s.adjust ?? 0.25);
      return Path()
        ..fillType = PathFillType.evenOdd
        ..addOval(Offset.zero & size)
        ..addOval(Rect.fromLTRB(t, t, w - t, h - t));
    case 'heart':
      return Path()
        ..moveTo(w / 2, h * 0.25)
        ..cubicTo(w * 0.15, -h * 0.1, -w * 0.2, h * 0.45, w / 2, h)
        ..moveTo(w / 2, h * 0.25)
        ..cubicTo(w * 0.85, -h * 0.1, w * 1.2, h * 0.45, w / 2, h);
    case 'round2SameRect':
      final r = m * (s.adjust ?? 0.16667);
      return path..addRRect(
        RRect.fromRectAndCorners(
          Offset.zero & size,
          topLeft: Radius.circular(r),
          topRight: Radius.circular(r),
        ),
      );
    case 'round1Rect':
      final r = m * (s.adjust ?? 0.16667);
      return path..addRRect(
        RRect.fromRectAndCorners(
          Offset.zero & size,
          topRight: Radius.circular(r),
        ),
      );
    case 'snip1Rect':
      final a = m * (s.adjust ?? 0.16667);
      return poly([
        Offset.zero,
        Offset(w - a, 0),
        Offset(w, a),
        Offset(w, h),
        Offset(0, h),
      ]);
    case 'snip2SameRect':
      final a = m * (s.adjust ?? 0.16667);
      return poly([
        Offset(a, 0),
        Offset(w - a, 0),
        Offset(w, a),
        Offset(w, h),
        Offset(0, h),
        Offset(0, a),
      ]);
    case 'custom':
      return _customPath(s, size);
    default:
      if (s.geometry.startsWith('star')) {
        final n = int.tryParse(s.geometry.substring(4)) ?? 5;
        final inner = n <= 5 ? 0.38 : (n <= 8 ? 0.6 : 0.75);
        final pts = <Offset>[];
        for (var i = 0; i < n * 2; i++) {
          final r = i.isEven ? 1.0 : inner;
          final ang = -math.pi / 2 + i * math.pi / n;
          pts.add(
            Offset(
              w / 2 + w / 2 * r * math.cos(ang),
              h / 2 + h / 2 * r * math.sin(ang),
            ),
          );
        }
        return poly(pts);
      }
      return path..addRect(Offset.zero & size);
  }
}

Path _customPath(SlideAutoShape s, Size size) {
  final out = Path();
  for (final p in s.customPaths ?? const <SlideCustomPath>[]) {
    // Path units: given width/height, else EMU of the shape.
    final pw = p.width > 0 ? p.width : s.frame.w * 12700;
    final ph = p.height > 0 ? p.height : s.frame.h * 12700;
    final sx = pw == 0 ? 1.0 : size.width / pw;
    final sy = ph == 0 ? 1.0 : size.height / ph;
    final path = Path();
    var cur = Offset.zero;
    for (final c in p.commands) {
      final pts = c.points;
      switch (c.op) {
        case 'M':
          cur = Offset(pts[0] * sx, pts[1] * sy);
          path.moveTo(cur.dx, cur.dy);
        case 'L':
          cur = Offset(pts[0] * sx, pts[1] * sy);
          path.lineTo(cur.dx, cur.dy);
        case 'C':
          if (pts.length >= 6) {
            path.cubicTo(
              pts[0] * sx,
              pts[1] * sy,
              pts[2] * sx,
              pts[3] * sy,
              pts[4] * sx,
              pts[5] * sy,
            );
            cur = Offset(pts[4] * sx, pts[5] * sy);
          }
        case 'Q':
          if (pts.length >= 4) {
            path.quadraticBezierTo(
              pts[0] * sx,
              pts[1] * sy,
              pts[2] * sx,
              pts[3] * sy,
            );
            cur = Offset(pts[2] * sx, pts[3] * sy);
          }
        case 'A':
          final wr = pts[0] * sx, hr = pts[1] * sy;
          final st = pts[2] * math.pi / 180, sw = pts[3] * math.pi / 180;
          final center = Offset(
            cur.dx - wr * math.cos(st),
            cur.dy - hr * math.sin(st),
          );
          final rect = Rect.fromCenter(
            center: center,
            width: wr * 2,
            height: hr * 2,
          );
          path.arcTo(rect, st, sw, false);
          cur = Offset(
            center.dx + wr * math.cos(st + sw),
            center.dy + hr * math.sin(st + sw),
          );
        case 'Z':
          path.close();
      }
    }
    out.addPath(path, Offset.zero);
  }
  return out;
}

bool _isLine(String g) => g == 'line' || g.contains('Connector') || g == 'arc';

class _GeometryClipper extends CustomClipper<Path> {
  _GeometryClipper(this.shape);
  final SlideAutoShape shape;

  @override
  Path getClip(Size size) => slideGeometryPath(shape, size);

  @override
  bool shouldReclip(_GeometryClipper old) => !identical(old.shape, shape);
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.shape, {this.skipFill = false});
  final SlideAutoShape shape;
  final bool skipFill;

  @override
  void paint(Canvas canvas, Size size) {
    final s = shape;
    canvas.save();
    if (s.flipH || s.flipV) {
      canvas.translate(s.flipH ? size.width : 0, s.flipV ? size.height : 0);
      canvas.scale(s.flipH ? -1 : 1, s.flipV ? -1 : 1);
    }
    final line = s.line;
    final strokePaint =
        line == null || line.color == 0 || (line.color >> 24) == 0
        ? null
        : (Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.5, line.width)
            ..color = Color(line.color)
            ..strokeJoin = StrokeJoin.round);

    if (_isLine(s.geometry)) {
      if (strokePaint != null) {
        final path = Path();
        final w = s.frame.w, h = s.frame.h;
        if (s.geometry.startsWith('bentConnector')) {
          path
            ..moveTo(0, 0)
            ..lineTo(w / 2, 0)
            ..lineTo(w / 2, h)
            ..lineTo(w, h);
        } else if (s.geometry.startsWith('curvedConnector')) {
          path
            ..moveTo(0, 0)
            ..cubicTo(w / 2, 0, w / 2, h, w, h);
        } else if (s.geometry == 'arc') {
          path.addArc(Offset.zero & size, -math.pi / 2, math.pi / 2);
        } else {
          path
            ..moveTo(0, 0)
            ..lineTo(w, h);
        }
        _stroke(canvas, path, strokePaint, line!);
        if (line.tailArrow) {
          _arrow(
            canvas,
            Offset(w, h),
            Offset(w > 0 || h > 0 ? 0 : -1, 0),
            strokePaint,
          );
        }
        if (line.headArrow) {
          _arrow(canvas, Offset.zero, Offset(w, h), strokePaint);
        }
      }
      canvas.restore();
      return;
    }

    final path = slideGeometryPath(s, size);
    final fill = s.fill;
    if (!skipFill && fill != null && !fill.isEmpty) {
      final paint = Paint()..style = PaintingStyle.fill;
      if (fill.gradient != null && fill.gradient!.length > 1) {
        paint.shader = _gradient(fill).createShader(Offset.zero & size);
      } else {
        paint.color = Color(fill.color ?? 0x00000000);
      }
      canvas.drawPath(path, paint);
    }
    if (strokePaint != null) _stroke(canvas, path, strokePaint, line!);
    canvas.restore();
  }

  void _stroke(Canvas canvas, Path path, Paint paint, SlideLine line) {
    if (line.dash == null) {
      canvas.drawPath(path, paint);
      return;
    }
    final w = paint.strokeWidth;
    final pattern = switch (line.dash) {
      'dot' || 'sysDot' => [w, w * 2],
      'dashDot' || 'sysDashDot' => [w * 4, w * 2, w, w * 2],
      'lgDash' => [w * 8, w * 3],
      _ => [w * 4, w * 3],
    };
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      var i = 0;
      while (d < metric.length) {
        final len = pattern[i % pattern.length];
        if (i.isEven) canvas.drawPath(metric.extractPath(d, d + len), paint);
        d += len;
        i++;
      }
    }
  }

  void _arrow(Canvas canvas, Offset tip, Offset from, Paint stroke) {
    final dir = tip - from;
    if (dir.distance == 0) return;
    final u = dir / dir.distance;
    final size = math.max(6.0, stroke.strokeWidth * 4);
    final back = tip - u * size;
    final n = Offset(-u.dy, u.dx) * (size / 2);
    final p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(back.dx + n.dx, back.dy + n.dy)
      ..lineTo(back.dx - n.dx, back.dy - n.dy)
      ..close();
    canvas.drawPath(p, Paint()..color = stroke.color);
  }

  @override
  bool shouldRepaint(_ShapePainter old) => !identical(old.shape, shape);
}
