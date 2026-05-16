import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:flutter/material.dart';

/// User-facing theme configuration (brightness mode + color palette).
class AppThemeSettings {
  const AppThemeSettings({
    required this.themeMode,
    required this.colorThemeId,
  });

  final ThemeMode themeMode;
  final String colorThemeId;

  AppColorThemeSpec get colorTheme => AppColorThemes.byId(colorThemeId);

  bool get isDark => themeMode == ThemeMode.dark;

  AppThemeSettings copyWith({
    ThemeMode? themeMode,
    String? colorThemeId,
  }) {
    return AppThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      colorThemeId: colorThemeId ?? this.colorThemeId,
    );
  }

  static AppThemeSettings defaults() => const AppThemeSettings(
        themeMode: ThemeMode.dark,
        colorThemeId: AppColorThemes.oceanId,
      );
}
