import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/explorer_theme_extension.dart';
import 'package:explorer/shared/liquid_glass/on_demand_liquid_glass_view.dart';
import 'package:explorer/shared/widgets/explorer_screen_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// Central liquid-glass presets and reusable lens/sheet/scaffold widgets.
abstract final class ExplorerLiquidGlass {
  ExplorerLiquidGlass._();

  static const double defaultPixelRatio = 0.85;
  static const double defaultCornerRadius = 34;

  /// Theme-aware lens tuning — clear, low tint, minimal distortion.
  static ExplorerLiquidGlassStyle styleOf(BuildContext context) {
    final appearance = context.explorerTheme.appearance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ExplorerLiquidGlassStyle.forAppearance(appearance, isDark: isDark);
  }

  static LiquidGlass buildLens({
    required BuildContext context,
    required double width,
    required double height,
    required LiquidGlassPosition position,
    required Widget child,
    double cornerRadius = defaultCornerRadius,
    ExplorerLiquidGlassStyle? style,
  }) {
    final s = style ?? styleOf(context);
    return LiquidGlass(
      width: width,
      height: height,
      position: position,
      magnification: s.magnification,
      distortion: s.distortion,
      distortionWidth: s.distortionWidth,
      chromaticAberration: s.chromaticAberration,
      enableInnerRadiusTransparent: s.enableInnerRadiusTransparent,
      refractionMode: LiquidGlassRefractionMode.shapeRefraction,
      color: s.tint,
      blur: s.blur,
      shape: s.shapeFor(cornerRadius),
      child: child,
    );
  }
}

/// Resolved shader + border settings for one frame.
class ExplorerLiquidGlassStyle {
  const ExplorerLiquidGlassStyle({
    required this.distortion,
    required this.distortionWidth,
    required this.blur,
    required this.tint,
    required this.shape,
    this.magnification = 1.0,
    this.chromaticAberration = 0.0,
    this.enableInnerRadiusTransparent = false,
    this.pixelRatio = ExplorerLiquidGlass.defaultPixelRatio,
  });

  final double distortion;
  final double distortionWidth;
  final LiquidGlassBlur blur;
  final Color tint;
  final RoundedRectangleShape shape;
  final double magnification;
  final double chromaticAberration;
  final bool enableInnerRadiusTransparent;
  final double pixelRatio;

  RoundedRectangleShape shapeFor(double cornerRadius) {
    return RoundedRectangleShape(
      cornerRadius: cornerRadius,
      borderWidth: shape.borderWidth,
      borderSoftness: shape.borderSoftness,
      lightColor: shape.lightColor,
      shadowColor: shape.shadowColor,
      lightDirection: shape.lightDirection,
      oneSideLightIntensity: shape.oneSideLightIntensity,
      lightIntensity: shape.lightIntensity,
      lightMode: shape.lightMode,
    );
  }

