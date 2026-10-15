import 'package:flutter/material.dart';

/// Light/dark aware colours for the spreadsheet grid.
class GridColors {
  const GridColors({
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

  static final Map<(Brightness, int), GridColors> _cache = {};

  static GridColors of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final key = (theme.brightness, scheme.primary.toARGB32());
    return _cache.putIfAbsent(key, () {
      final dark = theme.brightness == Brightness.dark;
      final accent = scheme.primary;
      final header = dark ? const Color(0xFF2A2C30) : const Color(0xFFF3F4F6);
      return GridColors(
        dark: dark,
        paper: dark ? const Color(0xFF1E1F22) : Colors.white,
        gridLine: dark ? const Color(0xFF3A3C40) : const Color(0xFFE1E3E6),
        header: header,
        headerLine: dark ? const Color(0xFF45484D) : const Color(0xFFD3D6DA),
        headerText: dark ? const Color(0xFFB8BCC2) : const Color(0xFF555A61),
        headerSelected: Color.alphaBlend(accent.withValues(alpha: dark ? 0.22 : 0.14), header),
        headerSelectedStrong: Color.alphaBlend(accent.withValues(alpha: dark ? 0.38 : 0.28), header),
        text: dark ? const Color(0xFFE6E7E9) : const Color(0xFF1F1F1F),
        accent: accent,
        selectionFill: accent.withValues(alpha: dark ? 0.22 : 0.12),
        frozenLine: dark ? const Color(0xFF7A7F87) : const Color(0xFF9AA0A6),
        editorBackground: dark ? const Color(0xFF26282C) : Colors.white,
        editorText: dark ? const Color(0xFFF2F2F2) : const Color(0xFF111111),
      );
    });
  }

  /// Text colour for a cell, keeping it readable on dark paper and fills.
  Color textFor({int? explicit, Color? fill}) {
    if (explicit != null) {
      final c = Color(explicit | 0xFF000000);
      if (fill == null && dark && c.computeLuminance() < 0.08) return text;
      if (fill == null && !dark && c.computeLuminance() > 0.93) return text;
      return c;
    }
    if (fill != null) {
      return fill.computeLuminance() > 0.4 ? const Color(0xFF1F1F1F) : Colors.white;
    }
    return text;
  }
}

/// Palette used by the colour pickers.
const kSheetPalette = <int>[
  0xFF000000, 0xFF434343, 0xFF666666, 0xFF999999, 0xFFCCCCCC, 0xFFEFEFEF, 0xFFFFFFFF, //
  0xFFC00000, 0xFFFF0000, 0xFFFFC000, 0xFFFFFF00, 0xFF92D050, 0xFF00B050, 0xFF00B0F0,
  0xFF0070C0, 0xFF002060, 0xFF7030A0, 0xFFE6B8B7, 0xFFFCD5B4, 0xFFFFF2CC, 0xFFE2EFDA,
  0xFFDDEBF7, 0xFFD9E1F2, 0xFFE4DFEC, 0xFFF4B084, 0xFFA9D08E, 0xFF9BC2E6, 0xFFB4A7D6,
];
