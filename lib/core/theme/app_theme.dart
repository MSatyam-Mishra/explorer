import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/explorer_theme_extension.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const double iconSize = 20;

  static ThemeData build({
    required AppColorThemeSpec colorTheme,
    required Brightness brightness,
  }) {
    final appearance = colorTheme.appearanceFor(brightness);
    final isDark = brightness == Brightness.dark;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: colorTheme.primary,
      onPrimary: colorTheme.neutral,
      secondary: colorTheme.secondary,
      onSecondary: colorTheme.neutral,
      tertiary: colorTheme.tertiary,
      onTertiary: colorTheme.neutral,
      error: colorTheme.tertiary,
      onError: colorTheme.neutral,
      surface: appearance.surface,
      onSurface: appearance.textPrimary,
      surfaceContainerHighest: appearance.surfaceVariant,
    );

    final base = isDark ? ThemeData.dark() : ThemeData.light();
    final inter = GoogleFonts.interTextTheme(base.textTheme);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor:
          appearance.screenGradient != null ||
                  colorTheme.screenBackgroundGradient != null
              ? Colors.transparent
              : appearance.background,
      textTheme: inter.apply(
        bodyColor: appearance.textPrimary,
        displayColor: appearance.textPrimary,
      ),
      iconTheme: const IconThemeData(size: iconSize),
      primaryIconTheme: const IconThemeData(size: iconSize),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colorTheme.neutral,
        iconTheme: IconThemeData(
          color: colorTheme.neutral,
          size: iconSize,
        ),
        titleTextStyle: inter.titleLarge?.copyWith(
          color: colorTheme.neutral,
          fontWeight: FontWeight.w500,
          fontSize: 18,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: appearance.border.withValues(alpha: 0.25),
        thickness: 0.5,
      ),
      cardTheme: CardThemeData(
        color: appearance.glassFill,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: appearance.glassBorder),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorTheme.neutral,
        foregroundColor: appearance.textPrimary,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      extensions: [
        ExplorerThemeExtension(
          colorTheme: colorTheme,
          appearance: appearance,
          appBarGradientStart: colorTheme.appBarGradientStart,
          appBarGradientEnd: colorTheme.appBarGradientEnd,
          glassBlurSigma: isDark ? 24 : 20,
        ),
      ],
    );
  }

  static ThemeData forSettings(
    AppThemeSettings settings, {
    required Brightness brightness,
  }) {
    return build(colorTheme: settings.colorTheme, brightness: brightness);
  }
}
