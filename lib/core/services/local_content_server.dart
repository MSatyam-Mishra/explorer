import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:explorer/core/files/file_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Resolves a mount-relative path (no leading slash, `/` separated) to bytes,
/// or null for 404.
typedef ContentResolver = FutureOr<Uint8List?> Function(String path);

/// A loopback-only HTTP server that lets WebView-based viewers load local
/// content with working relative URLs (EPUB CSS/images/fonts, glTF `.bin`
/// buffers, OBJ `.mtl` materials and textures, bundled JS libraries...).
///
/// Every URL carries a random per-run token and a random mount id, so other
/// apps on the device can't enumerate files through the port.
///
/// ```dart
/// final server = LocalContentServer.instance;
/// final viewer = await server.mountAssets('assets/viewer3d');
/// final model = await server.mountDirectory(file.parent.path);
/// webView.loadUrl(viewer.resolve('index.html?src=${model.resolve(name)}'));
/// // later, in dispose():
/// server.unmount(model);
/// ```
class LocalContentServer {
  LocalContentServer._();

  static final LocalContentServer instance = LocalContentServer._();

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final String _token = _randomId(24);
  final Map<String, ContentResolver> _mounts = {};

  Future<HttpServer> _ensureStarted() {
    final running = _server;
    if (running != null) return Future.value(running);
    return _starting ??= shelf_io
        .serve(_handle, InternetAddress.loopbackIPv4, 0)
        .then((server) {
      server.autoCompress = true;
      _server = server;
      return server;
    }).whenComplete(() => _starting = null);
  }

  /// Serves files under [rootDir]; requests can't escape the directory.
  Future<Uri> mountDirectory(String rootDir) {
    final root = p.normalize(p.absolute(rootDir));
    return mount((path) async {
      final target = p.normalize(p.join(root, p.joinAll(path.split('/'))));
      if (target != root && !p.isWithin(root, target)) return null;
      final file = File(target);
      return await file.exists() ? file.readAsBytes() : null;
    });
  }

  /// Serves Flutter assets under [assetPrefix] (e.g. `assets/viewer3d`).
  Future<Uri> mountAssets(String assetPrefix) {
    final prefix = assetPrefix.endsWith('/') ? assetPrefix : '$assetPrefix/';
    return mount((path) async {
      try {
        final data = await rootBundle.load('$prefix$path');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        return null;
      }
    });
  }

  /// Serves an in-memory map of files (e.g. an unpacked archive).
  Future<Uri> mountMemory(Map<String, Uint8List> files) =>
      mount((path) => files[path]);

  /// Registers a custom [resolver]; returns the mount's base URL (ending in
  /// `/`). Resolve relative paths against it with [Uri.resolve].
  Future<Uri> mount(ContentResolver resolver) async {
    final server = await _ensureStarted();
    final id = _randomId(12);
    _mounts[id] = resolver;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/$_token/$id/',
    );
  }

  /// Removes a mount created by one of the `mount*` methods.
  void unmount(Uri base) {
    final segments = base.pathSegments;
    if (segments.length >= 2) _mounts.remove(segments[1]);
  }

  Future<Response> _handle(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405);
    }
    final segments = request.url.pathSegments;
    if (segments.length < 3 || segments[0] != _token) {
      return Response.notFound(null);
    }
    final resolver = _mounts[segments[1]];
    if (resolver == null) return Response.notFound(null);

    final path = segments.sublist(2).join('/');
    try {
      final bytes = await resolver(path);
      if (bytes == null) return Response.notFound(null);
      return Response.ok(
        request.method == 'HEAD' ? null : bytes,
        headers: {
          HttpHeaders.contentTypeHeader: _contentType(path),
          HttpHeaders.contentLengthHeader: '${bytes.length}',
          HttpHeaders.cacheControlHeader: 'no-store',
        },
      );
    } catch (e, st) {
      debugPrint('LocalContentServer: $path failed: $e\n$st');
      return Response.internalServerError();
    }
  }

  static String _contentType(String path) {
    final mime = FileTypes.mimeTypeOf(path);
    return mime.startsWith('text/') ||
            mime.endsWith('javascript') ||
            mime.endsWith('+xml')
        ? '$mime; charset=utf-8'
        : mime;
  }

  static String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }
}
