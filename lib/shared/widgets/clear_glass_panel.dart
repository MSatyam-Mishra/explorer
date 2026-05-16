import 'dart:ui';

import 'package:explorer/shared/liquid_glass/explorer_liquid_glass.dart';
import 'package:flutter/material.dart';

/// Physical glass surface: frosted blur + bright rim + lit face gradient.
///
/// Prefer [ExplorerLiquidGlassLayer] / [ExplorerLiquidGlassBottomSheet] for
/// shader-based glass; this panel remains for simple static blur surfaces.
class ClearGlassPanel extends StatelessWidget {
  const ClearGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 32,
    this.margin,
    this.padding,
    this.blurSigma = 28,
    this.rimWidth = 1.5,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final double blurSigma;
  final double rimWidth;

  @override
  Widget build(BuildContext context) {
    final glass = _PhysicalGlassStyle.fromContext(context);
    final radius = BorderRadius.circular(borderRadius);
    final innerRadius = BorderRadius.circular(
      (borderRadius - rimWidth).clamp(0, borderRadius),
    );

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: glass.elevationShadows,
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: glass.rimGradient,
            ),
          ),
          padding: EdgeInsets.all(rimWidth),
          child: ClipRRect(
            borderRadius: innerRadius,
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: glass.faceGradient,
                    stops: glass.faceStops,
                  ),
                ),
                child: Padding(
                  padding: padding ?? EdgeInsets.zero,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhysicalGlassStyle {
  const _PhysicalGlassStyle({
    required this.rimGradient,
    required this.faceGradient,
    required this.faceStops,
    required this.elevationShadows,
  });

  final List<Color> rimGradient;
  final List<Color> faceGradient;
  final List<double> faceStops;
  final List<BoxShadow> elevationShadows;

  factory _PhysicalGlassStyle.fromContext(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDark) {
      return _PhysicalGlassStyle(
        rimGradient: [
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.22),
        ],
        faceGradient: [
          const Color.fromARGB(0, 26, 26, 26),
          const Color.fromARGB(33, 143, 143, 143),
          const Color.fromARGB(80, 160, 160, 160),
        ],
        faceStops: const [0.0, 0.45, 1.0],
        elevationShadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      );
    }

    return _PhysicalGlassStyle(
      rimGradient: [
        const Color.fromARGB(57, 255, 255, 255),
        const Color.fromARGB(146, 255, 255, 255),
        const Color.fromARGB(41, 255, 255, 255),
      ],
      faceGradient: [
        const Color.fromARGB(19, 207, 207, 207),
        const Color.fromARGB(41, 212, 212, 212),
        const Color.fromARGB(0, 187, 187, 187),
      ],
      faceStops: const [0.0, 0.55, 1.0],
      elevationShadows: [
        BoxShadow(
          color: const Color(0xFF2789D8).withValues(alpha: 0.14),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.45),
          blurRadius: 1,
          offset: const Offset(0, 1),
        ),
      ],
    );
  }
}

/// @nodoc — use [ExplorerLiquidGlassForeground].
typedef ClearGlassForeground = ExplorerLiquidGlassForeground;
