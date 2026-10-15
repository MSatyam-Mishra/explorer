import 'dart:typed_data';
import 'dart:ui';

/// Size and rotation of one PDF page, in PDF points.
class PdfPageMeta {
  const PdfPageMeta({
    required this.width,
    required this.height,
    required this.rotation,
  });

  /// Unrotated page width (crop box) in points.
  final double width;

  /// Unrotated page height (crop box) in points.
  final double height;

  /// Clockwise display rotation in degrees: 0, 90, 180 or 270.
  final int rotation;

  bool get isSideways => rotation == 90 || rotation == 270;

  /// Page size as it is shown on screen (rotation applied).
  Size get displaySize =>
      isSideways ? Size(height, width) : Size(width, height);
}

/// One page of the result of a page-manager session.
///
/// [sourceIndex] points at a page of the current document; `null` means a new
/// blank page of [blankSize].
class PagePlanEntry {
  const PagePlanEntry.source(int this.sourceIndex, {this.quarterTurns = 0})
      : blankSize = null;

  const PagePlanEntry.blank(Size this.blankSize)
      : sourceIndex = null,
        quarterTurns = 0;

  final int? sourceIndex;
  final int quarterTurns;
  final Size? blankSize;

  bool get isBlank => sourceIndex == null;

  PagePlanEntry rotated(int turns) => isBlank
      ? this
      : PagePlanEntry.source(
          sourceIndex!,
          quarterTurns: (quarterTurns + turns) % 4,
        );
}

/// Something drawn onto a page by the page canvas editor. All geometry is in
/// PDF points in the page's *display* orientation (origin top-left).
sealed class PageMark {
  const PageMark();
}

class InkMark extends PageMark {
  const InkMark({
    required this.points,
    required this.color,
    required this.width,
    this.opacity = 1,
  });

  final List<Offset> points;
  final Color color;
  final double width;
  final double opacity;
}

class TextMark extends PageMark {
  const TextMark({
    required this.position,
    required this.text,
    required this.fontSize,
    required this.color,
  });

  /// Top-left corner of the first line.
  final Offset position;
  final String text;
  final double fontSize;
  final Color color;
}

class ImageMark extends PageMark {
  const ImageMark({required this.rect, required this.bytes});

  final Rect rect;

  /// Encoded image (PNG, JPEG or anything the `image` package can decode).
  final Uint8List bytes;
}

/// Result of probing a PDF before it is shown.
enum PdfOpenStatus { ok, needsPassword, invalid }

class PdfProbeResult {
  const PdfProbeResult(this.status, {this.pageCount = 0, this.message});

  final PdfOpenStatus status;
  final int pageCount;
  final String? message;
}
