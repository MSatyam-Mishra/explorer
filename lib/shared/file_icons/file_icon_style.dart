/// Which of the bundled file icon sets (assets/iocns/file_type) to use.
enum FileIconStyle {
  /// Coloured pages with a white label (icon_1 "Solid").
  solid,

  /// White pages with a coloured label tag (icon_1 "Outline + Color").
  outline,

  /// Classic pages with a type glyph (icon_2), outline style otherwise.
  classic;

  String get label => switch (this) {
        FileIconStyle.solid => 'Solid',
        FileIconStyle.outline => 'Outline',
        FileIconStyle.classic => 'Classic',
      };

  static FileIconStyle parse(String? name) => FileIconStyle.values.firstWhere(
        (s) => s.name == name,
        orElse: () => FileIconStyle.solid,
      );
}
