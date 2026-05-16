import 'package:flutter/material.dart';

/// Appearance tokens for a single brightness (day / night).
class AppColorThemeAppearance {
  const AppColorThemeAppearance({
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.textPrimary,
    required this.textSecondary,
    required this.border,
    required this.glassFill,
    required this.glassBorder,
    this.screenGradient,
  });

  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color textPrimary;
  final Color textSecondary;
  final Color border;
  final Color glassFill;
  final Color glassBorder;

  /// Per-mode screen gradient (overrides [AppColorThemeSpec.screenBackgroundGradient]).
  final List<Color>? screenGradient;

  bool get hasDarkBackground {
    final sample = screenGradient?.first ?? background;
    return sample.computeLuminance() < 0.35;
  }
}

/// Full color theme (palette + day/night appearances).
class AppColorThemeSpec {
  const AppColorThemeSpec({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.neutral,
    required this.accent,
    required this.appBarGradientStart,
    required this.appBarGradientEnd,
    required this.light,
    required this.dark,
    this.screenBackgroundGradient,
  });

  final String id;
  final String name;
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Color neutral;
  final Color accent;
  final Color appBarGradientStart;
  final Color appBarGradientEnd;
  final AppColorThemeAppearance light;
  final AppColorThemeAppearance dark;
  final List<Color>? screenBackgroundGradient;

  List<Color> get paletteSwatches => [
        primary,
        secondary,
        tertiary,
        neutral,
        accent,
      ];

  AppColorThemeAppearance appearanceFor(Brightness brightness) {
    return brightness == Brightness.dark ? dark : light;
  }
}

abstract final class AppColorThemes {
  static const String oceanId = 'ocean';
  static const String coffeeId = 'coffee';

  static const Color coffeePrimary = Color(0xFF42261B);
  static const Color coffeeGradientEnd = Color(0xFF0C1214);

  /// Lightest brand tones — coffee light-mode icons and labels.
  static const Color coffeeLightForeground = Color(0xFFF5E6D3);
  static const Color coffeeLightForegroundMuted = Color(0xCCF5E6D3);

  static const List<Color> coffeeDarkGradient = [
    coffeePrimary,
    coffeeGradientEnd,
  ];

  /// Coffee day mode: softened gradient (lifted from primary + end colors).
  static const List<Color> coffeeLightGradient = [
    Color(0xFF6B4A3C),
    Color(0xFF2E383C),
  ];

  static const AppColorThemeSpec ocean = AppColorThemeSpec(
    id: oceanId,
    name: 'Ocean',
    primary: Color(0xFFBFEAFF),
    secondary: Color(0xFF2789D8),
    tertiary: Color(0xFFFF5A22),
    neutral: Color(0xFFFFFFFF),
    accent: Color(0xFFBFEAFF),
    appBarGradientStart: Color(0xFF3B241C),
    appBarGradientEnd: Color(0xFF965219),
    light: AppColorThemeAppearance(
      background: Color(0xFFE8F6FC),
      surface: Color(0xFF2789D8),
      surfaceVariant: Color(0xFFD4EEF9),
      textPrimary: Color(0xFF171717),
      textSecondary: Color(0xFF3D4F5C),
      border: Color(0xFFFFFFFF),
      glassFill: Color(0x99FFFFFF),
      glassBorder: Color(0x552789D8),
    ),
    dark: AppColorThemeAppearance(
      background: Color(0xFF1C1C1D),
      surface: Color(0xFF2789D8),
      surfaceVariant: Color(0xFF2A3540),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFBFEAFF),
      border: Color(0xFFFFFFFF),
      glassFill: Color(0x662789D8),
      glassBorder: Color(0x4DFFFFFF),
    ),
  );

  static const AppColorThemeSpec coffee = AppColorThemeSpec(
    id: coffeeId,
    name: 'Coffee',
    primary: coffeePrimary,
    secondary: Color(0xFF965219),
    tertiary: Color(0xFFE8A87C),
    neutral: coffeeLightForeground,
    accent: Color(0xFFE8A87C),
    appBarGradientStart: coffeePrimary,
    appBarGradientEnd: coffeeGradientEnd,
    screenBackgroundGradient: coffeeDarkGradient,
    light: AppColorThemeAppearance(
      background: Color(0xFF2E383C),
      surface: Color(0xFF6B4A3C),
      surfaceVariant: Color(0xFF4A352C),
      textPrimary: coffeeLightForeground,
      textSecondary: coffeeLightForegroundMuted,
      border: Color(0x66F5E6D3),
      glassFill: Color(0x1AFFFFFF),
      glassBorder: Color(0x66F5E6D3),
      screenGradient: coffeeLightGradient,
    ),
    dark: AppColorThemeAppearance(
      background: coffeeGradientEnd,
      surface: coffeePrimary,
      surfaceVariant: Color(0xFF1A1412),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: coffeeLightForegroundMuted,
      border: Color(0x4DFFFFFF),
      glassFill: Color(0x1FFFFFFF),
      glassBorder: Color(0x40FFFFFF),
      screenGradient: coffeeDarkGradient,
    ),
  );

  static const List<AppColorThemeSpec> all = [ocean, coffee];

  static AppColorThemeSpec byId(String id) {
    return all.firstWhere(
      (t) => t.id == id,
      orElse: () => ocean,
    );
  }
}
