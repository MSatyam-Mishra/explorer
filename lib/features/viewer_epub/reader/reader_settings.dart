import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderTheme {
  light('Light', Color(0xFFFFFFFF), Color(0xFF1F1F1F), Color(0xFF1A5FB4)),
  sepia('Sepia', Color(0xFFF4ECD8), Color(0xFF5B4636), Color(0xFF8A4B0F)),
  dark('Dark', Color(0xFF1E1F22), Color(0xFFD7D7D7), Color(0xFF8AB4F8)),
  black('Black', Color(0xFF000000), Color(0xFFC4C4C4), Color(0xFF7AA7F0));

  const ReaderTheme(this.label, this.background, this.foreground, this.link);

  final String label;
  final Color background;
  final Color foreground;
  final Color link;

  bool get isDark => this == dark || this == black;
}

enum ReaderFont {
  publisher('Publisher', null),
  serif('Serif', "Georgia, 'Noto Serif', 'Droid Serif', 'Times New Roman', serif"),
  sans('Sans', "system-ui, -apple-system, Roboto, 'Segoe UI', 'Noto Sans', 'Helvetica Neue', Arial, sans-serif"),
  // No dyslexia font is bundled: fall back to a clean sans with extra
  // letter/word spacing (added by the reader CSS).
  dyslexic('Dyslexia-friendly', "'OpenDyslexic', 'Lexend', 'Atkinson Hyperlegible', Verdana, system-ui, Roboto, sans-serif");

  const ReaderFont(this.label, this.cssFamily);

  final String label;
  final String? cssFamily;
}

enum ReaderAlign {
  publisher('Publisher'),
  justify('Justify'),
  left('Left');

  const ReaderAlign(this.label);

  final String label;
}

String _hex(Color c) {
  String two(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// User-adjustable reader appearance; persisted with shared_preferences.
@immutable
class ReaderSettings {
  const ReaderSettings({
    this.theme = ReaderTheme.light,
    this.fontScale = 1.0,
    this.font = ReaderFont.publisher,
    this.lineHeight,
    this.margin = 24,
    this.align = ReaderAlign.publisher,
    this.paginated = true,
    this.spreads = true,
  });

  final ReaderTheme theme;

  /// 0.6 – 2.5, relative to the publisher's size.
  final double fontScale;
  final ReaderFont font;

  /// Null keeps the publisher's line height.
  final double? lineHeight;

  /// Horizontal page margin in CSS px (= logical px).
  final double margin;
  final ReaderAlign align;
  final bool paginated;

  /// Two-page spreads on wide screens / book-posture foldables.
  final bool spreads;

  static const lineHeights = <double?>[null, 1.2, 1.4, 1.6, 1.8, 2.0];
  static const _prefsKey = 'epub_reader_settings_v2';

  ReaderSettings copyWith({
    ReaderTheme? theme,
    double? fontScale,
    ReaderFont? font,
    double? Function()? lineHeight,
    double? margin,
    ReaderAlign? align,
    bool? paginated,
    bool? spreads,
  }) {
    return ReaderSettings(
      theme: theme ?? this.theme,
      fontScale: fontScale ?? this.fontScale,
      font: font ?? this.font,
      lineHeight: lineHeight != null ? lineHeight() : this.lineHeight,
      margin: margin ?? this.margin,
      align: align ?? this.align,
      paginated: paginated ?? this.paginated,
      spreads: spreads ?? this.spreads,
    );
  }

  Map<String, dynamic> toJson() => {
        'theme': theme.name,
        'fontScale': fontScale,
        'font': font.name,
        'lineHeight': lineHeight,
        'margin': margin,
        'align': align.name,
        'paginated': paginated,
        'spreads': spreads,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    double? num_(Object? v) => v is num ? v.toDouble() : null;
    return ReaderSettings(
      theme: _enumByName(ReaderTheme.values, json['theme'], ReaderTheme.light),
      fontScale: (num_(json['fontScale']) ?? 1.0).clamp(0.6, 2.5),
      font: _enumByName(ReaderFont.values, json['font'], ReaderFont.publisher),
      lineHeight: num_(json['lineHeight']),
      margin: (num_(json['margin']) ?? 24).clamp(0, 120),
      align: _enumByName(ReaderAlign.values, json['align'], ReaderAlign.publisher),
      paginated: json['paginated'] is bool ? json['paginated'] as bool : true,
      spreads: json['spreads'] is bool ? json['spreads'] as bool : true,
    );
  }

  /// The settings object understood by the reader JS.
  Map<String, dynamic> toJs() => {
        'theme': theme.name,
        'bg': _hex(theme.background),
        'fg': _hex(theme.foreground),
        'link': _hex(theme.link),
        'rule': theme.isDark ? 'rgba(255,255,255,0.25)' : 'rgba(0,0,0,0.25)',
        'fontScale': fontScale,
        'font': font.name,
        'fontFamily': font.cssFamily,
        'lineHeight': lineHeight,
        'margin': margin,
        'align': align.name,
        'paginated': paginated,
        'spreads': spreads,
      };

  static Future<ReaderSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return const ReaderSettings();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ReaderSettings.fromJson(decoded);
      }
    } catch (_) {
      // Corrupt or unavailable prefs: use defaults.
    }
    return const ReaderSettings();
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(toJson()));
    } catch (_) {
      // Non-fatal.
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderSettings &&
      other.theme == theme &&
      other.fontScale == fontScale &&
      other.font == font &&
      other.lineHeight == lineHeight &&
      other.margin == margin &&
      other.align == align &&
      other.paginated == paginated &&
      other.spreads == spreads;

  @override
  int get hashCode => Object.hash(
      theme, fontScale, font, lineHeight, margin, align, paginated, spreads);
}
