import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

/// Renders page 1 of a PDF-compatible file (e.g. an Illustrator .ai).
abstract final class DesignPdfRenderer {
  /// Page 1 of the PDF at [path], [maxSide] pixels on its long side. The
  /// file is read from disk as needed, not loaded whole. Null on failure.
  ///
  /// [fallbackAspect] and [maxFallbackBytes] are no longer needed and are
  /// ignored.
  static Future<ui.Image?> renderFirstPage(
    String path, {
    required int maxSide,
    double? fallbackAspect,
    int maxFallbackBytes = 160 << 20,
  }) async {
    PdfDocument? document;
    try {
      await pdfrxFlutterInitialize();
      document = await PdfDocument.openFile(path);
      if (document.pages.isEmpty) return null;
      final page = document.pages.first;
      if (page.width <= 0 || page.height <= 0) return null;
      final (pw, ph) = _pixelSize(page.width / page.height, maxSide);
      final rendered = await page.render(
        width: pw,
        height: ph,
        fullWidth: pw.toDouble(),
        fullHeight: ph.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) return null;
      try {
        return await rendered.createImage();
      } finally {
        rendered.dispose();
      }
    } catch (_) {
      return null;
    } finally {
      await document?.dispose();
    }
  }

  static (int, int) _pixelSize(double aspect, int maxSide) {
    if (aspect >= 1) {
      return (maxSide, math.max(1, (maxSide / aspect).round()));
    }
    return (math.max(1, (maxSide * aspect).round()), maxSide);
  }
}
