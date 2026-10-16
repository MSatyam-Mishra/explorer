import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:explorer/features/viewer_pdf/services/pdf_page_rasterizer.dart';
// The platform PDF renderer behind the PDF viewer (PdfRenderer / PDFKit /
// PDFium), used directly so the page is opened from its path (no copy of
// a possibly huge .ai file in memory) and its real size is known.
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';

/// Renders page 1 of a PDF-compatible file (e.g. an Illustrator .ai).
abstract final class DesignPdfRenderer {
  static int _counter = 0;

  /// Page 1 of the PDF at [path], [maxSide] pixels on its long side. Falls
  /// back to the PDF viewer's rasterizer (which needs the bytes and a page
  /// aspect ratio: [fallbackAspect], width / height). Null on failure.
  static Future<ui.Image?> renderFirstPage(
    String path, {
    required int maxSide,
    double? fallbackAspect,
    int maxFallbackBytes = 160 << 20,
  }) async {
    try {
      final image = await _renderFromPath(path, maxSide);
      if (image != null) return image;
    } catch (_) {
      // Try the rasterizer below.
    }
    return _renderWithRasterizer(
      path,
      maxSide,
      fallbackAspect,
      maxFallbackBytes,
    );
  }

  static Future<ui.Image?> _renderFromPath(String path, int maxSide) async {
    final platform = PdfViewerPlatform.instance;
    final id = 'explorer_design_${DateTime.now().microsecondsSinceEpoch}_'
        '${_counter++}';
    final pages = await platform.loadPdfFromFile(path, id);
    if ((int.tryParse(pages ?? '') ?? 0) <= 0) {
      await _close(id);
      return null;
    }
    try {
      final widths = await platform.getPagesWidth(id);
      final heights = await platform.getPagesHeight(id);
      if (widths == null || heights == null) return null;
      if (widths.isEmpty || heights.isEmpty) return null;
      final w = (widths.first as num).toDouble();
      final h = (heights.first as num).toDouble();
      if (w <= 0 || h <= 0) return null;
      final (pw, ph) = _pixelSize(w / h, maxSide);
      final pixels = await platform.getPage(1, pw, ph, id);
      if (pixels == null || pixels.length < pw * ph * 4) return null;
      return _decode(pixels, pw, ph);
    } finally {
      await _close(id);
    }
  }

  static Future<ui.Image?> _renderWithRasterizer(
    String path,
    int maxSide,
    double? aspect,
    int maxBytes,
  ) async {
    if (aspect == null || aspect <= 0) return null;
    final file = File(path);
    if (await file.length() > maxBytes) return null;
    PdfPageRasterizer? rasterizer;
    try {
      rasterizer = await PdfPageRasterizer.open(await file.readAsBytes());
      final (pw, ph) = _pixelSize(aspect, maxSide);
      return await rasterizer.render(1, pw, ph);
    } catch (_) {
      return null;
    } finally {
      await rasterizer?.close();
    }
  }

  static (int, int) _pixelSize(double aspect, int maxSide) {
    if (aspect >= 1) {
      return (maxSide, math.max(1, (maxSide / aspect).round()));
    }
    return (math.max(1, (maxSide * aspect).round()), maxSide);
  }

  static Future<void> _close(String id) async {
    try {
      await PdfViewerPlatform.instance.closeDocument(id);
    } catch (_) {}
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
}
