import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/viewer_ui.dart';
import '../doc_model.dart';
import '../layout/doc_layout.dart';
import '../layout/doc_render_context.dart';

/// Lets the screen scroll whichever document view is showing.
class DocViewController {
  _Revealer? _target;

  /// Scrolls to [blockIndex] (a top-level block), at [paragraph]'s
  /// character [offset] when given.
  void reveal(int blockIndex, {DocParagraph? paragraph, int offset = 0}) =>
      _target?.reveal(blockIndex, paragraph, offset);

  int get currentPage => _target?.currentPage ?? 0;
}

abstract class _Revealer {
  void reveal(int blockIndex, DocParagraph? paragraph, int offset);
  int get currentPage;
}

/// Tracks a two-finger pinch from raw pointer events so it can coexist with
/// the scroll views underneath.
class _Pinch {
  final Map<int, Offset> pointers = {};
  double? startDistance;
  double startZoom = 1;

  bool get active => startDistance != null;

  double _distance() {
    final p = pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  Offset focal() {
    final p = pointers.values.toList();
    return p.length < 2 ? p.first : (p[0] + p[1]) / 2;
  }

  void down(PointerDownEvent e, double zoom) {
    pointers[e.pointer] = e.localPosition;
    if (pointers.length == 2) {
      startDistance = math.max(1, _distance());
      startZoom = zoom;
    }
  }

  /// New zoom, or null if not pinching.
  double? move(PointerMoveEvent e) {
    if (!pointers.containsKey(e.pointer)) return null;
    pointers[e.pointer] = e.localPosition;
    if (startDistance == null || pointers.length < 2) return null;
    return startZoom * _distance() / startDistance!;
  }

  bool up(PointerEvent e) {
    pointers.remove(e.pointer);
    if (pointers.length < 2 && startDistance != null) {
      startDistance = null;
      return true;
    }
    return false;
  }
}

class _ZoomPill extends StatelessWidget {
  const _ZoomPill({
    required this.label,
    required this.onMinus,
    required this.onPlus,
    this.onReset,
  });
  final String label;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return ViewerPill(
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ViewerAction(
            tooltip: 'Zoom out',
            icon: LucideIcons.minus,
            size: 32,
            iconSize: 16,
            onPressed: onMinus,
          ),
          Tooltip(
            message: 'Reset zoom',
            child: InkWell(
              onTap: onReset,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(label),
              ),
            ),
          ),
          ViewerAction(
            tooltip: 'Zoom in',
            icon: LucideIcons.plus,
            size: 32,
            iconSize: 16,
            onPressed: onPlus,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Print layout

class DocPagesView extends StatefulWidget {
  const DocPagesView({
    super.key,
    required this.result,
    required this.ctx,
    required this.controller,
    this.topPadding = 0,
  });

  final DocLayoutResult result;
  final DocRenderContext ctx;
  final DocViewController controller;
  final double topPadding;

  @override
  State<DocPagesView> createState() => _DocPagesViewState();
}

class _DocPagesViewState extends State<DocPagesView> implements _Revealer {
  final ScrollController _v = ScrollController();
  final ScrollController _h = ScrollController();
  final _Pinch _pinch = _Pinch();
  double _zoom = 1;
  double _scale = 1;
  List<double> _extents = const [];
  int _page = 0;
  bool _pinching = false;
  static const _gap = 16.0;

  @override
  void initState() {
    super.initState();
    widget.controller._target = this;
    _v.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(DocPagesView old) {
    super.didUpdateWidget(old);
    widget.controller._target = this;
  }

  @override
  void dispose() {
    if (identical(widget.controller._target, this)) {
      widget.controller._target = null;
    }
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  int get currentPage => _page;

  void _onScroll() {
    if (!_v.hasClients || _extents.isEmpty) return;
    final probe =
        _v.offset + _v.position.viewportDimension * 0.35 - widget.topPadding;
    var acc = 0.0;
    var p = 0;
    for (var i = 0; i < _extents.length; i++) {
      if (probe < acc + _extents[i]) {
        p = i;
        break;
      }
      acc += _extents[i];
      p = i;
    }
    if (p != _page) setState(() => _page = p);
  }

  double _pageTop(int page) {
    var y = widget.topPadding + 8;
    for (var i = 0; i < page && i < _extents.length; i++) {
      y += _extents[i];
    }
    return y;
  }

  @override
  void reveal(int blockIndex, DocParagraph? paragraph, int offset) {
    final r = widget.result;
    if (blockIndex < 0 || blockIndex >= r.blocks.length) return;
    final laid = r.blocks[blockIndex];
    var y = 0.0;
    if (paragraph != null &&
        laid is LaidParagraph &&
        identical(laid.paragraph, paragraph)) {
      y = laid.caretY(widget.ctx, offset);
    } else if (paragraph != null && laid is LaidTable) {
      y = laid.yOfParagraph(paragraph) ?? 0;
    }
    final loc = r.locate(blockIndex, y);
    if (loc == null || !_v.hasClients) return;
    final page = r.pages[loc.$1];
    final target =
        _pageTop(loc.$1) +
        _gap / 2 +
        (page.setup.marginTop + loc.$2) * _scale -
        _v.position.viewportDimension * 0.3;
    _v.animateTo(
      target.clamp(0.0, _v.position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _setZoom(double z, {Offset? focal}) {
    final nz = z.clamp(0.4, 5.0);
    if ((nz - _zoom).abs() < 0.001) return;
    final ratio = nz / _zoom;
    final f =
        focal ??
        Offset(0, _v.hasClients ? _v.position.viewportDimension / 2 : 0);
    setState(() => _zoom = nz);
    if (_v.hasClients) {
      final target = (_v.offset + f.dy) * ratio - f.dy;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_v.hasClients) return;
        _v.jumpTo(target.clamp(0.0, _v.position.maxScrollExtent));
      });
    }
    if (_h.hasClients) {
      final target = (_h.offset + f.dx) * ratio - f.dx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_h.hasClients) return;
        _h.jumpTo(target.clamp(0.0, _h.position.maxScrollExtent));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return LayoutBuilder(
      builder: (context, c) {
        final avail = c.maxWidth;
        final maxW = r.pages.fold<double>(
          1,
          (m, p) => math.max(m, p.setup.width),
        );
        final readable = math.min(avail - 24, 900.0);
        _scale = math.max(0.05, readable / maxW) * _zoom;
        final scale = _scale;
        _extents = [for (final p in r.pages) p.setup.height * scale + _gap];
        final contentW = maxW * scale + 24;
        final page = ViewerSurface.page(context);

        Widget list = ListView.builder(
          controller: _v,
          physics: _pinching ? const NeverScrollableScrollPhysics() : null,
          padding: EdgeInsets.only(top: widget.topPadding + 8, bottom: 96),
          itemCount: r.pages.length,
          itemExtentBuilder: (i, _) => i < _extents.length ? _extents[i] : null,
          itemBuilder: (context, i) {
            final s = r.pages[i].setup;
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: _gap / 2),
                child: DecoratedBox(
                  // The page paints its own paper (white, or dark with
                  // "Dark page"); this adds the edge and shadow.
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(border: page.border),
                  child: DecoratedBox(
                    decoration: BoxDecoration(boxShadow: page.boxShadow),
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: s.width * scale,
                        height: s.height * scale,
                        child: FittedBox(
                          fit: BoxFit.fill,
                          alignment: Alignment.topLeft,
                          child: DocPageView(
                            result: r,
                            pageIndex: i,
                            ctx: widget.ctx,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
        if (contentW > avail) {
          list = Scrollbar(
            controller: _h,
            child: SingleChildScrollView(
              controller: _h,
              scrollDirection: Axis.horizontal,
              physics: _pinching ? const NeverScrollableScrollPhysics() : null,
              child: SizedBox(
                width: contentW,
                height: c.maxHeight,
                child: list,
              ),
            ),
          );
        }

        return Listener(
          onPointerDown: (e) {
            _pinch.down(e, _zoom);
            if (_pinch.active && !_pinching) setState(() => _pinching = true);
          },
          onPointerMove: (e) {
            final z = _pinch.move(e);
            if (z != null) _setZoom(z, focal: _pinch.focal());
          },
          onPointerUp: (e) {
            if (_pinch.up(e)) setState(() => _pinching = false);
          },
          onPointerCancel: (e) {
            if (_pinch.up(e)) setState(() => _pinching = false);
          },
          onPointerSignal: (e) {
            if (e is PointerScrollEvent &&
                HardwareKeyboard.instance.isControlPressed) {
              GestureBinding.instance.pointerSignalResolver.register(e, (_) {
                _setZoom(
                  _zoom * (e.scrollDelta.dy > 0 ? 0.9 : 1.1),
                  focal: e.localPosition,
                );
              });
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: ViewerSurface.canvas(context),
                  child: Scrollbar(controller: _v, child: list),
                ),
              ),
              Positioned(
                left: 12,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: _PageBadge(
                  // Later pages are still being laid out.
                  text:
                      'Page ${_page + 1} of ${r.pages.length}'
                      '${r.complete ? '' : '+'}',
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12 + MediaQuery.paddingOf(context).bottom,
                child: _ZoomPill(
                  label: '${(_zoom * 100).round()}%',
                  onMinus: () => _setZoom(_zoom / 1.25),
                  onPlus: () => _setZoom(_zoom * 1.25),
                  onReset: () => _setZoom(1),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => ViewerPill(text: text);
}

// ---------------------------------------------------------------------------
// Mobile (reflow) view

class DocReflowView extends StatefulWidget {
  const DocReflowView({
    super.key,
    required this.model,
    required this.ctx,
    required this.controller,
    this.topPadding = 0,
  });

  final DocModel model;
  final DocRenderContext ctx;
  final DocViewController controller;
  final double topPadding;

  @override
  State<DocReflowView> createState() => _DocReflowViewState();
}

class _DocReflowViewState extends State<DocReflowView> implements _Revealer {
  final ScrollController _v = ScrollController();
  final _Pinch _pinch = _Pinch();
  double _textScale = 1.3;
  double _pendingScale = 1.3;
  double _layoutWidth = 0;
  List<LaidBlock>? _blocks;
  List<double> _offsets = const [];
  int _generation = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.controller._target = this;
  }

  @override
  void didUpdateWidget(DocReflowView old) {
    super.didUpdateWidget(old);
    widget.controller._target = this;
    if (!identical(old.model, widget.model)) {
      _blocks = null;
      _layoutWidth = 0;
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller._target, this)) {
      widget.controller._target = null;
    }
    _debounce?.cancel();
    _v.dispose();
    super.dispose();
  }

  @override
  int get currentPage => 0;

  Future<void> _layout(double width) async {
    final gen = ++_generation;
    final engine = DocLayoutEngine(widget.model, widget.ctx);
    final out = <LaidBlock>[];
    final offsets = <double>[];
    var y = 0.0;
    final blocks = widget.model.blocks;
    final sw = Stopwatch()..start();
    final sinceShown = Stopwatch()..start();
    var shown = false;
    // Lay out in batches (keeping contextual spacing within each batch) and
    // show what's ready: the first screenful right away, the rest as it
    // comes.
    var i = 0;
    while (i < blocks.length) {
      final end = math.min(blocks.length, i + 40);
      for (final b in engine.layoutBlocks(blocks.sublist(i, end), width)) {
        offsets.add(y);
        y += b is LaidMarker ? 24 : b.height;
        out.add(b);
      }
      i = end;
      if (sw.elapsedMilliseconds > 8) {
        if (!shown || sinceShown.elapsedMilliseconds > 250) {
          shown = true;
          sinceShown.reset();
          setState(() {
            _blocks = List.of(out);
            _offsets = List.of(offsets);
            _layoutWidth = width;
          });
        }
        await Future<void>.delayed(Duration.zero);
        if (!mounted || gen != _generation) return;
        sw.reset();
      }
    }
    if (!mounted || gen != _generation) return;
    setState(() {
      _blocks = out;
      _offsets = offsets;
      _layoutWidth = width;
    });
  }

  @override
  void reveal(int blockIndex, DocParagraph? paragraph, int offset) {
    final blocks = _blocks;
    if (blocks == null || blockIndex >= blocks.length || !_v.hasClients) return;
    final laid = blocks[blockIndex];
    var y = 0.0;
    if (paragraph != null &&
        laid is LaidParagraph &&
        identical(laid.paragraph, paragraph)) {
      y = laid.caretY(widget.ctx, offset);
    } else if (paragraph != null && laid is LaidTable) {
      y = laid.yOfParagraph(paragraph) ?? 0;
    }
    final target =
        widget.topPadding +
        16 +
        (_offsets[blockIndex] + y) * _textScale -
        _v.position.viewportDimension * 0.3;
    _v.animateTo(
      target.clamp(0.0, _v.position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _setScale(double s) {
    _pendingScale = s.clamp(0.8, 3.0);
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _textScale = _pendingScale;
        _blocks = null;
        _layoutWidth = 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final avail = math.min(c.maxWidth, 900.0);
        final width = math.max(120.0, (avail - 32) / _textScale);
        if (_blocks == null || (width - _layoutWidth).abs() > 1) {
          if ((width - _layoutWidth).abs() > 1) {
            _layoutWidth = width;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _layout(width);
            });
          }
          if (_blocks == null) {
            return const Center(child: CircularProgressIndicator());
          }
        }
        final blocks = _blocks!;
        final scale = _textScale;
        final preview = _pendingScale / _textScale;
        Widget list = ListView.builder(
          controller: _v,
          padding: EdgeInsets.only(top: widget.topPadding + 16, bottom: 96),
          itemCount: blocks.length,
          itemBuilder: (context, i) {
            final b = blocks[i];
            if (b is LaidMarker) {
              return SizedBox(
                height: 24 * scale,
                child: Center(
                  child: Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    color: widget.ctx.borderColor.withValues(alpha: 0.25),
                  ),
                ),
              );
            }
            return Center(
              child: SizedBox(
                width: b.width * scale,
                height: b.height * scale,
                child: FittedBox(
                  fit: BoxFit.fill,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: b.width,
                    height: b.height,
                    child: b.build(widget.ctx),
                  ),
                ),
              ),
            );
          },
        );
        if ((preview - 1).abs() > 0.01) {
          list = Transform.scale(
            scale: preview,
            alignment: Alignment.topCenter,
            child: list,
          );
        }
        return Listener(
          onPointerDown: (e) => _pinch.down(e, _pendingScale),
          onPointerMove: (e) {
            final z = _pinch.move(e);
            if (z != null) _setScale(z);
          },
          onPointerUp: _pinch.up,
          onPointerCancel: _pinch.up,
          child: ColoredBox(
            color: widget.ctx.pageColor,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Scrollbar(controller: _v, child: list),
                ),
                Positioned(
                  right: 12,
                  bottom: 12 + MediaQuery.paddingOf(context).bottom,
                  child: _ZoomPill(
                    label: 'Aa ${(_pendingScale * 100 / 1.3).round()}%',
                    onMinus: () => _setScale(_pendingScale / 1.15),
                    onPlus: () => _setScale(_pendingScale * 1.15),
                    onReset: () => _setScale(1.3),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
