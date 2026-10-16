// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// The lens renderer isn't exported; pubspec pins liquid_glass_easy to 1.1.1.
import 'package:liquid_glass_easy/src/widgets/liquid_glass.dart'
    show LiquidGlassWidget;

/// [LiquidGlassView] (liquid_glass_easy 1.1.1, MIT licence) that re-captures
/// its background only when the background changes.
///
/// The package view drives capture with a never-ending animation, so every
/// screen rendered a frame per vsync and re-rasterised the whole page about
/// 24 times a second even when idle, competing with whatever the page was
/// loading or drawing. Here a capture is scheduled when the background
/// repaints, scrolls or is touched, at most every [_activeInterval], and
/// repeated slowly for [_settleTime] afterwards to pick up content inside
/// nested repaint boundaries (list items, images) that changes without
/// repainting the background itself. An idle page renders no frames.
class OnDemandLiquidGlassView extends StatefulWidget {
  const OnDemandLiquidGlassView({
    super.key,
    required this.backgroundWidget,
    required this.children,
    this.controller,
    this.pixelRatio = 1.0,
    this.autoCapture = true,
  });

  final Widget backgroundWidget;
  final List<LiquidGlass> children;
  final LiquidGlassViewController? controller;

  /// Capture resolution; 0 uses the device pixel ratio (never more).
  final double pixelRatio;

  /// When false, the background is captured once and on
  /// [LiquidGlassViewController.captureOnce] only.
  final bool autoCapture;

  @override
  State<OnDemandLiquidGlassView> createState() =>
      _OnDemandLiquidGlassViewState();
}

class _OnDemandLiquidGlassViewState extends State<OnDemandLiquidGlassView> {
  static const _activeInterval = Duration(milliseconds: 42);
  static const _settleInterval = Duration(milliseconds: 250);
  static const _settleTime = Duration(milliseconds: 1500);

  static Future<(ui.FragmentProgram, ui.FragmentProgram)>? _programs;

  final _boundaryKey = GlobalKey();
  final _clock = Stopwatch()..start();
  ui.FragmentShader? _shader;
  ui.FragmentShader? _borderShader;
  ui.Image? _image;
  late bool _auto = widget.autoCapture;
  bool _captureQueued = false;
  Duration _lastCapture = -const Duration(days: 1);
  Duration _lastChange = Duration.zero;
  Timer? _settleTimer;
  Timer? _throttleTimer;

  @override
  void initState() {
    super.initState();
    widget.controller?.attach(
      captureOnce: _captureNow,
      startRealtime: () => setState(() => _auto = true),
      stopRealtime: () => setState(() => _auto = false),
    );
    _programs ??= () async {
      return (
        await ui.FragmentProgram.fromAsset(
            'packages/liquid_glass_easy/lib/assets/shaders/liquid_glass.frag'),
        await ui.FragmentProgram.fromAsset(
            'packages/liquid_glass_easy/lib/assets/shaders/liquid_glass_border.frag'),
      );
    }();
    _programs!.then((programs) {
      if (!mounted) return;
      _shader = programs.$1.fragmentShader();
      _borderShader = programs.$2.fragmentShader();
      _captureNow();
    }, onError: (Object e) {
      // e.g. the Skia renderer, which can't compile these shaders: the
      // lenses still show their content, without the glass effect.
      debugPrint('Liquid glass shaders unavailable: $e');
    });
  }

  @override
  void didUpdateWidget(covariant OnDemandLiquidGlassView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoCapture != oldWidget.autoCapture) _auto = widget.autoCapture;
    _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _changed();
  }

  @override
  void dispose() {
    widget.controller?.detach();
    _settleTimer?.cancel();
    _throttleTimer?.cancel();
    _shader?.dispose();
    _borderShader?.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// The background (may have) changed: capture soon, then keep refreshing
  /// slowly until it has been quiet for [_settleTime].
  void _changed() {
    if (!_auto || !mounted) return;
    _lastChange = _clock.elapsed;
    _queueCapture();
    _settleTimer ??= Timer.periodic(_settleInterval, (timer) {
      if (!mounted || _clock.elapsed - _lastChange > _settleTime) {
        timer.cancel();
        _settleTimer = null;
        return;
      }
      _queueCapture();
    });
  }

  void _queueCapture() {
    if (_captureQueued) return;
    _captureQueued = true;
    final wait = _activeInterval - (_clock.elapsed - _lastCapture);
    if (wait > Duration.zero) {
      _throttleTimer = Timer(wait, _captureAfterFrame);
    } else {
      _captureAfterFrame();
    }
  }

  Future<void> _captureAfterFrame() async {
    if (!mounted) return;
    // Capture once the frame that changed the background has been painted.
    await SchedulerBinding.instance.endOfFrame;
    _captureQueued = false;
    await _captureNow();
  }

  Future<void> _captureNow() async {
    if (!mounted || _shader == null) return;
    // Routes covered by an opaque route aren't painted; nothing to capture.
    if (!TickerMode.valuesOf(context).enabled) return;
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.attached) return;
    final ui.Image image;
    try {
      final deviceRatio = MediaQuery.devicePixelRatioOf(context);
      final ratio = widget.pixelRatio <= 0 || widget.pixelRatio > deviceRatio
          ? deviceRatio
          : widget.pixelRatio;
      image = boundary.toImageSync(pixelRatio: ratio);
    } catch (_) {
      // Mid-layout, or a platform view that can't be captured.
      return;
    }
    _lastCapture = _clock.elapsed;
    final old = _image;
    setState(() => _image = image);
    // Pictures already drawn keep their own reference to the old image.
    if (old != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: _buildLayers);
  }

  Widget _buildLayers(BuildContext context, BoxConstraints constraints) {
    final image = _image;
    final laidOut = _boundaryKey.currentContext?.findRenderObject();
    // Before the first layout, size the lenses from the constraints so the
    // bar's content shows on the first frame, glass or not.
    final size = laidOut is RenderBox && laidOut.hasSize
        ? laidOut.size
        : constraints.biggest;
    return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _changed(),
          onPointerUp: (_) => _changed(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _changed();
              return false;
            },
            child: _PaintNotifyingBoundary(
              key: _boundaryKey,
              onPaint: _changed,
              child: widget.backgroundWidget,
            ),
          ),
        ),
        for (final lens in widget.children)
          LiquidGlassWidget(
            config: lens,
            parentSize: size,
            sharedShader: _shader,
            border: _borderShader,
            sharedImage: image,
          ),
      ],
    );
  }
}

/// Repaint boundary that reports each time its own layer is repainted.
class _PaintNotifyingBoundary extends SingleChildRenderObjectWidget {
  const _PaintNotifyingBoundary({
    super.key,
    required this.onPaint,
    super.child,
  });

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintNotifyingBoundary(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaintNotifyingBoundary renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderPaintNotifyingBoundary extends RenderRepaintBoundary {
  _RenderPaintNotifyingBoundary(this.onPaint);

  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    // Only schedules timers and frame callbacks, never builds.
    onPaint();
  }
}
