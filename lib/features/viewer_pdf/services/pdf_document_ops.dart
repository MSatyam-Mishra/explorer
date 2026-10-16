import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:explorer/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:explorer/features/viewer_pdf/services/pdf_page_tree.dart';
import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Structural PDF edits built on syncfusion_flutter_pdf.
///
/// Every operation takes the current document bytes and returns new bytes.
/// The work runs on a background isolate so large documents don't freeze the
/// UI. Each method is static and only captures plain data, which keeps the
/// isolate closures sendable.
abstract final class PdfDocumentOps {
  static const _encryptedMessage = 'Cannot open an encrypted document';

  /// Checks whether [bytes] can be opened, optionally with [password].
  static Future<PdfProbeResult> probe(Uint8List bytes, {String? password}) =>
      Isolate.run(() => _probe(bytes, password));

  /// Removes the open password so the viewer and the editors can work on a
  /// plain copy. The password is re-applied with [encrypt] when saving.
  static Future<Uint8List> decrypt(Uint8List bytes, String password) =>
      Isolate.run(() => _decrypt(bytes, password));

  /// Protects the document with [password] (AES-256), used both as the open
  /// password and the permissions password.
  static Future<Uint8List> encrypt(Uint8List bytes, String password) =>
      Isolate.run(() => _encrypt(bytes, password));

  static Future<List<PdfPageMeta>> pageMetas(Uint8List bytes) =>
      Isolate.run(() => _pageMetas(bytes));

  /// Rotates the pages at [indices] by [quarterTurns] clockwise.
  static Future<Uint8List> rotatePages(
    Uint8List bytes,
    Set<int> indices,
    int quarterTurns,
  ) => Isolate.run(
    () => _edit(bytes, (doc) {
      final pages = [for (final i in indices) doc.pages[i]];
      for (final page in pages) {
        _rotate(page, quarterTurns);
      }
    }),
  );

  static Future<Uint8List> deletePages(Uint8List bytes, Set<int> indices) =>
      Isolate.run(
        () => _edit(bytes, (doc) {
          final sorted = indices.toList()..sort((a, b) => b.compareTo(a));
          if (sorted.length >= doc.pages.count) {
            throw StateError('A PDF needs at least one page');
          }
          for (final i in sorted) {
            doc.pages.removeAt(i);
          }
        }),
      );

  /// Inserts a blank page at [index], sized like its neighbour.
  static Future<Uint8List> insertBlankPage(Uint8List bytes, int index) =>
      Isolate.run(
        () => _edit(bytes, (doc) {
          final count = doc.pages.count;
          final at = index.clamp(0, count);
          final reference = count == 0
              ? null
              : doc.pages[math.min(at, count - 1)];
          final size = reference == null
              ? PdfPageSize.a4
              : _metaOf(reference).displaySize;
          doc.pages.insert(at, size, _noMargins());
        }),
      );

  /// Applies a page-manager plan (reorder, rotate, delete and insert blank
  /// pages) in one pass.
  static Future<Uint8List> applyPagePlan(
    Uint8List bytes,
    List<PagePlanEntry> plan,
  ) => Isolate.run(() => _applyPagePlan(bytes, plan));

  /// Returns a new PDF made of the pages at [indices] (kept in document
  /// order), with their annotations and links.
  static Future<Uint8List> extractPages(Uint8List bytes, Set<int> indices) =>
      Isolate.run(
        () => _edit(bytes, (doc) {
          final count = doc.pages.count;
          for (var i = count - 1; i >= 0; i--) {
            if (!indices.contains(i)) doc.pages.removeAt(i);
          }
        }),
      );

  /// Inserts the pages of [other] at [index] (end of document when null).
  ///
  /// Pages are copied as their visual content; annotations and form fields
  /// of [other] are not carried over.
  static Future<Uint8List> insertPdf(
    Uint8List bytes,
    Uint8List other, {
    String? otherPassword,
    int? index,
  }) => Isolate.run(() => _insertPdf(bytes, other, otherPassword, index));

