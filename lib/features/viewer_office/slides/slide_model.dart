import 'dart:typed_data';

/// Format-neutral presentation model (PPTX, PPT, ODP). Pure Dart so it can
/// be built in a background isolate. Geometry is in points; colours are
/// ARGB ints.

class SlideRect {
  const SlideRect(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;

  static const zero = SlideRect(0, 0, 0, 0);

  @override
  String toString() => 'SlideRect($x, $y, $w, $h)';
}

class SlideGradientStop {
  const SlideGradientStop(this.position, this.color);
  final double position;
  final int color;
}

class SlideFill {
  const SlideFill({
    this.color,
    this.imageId,
    this.gradient,
    this.gradientAngle = 90,
  });

  final int? color;
  final String? imageId;
  final List<SlideGradientStop>? gradient;

  /// Degrees, 0 = left→right, 90 = top→bottom.
  final double gradientAngle;

  bool get isEmpty =>
      color == null &&
      imageId == null &&
      (gradient == null || gradient!.isEmpty);
}

class SlideLine {
  const SlideLine({
    required this.color,
    this.width = 0.75,
    this.dash,
    this.headArrow = false,
    this.tailArrow = false,
  });
  final int color;
  final double width;

  /// `dash`, `dot`, `dashDot`… or null for solid.
  final String? dash;
  final bool headArrow;
  final bool tailArrow;
}

class SlideRun {
  SlideRun({
    required this.text,
    this.size = 18,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color = 0xFF000000,
    this.font,
    this.link,
    this.highlight,
    this.baseline = 0,
    this.caps = false,
  });

  String text;
  double size;
  bool bold;
  bool italic;
  bool underline;
  bool strike;
  int color;
  String? font;
  String? link;
  int? highlight;

  /// Positive = superscript, negative = subscript (percent of size).
  double baseline;
  bool caps;
}

class SlideBullet {
  const SlideBullet({
    this.char,
    this.autoNumber,
    this.startAt = 1,
    this.color,
    this.sizePercent = 1,
    this.font,
  });
  final String? char;

  /// `arabicPeriod`, `alphaLcParenR`, … (DrawingML auto-number schemes).
  final String? autoNumber;
  final int startAt;
  final int? color;
  final double sizePercent;
  final String? font;
}

enum SlideAlign { left, center, right, justify }

class SlideParagraph {
  SlideParagraph({
    List<SlideRun>? runs,
    this.align = SlideAlign.left,
    this.level = 0,
    this.bullet,
    this.bulletLabel,
    this.marginLeft = 0,
    this.indent = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.lineSpacing = 1,
    this.endSize = 18,
  }) : runs = runs ?? [];

  List<SlideRun> runs;
  SlideAlign align;
  int level;
  SlideBullet? bullet;

  /// Rendered bullet text (resolved auto-numbers), null for none.
  String? bulletLabel;
  double marginLeft;
  double indent;
  double spaceBefore;
  double spaceAfter;

  /// Multiple of single spacing.
  double lineSpacing;

  /// Font size for an empty paragraph.
  double endSize;

  String get text => runs.map((r) => r.text).join();
}

class SlideTextBody {
  SlideTextBody({
    List<SlideParagraph>? paragraphs,
    this.insetLeft = 7.2,
    this.insetTop = 3.6,
    this.insetRight = 7.2,
    this.insetBottom = 3.6,
    this.anchor = 't',
    this.wrap = true,
    this.fontScale = 1,
    this.vertical = false,
  }) : paragraphs = paragraphs ?? [];

  List<SlideParagraph> paragraphs;
  double insetLeft;
  double insetTop;
  double insetRight;
  double insetBottom;

  /// `t`, `ctr`, `b`.
  String anchor;
  bool wrap;
  double fontScale;
  bool vertical;

  String get plainText => paragraphs.map((p) => p.text).join('\n');
  bool get isEmpty => paragraphs.every((p) => p.text.trim().isEmpty);
}

sealed class SlideShape {
  SlideShape({
    required this.frame,
    this.rotation = 0,
    this.flipH = false,
    this.flipV = false,
    this.id,
    this.name,
    this.fromSlide = true,
    this.placeholder,
  });

  SlideRect frame;
  double rotation;
  bool flipH;
  bool flipV;

  /// `cNvPr` id within its part (used to address edits).
  String? id;
  String? name;

  /// False for shapes inherited from the layout/master.
  bool fromSlide;

  /// Placeholder type (`title`, `body`, …) when it is one.
  String? placeholder;
}

class SlidePathCommand {
  const SlidePathCommand(this.op, this.points);

  /// `M`, `L`, `C`, `Q`, `Z`, `A` (arc: points = [wR, hR, stAng, swAng]).
  final String op;
  final List<double> points;
}

class SlideCustomPath {
  const SlideCustomPath(
    this.width,
    this.height,
    this.commands, {
    this.fill = true,
    this.stroke = true,
  });
  final double width;
  final double height;
  final List<SlidePathCommand> commands;
  final bool fill;
  final bool stroke;
}

class SlideAutoShape extends SlideShape {
  SlideAutoShape({
    required super.frame,
    super.rotation,
    super.flipH,
    super.flipV,
    super.id,
    super.name,
    super.fromSlide,
    super.placeholder,
    this.geometry = 'rect',
    this.adjust,
    this.customPaths,
    this.fill,
    this.line,
    this.text,
    this.opacity = 1,
  });