  factory ExplorerLiquidGlassStyle.forAppearance(
    AppColorThemeAppearance appearance, {
    required bool isDark,
  }) {
    final onDarkBg = appearance.hasDarkBackground;

    if (onDarkBg) {
      return ExplorerLiquidGlassStyle(
        distortion: 0.03,
        distortionWidth: 16,
        blur: const LiquidGlassBlur(sigmaX: 2, sigmaY: 2),
        tint: appearance.glassFill.withValues(alpha: 0.12),
        shape: RoundedRectangleShape(
          cornerRadius: ExplorerLiquidGlass.defaultCornerRadius,
          borderWidth: 1.1,
          borderSoftness: 0.75,
          lightColor: appearance.glassBorder.withValues(alpha: 0.7),
          shadowColor: Colors.white.withValues(alpha: 0.08),
          lightDirection: 135,
          oneSideLightIntensity: 0,
          lightIntensity: 0.9,
        ),
      );
    }

    if (isDark) {
      return ExplorerLiquidGlassStyle(
        distortion: 0.04,
        distortionWidth: 18,
        blur: const LiquidGlassBlur(sigmaX: 3, sigmaY: 3),
        tint: Colors.white.withValues(alpha: 0.06),
        shape: RoundedRectangleShape(
          cornerRadius: ExplorerLiquidGlass.defaultCornerRadius,
          borderWidth: 1.2,
          borderSoftness: 0.8,
          lightColor: Colors.white.withValues(alpha: 0.75),
          shadowColor: Colors.white.withValues(alpha: 0.1),
          lightDirection: 135,
          oneSideLightIntensity: 0,
          lightIntensity: 0.95,
        ),
      );
    }

    return ExplorerLiquidGlassStyle(
      distortion: 0.03,
      distortionWidth: 16,
      blur: const LiquidGlassBlur(sigmaX: 1.5, sigmaY: 1.5),
      tint: appearance.glassFill.withValues(alpha: 0.1),
      shape: RoundedRectangleShape(
        cornerRadius: ExplorerLiquidGlass.defaultCornerRadius,
        borderWidth: 1.2,
        borderSoftness: 0.7,
        lightColor: Colors.white.withValues(alpha: 0.85),
        shadowColor: Colors.white.withValues(alpha: 0.18),
        lightDirection: 135,
        oneSideLightIntensity: 0,
        lightIntensity: 0.92,
      ),
    );
  }
}

/// Text and icon colors on top of any liquid-glass lens.
abstract final class ExplorerLiquidGlassForeground {
  static Color icon(BuildContext context) {
    return context.explorerTheme.appearance.textPrimary.withValues(alpha: 0.94);
  }

  static Color primaryText(BuildContext context) => icon(context);

  static TextStyle title(BuildContext context) {
    return Theme.of(context).textTheme.titleMedium?.copyWith(
          color: primaryText(context),
          fontWeight: FontWeight.w600,
          fontSize: 16,
          letterSpacing: -0.2,
        ) ??
        TextStyle(
          color: primaryText(context),
          fontWeight: FontWeight.w600,
          fontSize: 16,
          letterSpacing: -0.2,
        );
  }
}

/// Full-screen capture host with one or more lenses.
class ExplorerLiquidGlassLayer extends StatelessWidget {
  const ExplorerLiquidGlassLayer({
    super.key,
    required this.background,
    required this.lenses,
    this.controller,
    this.pixelRatio,
    this.realTimeCapture = true,
  });

  final Widget background;
  final List<LiquidGlass> lenses;
  final LiquidGlassViewController? controller;
  final double? pixelRatio;
  final bool realTimeCapture;

  @override
  Widget build(BuildContext context) {
    final style = ExplorerLiquidGlass.styleOf(context);
    return OnDemandLiquidGlassView(
      controller: controller,
      pixelRatio: pixelRatio ?? style.pixelRatio,
      autoCapture: realTimeCapture,
      backgroundWidget: background,
      children: lenses,
    );
  }
}

/// Page shell: scrolling body + docked liquid-glass top bar lens.
class ExplorerLiquidGlassTopBarScaffold extends StatefulWidget {
  /// Scroll padding so the first list row clears the docked bar lens.
  static double contentTopInset(
    BuildContext context, {
    EdgeInsets barMargin = const EdgeInsets.fromLTRB(16, 12, 16, 12),
    double barHeight = 54,
  }) {
    return MediaQuery.paddingOf(context).top +
        barMargin.top +
        barHeight +
        barMargin.bottom;
  }

  const ExplorerLiquidGlassTopBarScaffold({
    super.key,
    required this.topBarBuilder,
    required this.body,
    this.drawer,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.barMargin = const EdgeInsets.fromLTRB(16, 12, 16, 12),
    this.barHeight = 54,
    this.barRadius = ExplorerLiquidGlass.defaultCornerRadius,
    this.backgroundColor,
    this.pixelRatio,
  });

