import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/shared/file_icons/file_icon_style.dart';
import 'package:flutter/material.dart';

/// User-facing theme configuration (light/dark/system, colours, icons).
class AppThemeSettings {
  const AppThemeSettings({
    required this.themeMode,
    required this.colorThemeId,
    this.fileIconStyle = FileIconStyle.solid,
    this.windowEffect = true,
  });

  final ThemeMode themeMode;
  final String colorThemeId;
  final FileIconStyle fileIconStyle;

  /// Translucent window on computers (Acrylic, vibrancy); see WindowEffects.
  final bool windowEffect;

  AppColorThemeSpec get colorTheme => AppColorThemes.byId(colorThemeId);

  AppThemeSettings copyWith({
    ThemeMode? themeMode,
    String? colorThemeId,
    FileIconStyle? fileIconStyle,
    bool? windowEffect,
  }) {
    return AppThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      colorThemeId: colorThemeId ?? this.colorThemeId,
      fileIconStyle: fileIconStyle ?? this.fileIconStyle,
      windowEffect: windowEffect ?? this.windowEffect,
    );
  }

  static AppThemeSettings defaults() => const AppThemeSettings(
        themeMode: ThemeMode.system,
        colorThemeId: AppColorThemes.defaultId,
      );
}
