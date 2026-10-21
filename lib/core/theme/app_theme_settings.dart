import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/shared/file_icons/file_icon_style.dart';
import 'package:flutter/material.dart';

/// User-facing theme configuration (light/dark/system, colours, icons).
class AppThemeSettings {
  const AppThemeSettings({
    required this.themeMode,
    required this.colorThemeId,
    this.fileIconStyle = FileIconStyle.solid,
  });

  final ThemeMode themeMode;
  final String colorThemeId;
  final FileIconStyle fileIconStyle;

  AppColorThemeSpec get colorTheme => AppColorThemes.byId(colorThemeId);

  AppThemeSettings copyWith({
    ThemeMode? themeMode,
    String? colorThemeId,
    FileIconStyle? fileIconStyle,
  }) {
    return AppThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      colorThemeId: colorThemeId ?? this.colorThemeId,
      fileIconStyle: fileIconStyle ?? this.fileIconStyle,
    );
  }

  static AppThemeSettings defaults() => const AppThemeSettings(
        themeMode: ThemeMode.system,
        colorThemeId: AppColorThemes.defaultId,
      );
}
