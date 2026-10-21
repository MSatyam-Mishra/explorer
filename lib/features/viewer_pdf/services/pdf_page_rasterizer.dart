import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

/// Renders pages of one PDF to [ui.Image]s (thumbnails, the page canvas
/// editor), with a small cache of recent results. Call [close] when done.
class PdfPageRasterizer {
  PdfPageRasterizer._(this._document);

  static const _cacheSize = 48;

  final PdfDocument _document;
  final LinkedHashMap<String, ui.Image> _cache = LinkedHashMap();
  bool _closed = false;

  bool get isClosed => _closed;

  static Future<PdfPageRasterizer> open(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    if (document.pages.isEmpty) {
      await document.dispose();
      throw const FormatException('The PDF has no pages');
    }
    return PdfPageRasterizer._(document);
  }

  /// Renders [pageNumber] (1-based) at [width] x [height] pixels. The caller
  /// owns the returned image and must dispose it. Returns null on failure.
  Future<ui.Image?> render(int pageNumber, int width, int height) async {
    final key = '$pageNumber@${width}x$height';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached.clone();
    }
    if (_closed || pageNumber < 1 || pageNumber > _document.pages.length) {
      return null;
    }
    try {
      final rendered = await _document.pages[pageNumber - 1].render(
        width: width,
        height: height,
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) return null;
      final ui.Image image;
      try {
        image = await rendered.createImage();
      } finally {
        rendered.dispose();
      }
      if (_closed) {
        image.dispose();
        return null;
      }
      _cache[key] = image;
      while (_cache.length > _cacheSize) {
        _cache.remove(_cache.keys.first)?.dispose();
      }
      return image.clone();
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    await _document.dispose();
  }
}