  /// Draws [marks] permanently onto the page at [pageIndex].
  static Future<Uint8List> drawOnPage(
    Uint8List bytes,
    int pageIndex,
    List<PageMark> marks,
  ) => Isolate.run(() => _drawOnPage(bytes, pageIndex, marks));

  /// Whether [drawOnPage] can write [text] as real PDF text: Latin-1 with the
  /// standard font, or Latin, Greek and Cyrillic when a system TrueType font
  /// is available. Other scripts and emoji have to be placed as an image.
  static bool canEmbedText(String text) {
    var latin1 = true;
    for (final rune in text.runes) {
      if (rune <= 0xFF) continue;
      latin1 = false;
      if (!_coveredBySystemFont(rune)) return false;
    }
    return latin1 || _systemFontPath() != null;
  }

  /// Bytes to embed for an image picked on the page canvas.
  ///
  /// PNG files and upright JPEGs are kept as they are. Anything else (HEIC,
  /// AVIF, WebP, camera JPEGs with an EXIF rotation...) is re-encoded from
  /// [decoded], which the platform decoder already turned the right way up;
  /// PDF ignores EXIF orientation and the PDF library can't read those
  /// formats.
  static Future<Uint8List> imageForPdf(Uint8List bytes, Image decoded) async {
    final isJpeg = _isJpeg(bytes);
    if (_isPng(bytes) || (isJpeg && _jpegOrientation(bytes) <= 1)) {
      return bytes;
    }
    const maxSide = 2400;
    final longest = math.max(decoded.width, decoded.height);
    Image? scaled;
    if (longest > maxSide) {
      final k = maxSide / longest;
      final width = math.max(1, (decoded.width * k).round());
      final height = math.max(1, (decoded.height * k).round());
      final recorder = PictureRecorder();
      Canvas(recorder).drawImageRect(
        decoded,
        Rect.fromLTWH(0, 0, decoded.width.toDouble(), decoded.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      scaled = await picture.toImage(width, height);
      picture.dispose();
    }
    try {
      final source = scaled ?? decoded;
      final data = await source.toByteData(
        format: ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw const FormatException('Unsupported image');
      final rgba = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final width = source.width;
      final height = source.height;
      return await Isolate.run(() => _encodeRgba(rgba, width, height));
    } finally {
      scaled?.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Isolate entry points. Keep these top-level so closures stay sendable.
// ---------------------------------------------------------------------------

PdfProbeResult _probe(Uint8List bytes, String? password) {
  PdfDocument? doc;
  try {
    doc = PdfDocument(inputBytes: bytes, password: password);
    return PdfProbeResult(PdfOpenStatus.ok, pageCount: doc.pages.count);
  } catch (e) {
    final message = e.toString();
    if (message.contains(PdfDocumentOps._encryptedMessage)) {
      return const PdfProbeResult(PdfOpenStatus.needsPassword);
    }
    return PdfProbeResult(PdfOpenStatus.invalid, message: message);
  } finally {
    doc?.dispose();
  }
}

Uint8List _decrypt(Uint8List bytes, String password) {
  final doc = PdfDocument(inputBytes: bytes, password: password);
  try {
    doc.fileStructure.incrementalUpdate = false;
    doc.security.userPassword = '';
    doc.security.ownerPassword = '';
    return doc.saveAsBytesSync();
  } finally {
    doc.dispose();
  }
}

Uint8List _encrypt(Uint8List bytes, String password) {
  final doc = PdfDocument(inputBytes: bytes);
  try {
    doc.fileStructure.incrementalUpdate = false;
    final security = doc.security;
    security.algorithm = PdfEncryptionAlgorithm.aesx256Bit;
    security.userPassword = password;
    security.ownerPassword = password;
    return doc.saveAsBytesSync();
  } finally {
    doc.dispose();
  }
}

List<PdfPageMeta> _pageMetas(Uint8List bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  try {
    return [for (var i = 0; i < doc.pages.count; i++) _metaOf(doc.pages[i])];
  } finally {
    doc.dispose();
  }
}

PdfPageMeta _metaOf(PdfPage page) {
  final size = page.size;
  return PdfPageMeta(
    width: size.width,
    height: size.height,
    rotation: page.rotation.index * 90,
  );
}

Uint8List _edit(Uint8List bytes, void Function(PdfDocument doc) change) {
  final doc = PdfDocument(inputBytes: bytes);
  try {
    // A full rewrite drops removed content instead of appending to the file.
    doc.fileStructure.incrementalUpdate = false;
    change(doc);
    return doc.saveAsBytesSync();
  } finally {
    doc.dispose();
  }
}

PdfMargins _noMargins() => PdfMargins()..all = 0;

void _rotate(PdfPage page, int quarterTurns) {
  final turns = ((page.rotation.index + quarterTurns) % 4 + 4) % 4;
  page.rotation = PdfPageRotateAngle.values[turns];
}

Uint8List _applyPagePlan(Uint8List bytes, List<PagePlanEntry> plan) {
  if (plan.isEmpty) throw StateError('A PDF needs at least one page');

  var current = _edit(bytes, (doc) {
    final count = doc.pages.count;
    final pages = [for (var i = 0; i < count; i++) doc.pages[i]];

    for (final entry in plan) {
      if (!entry.isBlank && entry.quarterTurns % 4 != 0) {
        _rotate(pages[entry.sourceIndex!], entry.quarterTurns);
      }
    }

    final order = [
      for (final entry in plan)
        if (!entry.isBlank) entry.sourceIndex!,
    ];
    final kept = order.toSet();
    if (kept.length != order.length) {
      throw StateError('A page appears twice in the plan');
    }
    for (var i = count - 1; i >= 0; i--) {
      if (!kept.contains(i)) doc.pages.remove(pages[i]);
    }

    final ascending = order.toList()..sort();
    var reordered = false;
    for (var i = 0; i < order.length; i++) {
      if (order[i] != ascending[i]) {
        reordered = true;
        break;
      }
    }
    if (reordered) {
      reorderPdfPages(doc, [for (final i in order) pages[i]]);
    }
  });

  // Blank pages go in after a save/reload, so the page tree caches are fresh.
  final blanks = <int, Size>{
    for (var i = 0; i < plan.length; i++)
      if (plan[i].isBlank) i: plan[i].blankSize!,
  };
  if (blanks.isNotEmpty) {
    current = _edit(current, (doc) {
      final positions = blanks.keys.toList()..sort();
      for (final at in positions) {
        doc.pages.insert(
          math.min(at, doc.pages.count),
          blanks[at]!,
          _noMargins(),
        );
      }
    });
  }
  return current;
}

Uint8List _insertPdf(
  Uint8List bytes,
  Uint8List otherBytes,
  String? otherPassword,
  int? index,
) {
  final other = PdfDocument(inputBytes: otherBytes, password: otherPassword);
  try {
    return _edit(bytes, (doc) {
      var at = (index ?? doc.pages.count).clamp(0, doc.pages.count);
      for (var i = 0; i < other.pages.count; i++) {
        final source = other.pages[i];
        final meta = _metaOf(source);
        final template = source.createTemplate();
        final page = doc.pages.insert(at++, meta.displaySize, _noMargins());
        final graphics = page.graphics;
        final state = graphics.save();
        // Draw the unrotated content turned to match how the source page
        // displays, so the copy needs no /Rotate of its own.
        switch (meta.rotation) {
          case 90:
            graphics.translateTransform(meta.height, 0);
            graphics.rotateTransform(90);
          case 180:
            graphics.translateTransform(meta.width, meta.height);
            graphics.rotateTransform(180);
          case 270:
            graphics.translateTransform(0, meta.width);
            graphics.rotateTransform(270);
        }
        graphics.drawPdfTemplate(
          template,
          Offset.zero,
          Size(meta.width, meta.height),
        );
        graphics.restore(state);
      }
    });
  } finally {
    other.dispose();
  }
}

Uint8List _drawOnPage(Uint8List bytes, int pageIndex, List<PageMark> marks) {
  return _edit(bytes, (doc) {
    final page = doc.pages[pageIndex];
    final meta = _metaOf(page);
    final graphics = page.graphics;
    final state = graphics.save();
    // Marks are in display coordinates; map them onto the unrotated page.
    switch (meta.rotation) {
      case 90:
        graphics.translateTransform(0, meta.height);
        graphics.rotateTransform(-90);
      case 180:
        graphics.translateTransform(meta.width, meta.height);
        graphics.rotateTransform(-180);
      case 270:
        graphics.translateTransform(meta.width, 0);
        graphics.rotateTransform(-270);
    }
    for (final mark in marks) {
      switch (mark) {
        case InkMark():
          _drawInk(graphics, mark);
        case TextMark():
          _drawText(graphics, mark);
        case ImageMark():
          _drawImage(graphics, mark);
      }
    }
    graphics.restore(state);
  });
}

PdfColor _pdfColor(Color color) => PdfColor(
  (color.r * 255).round(),
  (color.g * 255).round(),
  (color.b * 255).round(),
);

void _drawInk(PdfGraphics graphics, InkMark mark) {
  if (mark.points.isEmpty) return;
  final transparent = mark.opacity < 1 || mark.color.a < 1;
  final state = transparent ? graphics.save() : null;
  if (transparent) {
    graphics.setTransparency((mark.opacity * mark.color.a).clamp(0.05, 1));
  }
  final color = _pdfColor(mark.color);
  if (mark.points.length == 1) {
    final p = mark.points.first;
    graphics.drawEllipse(
      Rect.fromCircle(center: p, radius: mark.width / 2),
      brush: PdfSolidBrush(color),
    );
  } else {
    final path = PdfPath();
    for (var i = 1; i < mark.points.length; i++) {
      path.addLine(mark.points[i - 1], mark.points[i]);
    }
    graphics.drawPath(
      path,
      pen: PdfPen(
        color,
        width: mark.width,
        lineCap: PdfLineCap.round,
        lineJoin: PdfLineJoin.round,
      ),
    );
  }
  if (state != null) graphics.restore(state);
}

void _drawText(PdfGraphics graphics, TextMark mark) {
  if (mark.text.trim().isEmpty) return;
  final font = _fontFor(mark.text, mark.fontSize);
  final brush = PdfSolidBrush(_pdfColor(mark.color));
  final lineHeight = font.height;
  var y = mark.position.dy;
  for (final line in mark.text.split('\n')) {
    if (line.isNotEmpty) {
      final size = font.measureString(line);
      graphics.drawString(
        line,
        font,
        brush: brush,
        bounds: Rect.fromLTWH(
          mark.position.dx,
          y,
          size.width + 2,
          math.max(size.height, lineHeight),
        ),
      );
    }
    y += lineHeight;
  }
}

/// Helvetica covers Latin-1. Anything else needs an embedded TrueType font,
/// taken from the platform's system fonts when one can be read. Callers
/// check [PdfDocumentOps.canEmbedText] first: Helvetica throws on characters
/// it doesn't have.
PdfFont _fontFor(String text, double size) {
  final latin1 = text.runes.every((r) => r <= 0xFF);
  if (!latin1) {
    final path = _systemFontPath();
    if (path != null) {
      try {
        return PdfTrueTypeFont(File(path).readAsBytesSync(), size);
      } catch (_) {
        // Fall back to Helvetica below.
      }
    }
  }
  return PdfStandardFont(PdfFontFamily.helvetica, size);
}

/// Ranges the [_systemFontCandidates] all cover beyond Latin-1: Latin
/// Extended, Greek, Cyrillic, Vietnamese, punctuation and currency signs.
bool _coveredBySystemFont(int rune) =>
    (rune >= 0x0100 && rune <= 0x024F) ||
    (rune >= 0x0370 && rune <= 0x03FF) ||
    (rune >= 0x0400 && rune <= 0x04FF) ||
    (rune >= 0x1E00 && rune <= 0x1EFF) ||
    (rune >= 0x2010 && rune <= 0x205E) ||
    (rune >= 0x20A0 && rune <= 0x20BF) ||
    rune == 0x2116 ||
    rune == 0x2122;

String? _cachedSystemFontPath;
bool _systemFontLooked = false;

/// First readable system font of [_systemFontCandidates], or null (always on
/// iOS, where system fonts can't be read).
String? _systemFontPath() {
  if (!_systemFontLooked) {
    _systemFontLooked = true;
    for (final path in _systemFontCandidates()) {
      try {
        if (File(path).existsSync()) {
          _cachedSystemFontPath = path;
          break;
        }
      } catch (_) {
        // Try the next candidate.
      }
    }
  }
  return _cachedSystemFontPath;
}

List<String> _systemFontCandidates() {
  if (Platform.isAndroid) {
    return const [
      '/system/fonts/Roboto-Regular.ttf',
      '/system/fonts/NotoSans-Regular.ttf',
      '/system/fonts/DroidSans.ttf',
    ];
  }
  if (Platform.isWindows) {
    final root = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return ['$root\\Fonts\\arial.ttf', '$root\\Fonts\\segoeui.ttf'];
  }
  if (Platform.isMacOS) {
    return const [
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      '/System/Library/Fonts/Supplemental/Arial.ttf',
      '/Library/Fonts/Arial Unicode.ttf',
    ];
  }
  if (Platform.isLinux) {
    return const [
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
      '/usr/share/fonts/TTF/DejaVuSans.ttf',
    ];
  }
  return const [];
}

void _drawImage(PdfGraphics graphics, ImageMark mark) {
  final encoded = _pdfFriendlyImage(mark.bytes);
  graphics.drawImage(PdfBitmap(encoded), mark.rect);
}

bool _isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

bool _isJpeg(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// EXIF orientation of a JPEG (1 = upright), or 1 when there is none.
int _jpegOrientation(Uint8List bytes) {
  try {
    return img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1;
  } catch (_) {
    return 1;
  }
}

/// Straight RGBA pixels as JPEG when fully opaque (photos), else PNG.
Uint8List _encodeRgba(Uint8List rgba, int width, int height) {
  var opaque = true;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 0xFF) {
      opaque = false;
      break;
    }
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  return opaque ? img.encodeJpg(image, quality: 88) : img.encodePng(image);
}

/// PdfBitmap reads PNG and JPEG. Other formats are re-encoded, and big
/// photos are scaled down so a stamp doesn't add megabytes to the file.
Uint8List _pdfFriendlyImage(Uint8List bytes) {
  const maxSide = 2400;
  final isPng = _isPng(bytes);
  final isJpeg = _isJpeg(bytes);
  if ((isPng || isJpeg) && bytes.length <= 1536 * 1024) return bytes;

  var decoded = img.decodeImage(bytes);
  if (decoded == null) {
    if (isPng || isJpeg) return bytes;
    throw const FormatException('Unsupported image');
  }
  if (math.max(decoded.width, decoded.height) > maxSide) {
    decoded = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxSide)
        : img.copyResize(decoded, height: maxSide);
  } else if (isPng || isJpeg) {
    return bytes;
  }
  return decoded.hasAlpha
      ? img.encodePng(decoded)
      : img.encodeJpg(decoded, quality: 88);
}