  final Widget Function(BuildContext scaffoldContext) topBarBuilder;
  final Widget body;
  final Widget? drawer;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final EdgeInsets barMargin;
  final double barHeight;
  final double barRadius;
  final Color? backgroundColor;
  final double? pixelRatio;

  @override
  State<ExplorerLiquidGlassTopBarScaffold> createState() =>
      _ExplorerLiquidGlassTopBarScaffoldState();
}

class _ExplorerLiquidGlassTopBarScaffoldState
    extends State<ExplorerLiquidGlassTopBarScaffold> {
  final LiquidGlassViewController _viewController = LiquidGlassViewController();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = ExplorerLiquidGlass.styleOf(context);
    final lensWidth =
        media.size.width - widget.barMargin.left - widget.barMargin.right;
    final lensTop = topInset + widget.barMargin.top;

    final overlayStyle =
        isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: widget.backgroundColor ?? Colors.transparent,
        drawer: widget.drawer,
        body: ExplorerLiquidGlassLayer(
          controller: _viewController,
          pixelRatio: widget.pixelRatio,
          background: ExplorerScreenBackground(child: widget.body),
          lenses: [
            ExplorerLiquidGlass.buildLens(
              context: context,
              width: lensWidth,
              height: widget.barHeight,
              style: style,
              cornerRadius: widget.barRadius,
              position: LiquidGlassOffsetPosition(
                left: widget.barMargin.left,
                top: lensTop,
              ),
              child: Builder(builder: widget.topBarBuilder),
            ),
          ],
        ),
        floatingActionButton: widget.floatingActionButton,
        floatingActionButtonLocation: widget.floatingActionButtonLocation,
      ),
    );
  }
}

/// Modal bottom sheet with a bottom-aligned liquid-glass panel.
class ExplorerLiquidGlassBottomSheet extends StatelessWidget {
  const ExplorerLiquidGlassBottomSheet({
    super.key,
    required this.child,
    this.maxHeightFraction = 0.78,
    this.horizontalMargin = 16,
    this.bottomMargin = 16,
    this.cornerRadius = 28,
  });

  final Widget child;
  final double maxHeightFraction;
  final double horizontalMargin;
  final double bottomMargin;
  final double cornerRadius;

  static Future<T?> show<T>(
    BuildContext context, {
    required Widget child,
    double maxHeightFraction = 0.78,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => ExplorerLiquidGlassBottomSheet(
        maxHeightFraction: maxHeightFraction,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final style = ExplorerLiquidGlass.styleOf(context);
    final lensWidth = media.size.width - horizontalMargin * 2;
    final maxLensHeight = media.size.height * maxHeightFraction;
    final bottom = bottomMargin + media.viewInsets.bottom;

    return SizedBox(
      height: media.size.height,
      width: media.size.width,
      child: ExplorerLiquidGlassLayer(
        pixelRatio: style.pixelRatio,
        background: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          behavior: HitTestBehavior.opaque,
          child: const SizedBox.expand(),
        ),
        lenses: [
          ExplorerLiquidGlass.buildLens(
            context: context,
            width: lensWidth,
            height: maxLensHeight,
            style: style,
            cornerRadius: cornerRadius,
            position: LiquidGlassOffsetPosition(
              left: horizontalMargin,
              bottom: bottom,
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                _SheetHandle(
                  color: ExplorerLiquidGlassForeground.icon(context),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

/// Side drawer filled with one liquid-glass lens over the route behind it.
class ExplorerLiquidGlassDrawer extends StatelessWidget {
  const ExplorerLiquidGlassDrawer({
    super.key,
    required this.child,
    this.width,
  });

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: width,
      backgroundColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ExplorerLiquidGlassLayer(
            background: const SizedBox.expand(),
            lenses: [
              ExplorerLiquidGlass.buildLens(
                context: context,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                cornerRadius: 0,
                position: const LiquidGlassOffsetPosition(left: 0, top: 0),
                child: SafeArea(child: child),
              ),
            ],
          );
        },
      ),
    );
  }
}
