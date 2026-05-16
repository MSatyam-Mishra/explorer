import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/theme_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class ThemeCubit extends Cubit<AppThemeSettings> {
  ThemeCubit() : super(AppThemeSettings.defaults()) {
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final saved = await ThemePreferences.load();
    emit(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final next = state.copyWith(themeMode: mode);
    emit(next);
    await ThemePreferences.save(next);
  }

  Future<void> toggleBrightness() async {
    final nextMode =
        state.themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await setThemeMode(nextMode);
  }

  Future<void> setColorTheme(String colorThemeId) async {
    final next = state.copyWith(colorThemeId: colorThemeId);
    emit(next);
    await ThemePreferences.save(next);
  }
}
