import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
// The renderer that backs SfPdfViewer (PdfRenderer/PDFKit/PDFium). Using it
// directly gives page bitmaps for thumbnails and the page canvas editor
// without adding another PDF engine to the app.
// ignore: depend_on_referenced_packages
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';

/// Renders pages of one PDF to [ui.Image]s.
///
/// Requests are serialised (Android's renderer can only open one page at a
/// time) and recent results are kept in a small cache. Call [close] when done.
class PdfPageRasterizer {
  PdfPageRasterizer._(this._documentId, this._tempDir);

  static int _counter = 0;
  static const _cacheSize = 48;

  final String _documentId;
  final Directory _tempDir;
  final LinkedHashMap<String, ui.Image> _cache = LinkedHashMap();
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  bool get isClosed => _closed;

  static Future<PdfPageRasterizer> open(Uint8List bytes) async {
    final id =
        'explorer_pdf_${DateTime.now().microsecondsSinceEpoch}_'
        '${_counter++}';
    final dir = await Directory.systemTemp.createTemp('pdf_pages_');
    final file = File(p.join(dir.path, '$id.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    final pageCount = await PdfViewerPlatform.instance.loadPdfFromFile(
      file.path,
      id,
    );
    if (pageCount == null || (int.tryParse(pageCount) ?? 0) <= 0) {
      await _deleteQuietly(dir);
      throw const FileSystemException(
        'The page renderer could not open the PDF',
      );
    }
    return PdfPageRasterizer._(id, dir);
  }

  /// Renders [pageNumber] (1-based) at [width] x [height] pixels. The caller
  /// owns the returned image and must dispose it. Returns null on failure.
  Future<ui.Image?> render(int pageNumber, int width, int height) {
    final key = '$pageNumber@${width}x$height';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached.clone());
    }

    final completer = Completer<ui.Image?>();
    _queue = _queue.then((_) async {
      if (_closed) return completer.complete(null);
      try {
        final pixels = await PdfViewerPlatform.instance.getPage(
          pageNumber,
          width,
          height,
          _documentId,
        );
        if (pixels == null || _closed) return completer.complete(null);
        final image = await _decode(pixels, width, height);
        if (_closed) {
          image.dispose();
          return completer.complete(null);
        }
        _cache[key] = image;
        while (_cache.length > _cacheSize) {
          _cache.remove(_cache.keys.first)?.dispose();
        }
        completer.complete(image.clone());
      } catch (_) {
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    try {
      await _queue;
      await PdfViewerPlatform.instance.closeDocument(_documentId);
    } catch (_) {
      // The renderer may already have released the document.
    }
    await _deleteQuietly(_tempDir);
  }

  static Future<ui.Image> _decode(Uint8List pixels, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
