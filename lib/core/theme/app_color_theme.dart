import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// One of the shadcn/ui colour schemes the user can pick in Options.
class AppColorThemeSpec {
  const AppColorThemeSpec({required this.id, required this.name});

  /// shadcn/ui scheme name (see [ShadColorScheme.fromName]).
  final String id;
  final String name;

  ShadColorScheme schemeFor(Brightness brightness) =>
      ShadColorScheme.fromName(id, brightness: brightness);

  /// Colour shown in the picker: the accent colour, or for the neutral
  /// schemes (whose primary is black or white) their mid grey.
  Color get swatch => switch (id) {
        'zinc' => const Color(0xFF71717A),
        'slate' => const Color(0xFF64748B),
        'stone' => const Color(0xFF78716C),
        'neutral' => const Color(0xFF737373),
        'gray' => const Color(0xFF6B7280),
        _ => schemeFor(Brightness.light).primary,
      };
}

abstract final class AppColorThemes {
  static const String defaultId = 'blue';

  static const List<AppColorThemeSpec> all = [
    AppColorThemeSpec(id: 'zinc', name: 'Zinc'),
    AppColorThemeSpec(id: 'slate', name: 'Slate'),
    AppColorThemeSpec(id: 'stone', name: 'Stone'),
    AppColorThemeSpec(id: 'neutral', name: 'Neutral'),
    AppColorThemeSpec(id: 'blue', name: 'Blue'),
    AppColorThemeSpec(id: 'violet', name: 'Violet'),
    AppColorThemeSpec(id: 'green', name: 'Green'),
    AppColorThemeSpec(id: 'yellow', name: 'Yellow'),
    AppColorThemeSpec(id: 'orange', name: 'Orange'),
    AppColorThemeSpec(id: 'rose', name: 'Rose'),
    AppColorThemeSpec(id: 'red', name: 'Red'),
  ];

  static AppColorThemeSpec byId(String id) => all.firstWhere(
        (t) => t.id == id,
        orElse: () => all.firstWhere((t) => t.id == defaultId),
      );

  /// A saved id, including ones from older versions ('ocean', 'coffee').
  static String migrate(String? id) => switch (id) {
        'ocean' => 'blue',
        'coffee' => 'orange',
        final String id when all.any((t) => t.id == id) => id,
        _ => defaultId,
      };
}
