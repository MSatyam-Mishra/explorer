import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Light/dark aware colours for the spreadsheet grid, from the app's
/// shadcn colour scheme.
class GridColors {
  GridColors({
    required this.dark,
    required this.paper,
    required this.gridLine,
    required this.header,
    required this.headerLine,
    required this.headerText,
    required this.headerSelected,
    required this.headerSelectedStrong,
    required this.text,
    required this.accent,
    required this.selectionFill,
    required this.frozenLine,
    required this.editorBackground,
    required this.editorText,
  });

  final bool dark;
  final Color paper;
  final Color gridLine;
  final Color header;
  final Color headerLine;
  final Color headerText;
  final Color headerSelected;
  final Color headerSelectedStrong;
  final Color text;
  final Color accent;
  final Color selectionFill;
  final Color frozenLine;
  final Color editorBackground;
  final Color editorText;

  /// Resolved colours of explicit (document) text colours, without fill.
  final Map<int, Color> _explicitText = {};

  static final Map<ShadColorScheme, GridColors> _cache = {};

  static GridColors of(BuildContext context) {
    final shad = ShadTheme.of(context);
    final c = shad.colorScheme;
    final dark = shad.brightness == Brightness.dark;
    return _cache.putIfAbsent(c, () {
      final header = c.muted;
      return GridColors(
        dark: dark,
        paper: c.background,
        gridLine: c.border,
        header: header,
        // In dark schemes the border colour equals muted: lift it so the
        // header cells stay separated.
        headerLine: Color.alphaBlend(
          c.foreground.withValues(alpha: dark ? 0.12 : 0.08),
          header,
        ),
        headerText: c.mutedForeground,
        headerSelected: Color.alphaBlend(
          c.primary.withValues(alpha: dark ? 0.22 : 0.14),
          header,
        ),
        headerSelectedStrong: Color.alphaBlend(
          c.primary.withValues(alpha: dark ? 0.38 : 0.28),
          header,
        ),
        text: c.foreground,
        accent: c.primary,
        selectionFill: c.primary.withValues(alpha: dark ? 0.22 : 0.12),
        frozenLine: c.mutedForeground.withValues(alpha: 0.7),
        editorBackground: c.background,
        editorText: c.foreground,
      );
    });
  }

  /// Text colour for a cell, keeping it readable on dark paper and fills.
  ///
  /// The document's own colours are kept where they read well. Colours
  /// chosen for white paper that would vanish on a dark sheet (black, navy,
  /// dark red…) are lifted to a lighter shade of the same hue.
  Color textFor({int? explicit, Color? fill}) {
    if (explicit != null) {
      final c = Color(explicit | 0xFF000000);
      if (fill != null) return c;
      return _explicitText.putIfAbsent(explicit, () {
        final contrast = _contrast(c, paper);
        if (dark && contrast < 4.5) return _lifted(c);
        if (!dark && contrast < 1.3) return text;
        return c;
      });
    }
    if (fill != null) {
      return fill.computeLuminance() > 0.4
          ? const Color(0xFF1F1F1F)
          : Colors.white;
    }
    return text;
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance() + 0.05;
    final lb = b.computeLuminance() + 0.05;
    return la > lb ? la / lb : lb / la;
  }

  /// [c] made light enough for dark paper; near-greys become the text colour.
  Color _lifted(Color c) {
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.15) return text;
    for (var l = hsl.lightness.clamp(0.5, 0.95); l <= 0.95; l += 0.05) {
      final candidate = hsl.withLightness(l).toColor();
      if (_contrast(candidate, paper) >= 4.5) return candidate;
    }
    return hsl.withLightness(0.85).toColor();
  }
}

/// Palette used by the colour pickers.
const kSheetPalette = <int>[
  0xFF000000, 0xFF434343, 0xFF666666, 0xFF999999, 0xFFCCCCCC, 0xFFEFEFEF, 0xFFFFFFFF, //
  0xFFC00000, 0xFFFF0000, 0xFFFFC000, 0xFFFFFF00, 0xFF92D050, 0xFF00B050, 0xFF00B0F0,
  0xFF0070C0, 0xFF002060, 0xFF7030A0, 0xFFE6B8B7, 0xFFFCD5B4, 0xFFFFF2CC, 0xFFE2EFDA,
  0xFFDDEBF7, 0xFFD9E1F2, 0xFFE4DFEC, 0xFFF4B084, 0xFFA9D08E, 0xFF9BC2E6, 0xFFB4A7D6,
];
