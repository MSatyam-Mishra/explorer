import 'svg_path_loader_stub.dart'
    if (dart.library.io) 'svg_path_loader_io.dart' as loader;

/// Reads SVG markup from [path] on IO platforms (Android, iOS, desktop).
Future<String> loadSvgFromPath(String path) => loader.loadSvgFromPath(path);