  /// DrawingML preset name (`rect`, `roundRect`, `ellipse`, `line` …) or
  /// `custom`.
  String geometry;

  /// First adjust value (fraction), e.g. corner radius for roundRect.
  double? adjust;
  List<SlideCustomPath>? customPaths;
  SlideFill? fill;
  SlideLine? line;
  SlideTextBody? text;
  double opacity;
}

class SlidePicture extends SlideShape {
  SlidePicture({
    required super.frame,
    super.rotation,
    super.flipH,
    super.flipV,
    super.id,
    super.name,
    super.fromSlide,
    super.placeholder,
    required this.imageId,
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
    this.geometry = 'rect',
    this.line,
  });

  final String imageId;
  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;
  final String geometry;
  final SlideLine? line;
}

class SlideTableCell {
  SlideTableCell({
    required this.text,
    this.fill,
    this.colSpan = 1,
    this.rowSpan = 1,
    this.merged = false,
    this.borderColor,
  });

  SlideTextBody text;
  SlideFill? fill;
  int colSpan;
  int rowSpan;

  /// Covered by a neighbour's span.
  bool merged;
  int? borderColor;
}

class SlideTable extends SlideShape {
  SlideTable({
    required super.frame,
    super.id,
    super.name,
    super.fromSlide,
    required this.columns,
    required this.rows,
    required this.rowHeights,
  });

  final List<double> columns;
  final List<List<SlideTableCell>> rows;
  final List<double> rowHeights;
}

class SlideImageData {
  SlideImageData(this.bytes, this.extension);
  final Uint8List bytes;
  final String extension;
}

class Slide {
  Slide({
    required this.index,
    List<SlideShape>? shapes,
    this.background,
    this.notes = '',
    this.hidden = false,
    this.partName,
    this.relId,
    this.slideId,
  }) : shapes = shapes ?? [];

  int index;
  List<SlideShape> shapes;
  SlideFill? background;
  String notes;
  bool hidden;

  /// PPTX: `ppt/slides/slideN.xml`, its relationship id in
  /// `presentation.xml.rels`, and its `p:sldId` id.
  String? partName;
  String? relId;
  String? slideId;

  String get title {
    for (final s in shapes) {
      if (s is SlideAutoShape &&
          (s.placeholder == 'title' || s.placeholder == 'ctrTitle') &&
          s.text != null &&
          !s.text!.isEmpty) {
        return s.text!.plainText.replaceAll('\n', ' ').trim();
      }
    }
    for (final s in shapes) {
      if (s is SlideAutoShape &&
          s.fromSlide &&
          s.text != null &&
          !s.text!.isEmpty) {
        return s.text!.paragraphs.first.text.trim();
      }
    }
    return '';
  }

  /// Every text shape on the slide that belongs to the slide itself.
  Iterable<SlideAutoShape> get editableTextShapes sync* {
    for (final s in shapes) {
      if (s is SlideAutoShape &&
          s.fromSlide &&
          s.text != null &&
          s.id != null) {
        yield s;
      }
    }
  }
}

class SlideDeck {
  SlideDeck({
    required this.format,
    required this.width,
    required this.height,
    required this.slides,
    Map<String, SlideImageData>? images,
    List<String>? warnings,
  }) : images = images ?? {},
       warnings = warnings ?? [];

  /// `pptx`, `ppt`, `odp`.
  final String format;
  final double width;
  final double height;
  final List<Slide> slides;
  final Map<String, SlideImageData> images;
  final List<String> warnings;

  double get aspect => height <= 0 ? 16 / 9 : width / height;
}

/// Formats an auto-number bullet.
String slideAutoNumber(String scheme, int n) {
  String letters(int v) {
    if (v <= 0) return '$v';
    return String.fromCharCode(0x61 + (v - 1) % 26) * ((v - 1) ~/ 26 + 1);
  }

  String roman(int v) {
    if (v <= 0 || v >= 4000) return '$v';
    const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const syms = [
      'm',
      'cm',
      'd',
      'cd',
      'c',
      'xc',
      'l',
      'xl',
      'x',
      'ix',
      'v',
      'iv',
      'i',
    ];
    final sb = StringBuffer();
    var x = v;
    for (var i = 0; i < vals.length; i++) {
      while (x >= vals[i]) {
        sb.write(syms[i]);
        x -= vals[i];
      }
    }
    return sb.toString();
  }

  final s = scheme.toLowerCase();
  String core;
  if (s.startsWith('alphalc')) {
    core = letters(n);
  } else if (s.startsWith('alphauc')) {
    core = letters(n).toUpperCase();
  } else if (s.startsWith('romanlc')) {
    core = roman(n);
  } else if (s.startsWith('romanuc')) {
    core = roman(n).toUpperCase();
  } else {
    core = '$n';
  }
  if (s.endsWith('parenboth')) return '($core)';
  if (s.endsWith('parenr')) return '$core)';
  if (s.endsWith('period')) return '$core.';
  if (s.endsWith('minus')) return '- $core -';
  return core;
}
