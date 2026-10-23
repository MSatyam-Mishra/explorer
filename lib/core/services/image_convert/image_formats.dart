import 'package:path/path.dart' as p;

/// Image formats files can be converted to.
enum ImageFormat {
  png('PNG', 'png', {'png', 'apng'}),
  jpeg('JPEG', 'jpg', {'jpg', 'jpeg', 'jfif', 'jpe', 'pjpeg'}),
  webp('WebP', 'webp', {'webp'}),
  avif('AVIF', 'avif', {'avif'}),
  heic('HEIC', 'heic', {'heic', 'heif'}),
  tiff('TIFF', 'tiff', {'tif', 'tiff'}),
  bmp('BMP', 'bmp', {'bmp', 'dib'}),
  gif('GIF', 'gif', {'gif'}),
  ico('ICO (icon)', 'ico', {'ico'}),
  tga('TGA', 'tga', {'tga'}),
  svg('SVG', 'svg', {'svg'});

  const ImageFormat(this.label, this.extension, this.extensions);

  final String label;

  /// The extension written.
  final String extension;

  /// Every extension that counts as this format.
  final Set<String> extensions;

  /// The format of [path], by its extension.
  static ImageFormat? of(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    for (final f in values) {
      if (f.extensions.contains(ext)) return f;
    }
    return null;
  }

  /// What [paths] can be converted to: every format but theirs. SVG files
  /// are drawings, not pictures, so they aren't converted from.
  static List<ImageFormat> targetsFor(Iterable<String> paths) {
    final own = {for (final path in paths) ?of(path)};
    return [for (final f in values) if (!own.contains(f)) f];
  }
}

/// Image files this feature takes as input (decodable pictures).
const convertibleExtensions = {
  'png', 'apng', 'jpg', 'jpeg', 'jfif', 'jpe', 'pjpeg', 'webp', 'avif', 'heic', 'heif',
  'tif', 'tiff', 'bmp', 'dib', 'gif', 'ico', 'tga', 'psd', 'exr', 'pnm', 'ppm', 'pgm',
  'pbm', 'qoi', 'cur',
};

bool isConvertibleImage(String path) =>
    convertibleExtensions.contains(p.extension(path).toLowerCase().replaceFirst('.', ''));
