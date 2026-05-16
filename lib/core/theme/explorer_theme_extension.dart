import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:flutter/material.dart';

/// Extended theme tokens used by glossy surfaces and the app bar.
class ExplorerThemeExtension extends ThemeExtension<ExplorerThemeExtension> {
  const ExplorerThemeExtension({
    required this.colorTheme,
    required this.appearance,
    required this.appBarGradientStart,
    required this.appBarGradientEnd,
    required this.glassBlurSigma,
  });

  final AppColorThemeSpec colorTheme;
  final AppColorThemeAppearance appearance;
  final Color appBarGradientStart;
  final Color appBarGradientEnd;
  final double glassBlurSigma;

  LinearGradient get appBarGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          appBarGradientStart,
          Color.lerp(appBarGradientStart, appBarGradientEnd, 0.55)!,
          appBarGradientEnd.withValues(alpha: 0.35),
          appBarGradientEnd.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.45, 0.78, 1.0],
      );

  @override
  ExplorerThemeExtension copyWith({
    AppColorThemeSpec? colorTheme,
    AppColorThemeAppearance? appearance,
    Color? appBarGradientStart,
    Color? appBarGradientEnd,
    double? glassBlurSigma,
  }) {
    return ExplorerThemeExtension(
      colorTheme: colorTheme ?? this.colorTheme,
      appearance: appearance ?? this.appearance,
      appBarGradientStart: appBarGradientStart ?? this.appBarGradientStart,
      appBarGradientEnd: appBarGradientEnd ?? this.appBarGradientEnd,
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
    );
  }

  @override
  ExplorerThemeExtension lerp(
    ThemeExtension<ExplorerThemeExtension>? other,
    double t,
  ) {
    if (other is! ExplorerThemeExtension) return this;
    return ExplorerThemeExtension(
      colorTheme: t < 0.5 ? colorTheme : other.colorTheme,
      appearance: t < 0.5 ? appearance : other.appearance,
      appBarGradientStart: Color.lerp(
            appBarGradientStart,
            other.appBarGradientStart,
            t,
          ) ??
          appBarGradientStart,
      appBarGradientEnd:
          Color.lerp(appBarGradientEnd, other.appBarGradientEnd, t) ??
              appBarGradientEnd,
      glassBlurSigma: glassBlurSigma + (other.glassBlurSigma - glassBlurSigma) * t,
    );
  }
}

extension ExplorerThemeContext on BuildContext {
  ExplorerThemeExtension get explorerTheme =>
      Theme.of(this).extension<ExplorerThemeExtension>()!;
}
