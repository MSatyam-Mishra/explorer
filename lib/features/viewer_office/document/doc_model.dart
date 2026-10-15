import 'dart:typed_data';

/// Format-neutral document model shared by every word-processing parser
/// (DOCX, DOC, RTF, ODT), the print-layout renderer, the Quill converter and
/// the writers. Pure Dart so parsing can run in a background isolate.
///
/// All lengths are in points. Colours are ARGB ints (null = automatic).

enum DocAlign { left, center, right, justify }

enum DocVertAlign { baseline, superscript, subscript }

enum DocCellVAlign { top, center, bottom }

const Object _unset = Object();

/// Effective character formatting of a run.
class DocRunStyle {
  const DocRunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.allCaps = false,
    this.smallCaps = false,
    this.color,
    this.highlight,
    this.fontSize,
    this.fontFamily,
    this.vertAlign = DocVertAlign.baseline,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool allCaps;
  final bool smallCaps;
  final int? color;
  final int? highlight;
  final double? fontSize;
  final String? fontFamily;
  final DocVertAlign vertAlign;

  static const plain = DocRunStyle();

  DocRunStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? allCaps,
    bool? smallCaps,
    Object? color = _unset,
    Object? highlight = _unset,
    Object? fontSize = _unset,
    Object? fontFamily = _unset,
    DocVertAlign? vertAlign,
  }) {
    return DocRunStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strike: strike ?? this.strike,
      allCaps: allCaps ?? this.allCaps,
      smallCaps: smallCaps ?? this.smallCaps,
      color: identical(color, _unset) ? this.color : color as int?,
      highlight:
          identical(highlight, _unset) ? this.highlight : highlight as int?,
      fontSize: identical(fontSize, _unset) ? this.fontSize : fontSize as double?,
      fontFamily:
          identical(fontFamily, _unset) ? this.fontFamily : fontFamily as String?,
      vertAlign: vertAlign ?? this.vertAlign,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DocRunStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.allCaps == allCaps &&
      other.smallCaps == smallCaps &&
      other.color == color &&
      other.highlight == highlight &&
      other.fontSize == fontSize &&
      other.fontFamily == fontFamily &&
      other.vertAlign == vertAlign;

  @override
  int get hashCode => Object.hash(bold, italic, underline, strike, allCaps,
      smallCaps, color, highlight, fontSize, fontFamily, vertAlign);
}

// ---------------------------------------------------------------------------
// Inline content

sealed class DocInline {}

/// A run of text. Tabs are `\t`, soft line breaks are `\n`.
class DocText extends DocInline {
  DocText(this.text, this.style, {this.link, this.raw, this.field, this.origin});

  String text;
  DocRunStyle style;

  /// Hyperlink target (URL, or `#bookmark` for internal anchors).
  String? link;

  /// Format-specific payload for faithful round-trips (DOCX: the original
  /// `<w:rPr>` markup).
  String? raw;

  /// Field the text is the cached result of (`PAGE`, `NUMPAGES`).
  String? field;

  /// Formatting as originally parsed (set after editing) so writers only
  /// rewrite properties that changed.
  DocRunStyle? origin;
}

/// An inline picture.
class DocImage extends DocInline {
  DocImage({
    required this.imageId,
    required this.width,
    required this.height,
    this.raw,
    this.description,
  });

  /// Key into [DocModel.images].
  final String imageId;
  double width;
  double height;

  /// DOCX: original `<w:r>` markup holding the drawing.
  final String? raw;
  final String? description;
}

/// An embedded object that can't be edited but must be preserved: text
/// boxes, charts, equations, footnote references, shapes.
class DocObject extends DocInline {
  DocObject({
    required this.kind,
    this.displayText,
    this.raw,
    this.style = DocRunStyle.plain,
    List<DocBlock>? content,
  }) : content = content ?? [];

  /// Short label (`Text box`, `Chart`, `Equation`, `Footnote`).
  final String kind;

  /// Text shown inline in place of the object (may be empty).
  final String? displayText;

  /// DOCX: original `<w:r>` markup.
  final String? raw;
  final DocRunStyle style;

  /// Text-box content rendered (read-only) after the paragraph.
  final List<DocBlock> content;
}

// ---------------------------------------------------------------------------
// Blocks

sealed class DocBlock {}

class DocListInfo {
  DocListInfo({
    required this.ordered,
    required this.level,
    this.numId,
    this.format = 'decimal',
    this.label = '',
    this.labelStyle,
  });

  bool ordered;
  int level;

  /// Source list identifier (DOCX `numId`) for round-trips.
  String? numId;

  /// Number format (`decimal`, `lowerLetter`, `upperRoman`, `bullet` …).
  String format;

  /// Rendered label (`1.`, `a)`, `•`).
  String label;
  DocRunStyle? labelStyle;
}

class DocBorder {
  const DocBorder({this.color = 0xFF000000, this.width = 0.5, this.space = 1});
  final int color;
  final double width;
  final double space;
}

class DocParagraph extends DocBlock {
  DocParagraph({
    List<DocInline>? inlines,
    this.styleId,
    this.headingLevel,
    this.align = DocAlign.left,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.firstLine = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.lineSpacing = 1.0,
    this.lineExact,
    this.list,
    this.shading,
    this.borderTop,
    this.borderBottom,
    this.keepNext = false,
    this.pageBreakBefore = false,
    this.rtl = false,
    this.contextualSpacing = false,
    this.markStyle = DocRunStyle.plain,
    this.raw,
  }) : inlines = inlines ?? [];

  List<DocInline> inlines;
  String? styleId;

  /// 1–6 for headings (deeper outline levels are clamped to 6).
  int? headingLevel;
  DocAlign align;
  double indentLeft;
  double indentRight;

  /// Positive = first-line indent, negative = hanging indent.
  double firstLine;
  double spaceBefore;
  double spaceAfter;

  /// Multiple of single spacing (1.0 = single).
  double lineSpacing;

  /// Exact line height in points (overrides [lineSpacing]).
  double? lineExact;
  DocListInfo? list;
  int? shading;
  DocBorder? borderTop;
  DocBorder? borderBottom;
  bool keepNext;
  bool pageBreakBefore;
  bool rtl;
  bool contextualSpacing;

  /// Formatting a run without direct formatting would get here (used for
  /// empty paragraphs and list labels).
  DocRunStyle markStyle;

  /// DOCX: original `<w:pPr>` markup.
  String? raw;

  /// The paragraph this one was derived from while editing (null when it
  /// was parsed directly or created from scratch).
  DocParagraph? origin;

  String get plainText {
    final sb = StringBuffer();
    for (final i in inlines) {
      switch (i) {
        case DocText():
          sb.write(i.text);
        case DocImage():
          sb.write('\uFFFC');
        case DocObject():
          sb.write(i.displayText ?? '');
      }
    }
    return sb.toString();
  }

  bool get isEmpty =>
      inlines.every((i) => i is DocText && i.text.isEmpty);
}

class DocTableCell {
  DocTableCell({
    List<DocBlock>? blocks,
    this.colSpan = 1,
    this.rowSpan = 1,
    this.covered = false,
    this.shading,
    this.vAlign = DocCellVAlign.top,
    this.width,
  }) : blocks = blocks ?? [];

  List<DocBlock> blocks;
  int colSpan;
  int rowSpan;

  /// Continuation of a vertically merged cell (not drawn).
  bool covered;
  int? shading;
  DocCellVAlign vAlign;
  double? width;
}

class DocTableRow {
  DocTableRow({List<DocTableCell>? cells, this.height, this.exactHeight = false, this.header = false})
      : cells = cells ?? [];

  List<DocTableCell> cells;
  double? height;
  bool exactHeight;
  bool header;
}

class DocTable extends DocBlock {
  DocTable({
    List<DocTableRow>? rows,
    List<double>? columnWidths,
    this.width,
    this.borders = true,
    this.borderColor = 0xFF000000,
    this.align = DocAlign.left,
    this.indent = 0,
    this.cellPadding = 5.4,
    this.raw,
  })  : rows = rows ?? [],
        columnWidths = columnWidths ?? [];

  List<DocTableRow> rows;
  List<double> columnWidths;
  double? width;
  bool borders;
  int borderColor;
  DocAlign align;
  double indent;
  double cellPadding;

  /// DOCX: original `<w:tbl>` markup, written back verbatim.
  String? raw;

  int get columnCount {
    if (columnWidths.isNotEmpty) return columnWidths.length;
    var max = 0;
    for (final r in rows) {
      var n = 0;
      for (final c in r.cells) {
        n += c.colSpan;
      }
      if (n > max) max = n;
    }
    return max;
  }
}

class DocPageBreak extends DocBlock {}

/// End of a section; carries the page setup of the section it ends.
class DocSectionBreak extends DocBlock {
  DocSectionBreak({required this.page, this.newPage = true, this.raw});
  final DocPageSetup page;
  final bool newPage;

  /// DOCX: original `<w:sectPr>` markup.
  final String? raw;
}

/// A read-only frame (e.g. a text box's content) shown in the flow.
class DocFrame extends DocBlock {
  DocFrame({required this.blocks, this.label});
  final List<DocBlock> blocks;
  final String? label;
}

class DocPageSetup {
  const DocPageSetup({
    this.width = 612,
    this.height = 792,
    this.marginTop = 72,
    this.marginBottom = 72,
    this.marginLeft = 72,
    this.marginRight = 72,
    this.headerDistance = 36,
    this.footerDistance = 36,
  });

  final double width;
  final double height;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;
  final double headerDistance;
  final double footerDistance;

  double get contentWidth =>
      (width - marginLeft - marginRight).clamp(72, 10000).toDouble();
  double get contentHeight =>
      (height - marginTop - marginBottom).clamp(72, 10000).toDouble();

  static const letter = DocPageSetup();
  static const a4 = DocPageSetup(width: 595.3, height: 841.9);
}

class DocImageData {
  DocImageData(this.bytes, this.extension, {this.sourcePath});
  final Uint8List bytes;

  /// Lower-case extension (`png`, `jpeg`, `emf` …).
  final String extension;

  /// Original part name (DOCX `word/media/image1.png`).
  final String? sourcePath;
}

/// DOCX-specific information needed to save back into the original package.
class DocxSourceInfo {
  DocxSourceInfo({
    required this.mainPart,
    required this.headingStyleIds,
    required this.normalStyleId,
    required this.wPrefix,
    this.bodySectPr,
    Map<String, String>? hyperlinkTargets,
    Set<String>? headingStyleSet,
  })  : hyperlinkTargets = hyperlinkTargets ?? {},
        headingStyleSet = headingStyleSet ?? {};

  final String mainPart;
  final Map<int, String> headingStyleIds;
  final String? normalStyleId;
  final String wPrefix;
  final String? bodySectPr;

  /// Relationship id → URL for existing hyperlinks.
  final Map<String, String> hyperlinkTargets;

  /// All style ids that are headings (any level).
  final Set<String> headingStyleSet;
}

class DocModel {
  DocModel({
    required this.format,
    required this.blocks,
    Map<String, DocImageData>? images,
    this.page = DocPageSetup.letter,
    this.baseStyle = const DocRunStyle(fontSize: 11),
    Map<int, DocRunStyle>? headingStyles,
    Map<int, double>? headingSpacing,
    List<DocBlock>? header,
    List<DocBlock>? footer,
    List<String>? warnings,
    this.docx,
    this.title,
  })  : images = images ?? {},
        headingStyles = headingStyles ?? defaultHeadingStyles(baseStyle),
        headingSpacing = headingSpacing ?? {},
        header = header ?? [],
        footer = footer ?? [],
        warnings = warnings ?? [];

  /// Source format id: `docx`, `doc`, `rtf`, `odt`, `wps`, `txt`.
  final String format;
  List<DocBlock> blocks;
  final Map<String, DocImageData> images;

  /// Page setup of the last section (earlier sections carry their own in
  /// [DocSectionBreak]).
  final DocPageSetup page;

  /// Run formatting of a plain "Normal" paragraph.
  final DocRunStyle baseStyle;

  /// Run formatting of heading paragraphs by level (1–6).
  final Map<int, DocRunStyle> headingStyles;

  /// Space before headings by level (pt), used by the editor.
  final Map<int, double> headingSpacing;
  final List<DocBlock> header;
  final List<DocBlock> footer;
  final List<String> warnings;
  final DocxSourceInfo? docx;
  final String? title;

  static Map<int, DocRunStyle> defaultHeadingStyles(DocRunStyle base) {
    final size = base.fontSize ?? 11;
    return {
      1: base.copyWith(bold: true, fontSize: (size * 1.8).roundToDouble()),
      2: base.copyWith(bold: true, fontSize: (size * 1.5).roundToDouble()),
      3: base.copyWith(bold: true, fontSize: (size * 1.25).roundToDouble()),
      4: base.copyWith(bold: true, italic: true, fontSize: size + 1),
      5: base.copyWith(bold: true, fontSize: size),
      6: base.copyWith(bold: true, italic: true, fontSize: size),
    };
  }

  DocRunStyle editorBaseFor(int? heading) =>
      heading == null ? baseStyle : (headingStyles[heading] ?? baseStyle);

  /// Every paragraph in reading order, including those inside tables and
  /// frames.
  Iterable<DocParagraph> allParagraphs() sync* {
    yield* paragraphsIn(blocks);
  }

  static Iterable<DocParagraph> paragraphsIn(List<DocBlock> blocks) sync* {
    for (final b in blocks) {
      switch (b) {
        case DocParagraph():
          yield b;
        case DocTable():
          for (final r in b.rows) {
            for (final c in r.cells) {
              if (!c.covered) yield* paragraphsIn(c.blocks);
            }
          }
        case DocFrame():
          yield* paragraphsIn(b.blocks);
        default:
          break;
      }
    }
  }

  String plainText() {
    final sb = StringBuffer();
    for (final p in allParagraphs()) {
      if (p.list != null && p.list!.label.isNotEmpty) {
        sb.write('${p.list!.label} ');
      }
      sb.writeln(p.plainText.replaceAll('\uFFFC', ''));
    }
    return sb.toString();
  }
}

/// Recomputes list labels after editing (or for formats without stored
/// labels). Paragraphs that keep [DocListInfo.label] non-empty and have
/// [keepExisting] are left untouched.
void renumberLists(List<DocBlock> blocks, {bool keepExisting = false}) {
  final counters = <int>[];
  final kinds = <bool?>[];
  var lastWasList = false;
  for (final b in blocks) {
    if (b is DocTable) {
      for (final r in b.rows) {
        for (final c in r.cells) {
          renumberLists(c.blocks, keepExisting: keepExisting);
        }
      }
      continue;
    }
    if (b is! DocParagraph) continue;
    final l = b.list;
    if (l == null) {
      if (!b.isEmpty) {
        counters.clear();
        lastWasList = false;
      }
      continue;
    }
    if (!lastWasList) {
      counters.clear();
      kinds.clear();
    }
    lastWasList = true;
    while (counters.length <= l.level) {
      counters.add(0);
      kinds.add(null);
    }
    // A switch between bullets and numbers starts a new list.
    if (kinds[l.level] != null && kinds[l.level] != l.ordered) {
      counters[l.level] = 0;
    }
    kinds[l.level] = l.ordered;
    counters[l.level]++;
    for (var i = l.level + 1; i < counters.length; i++) {
      counters[i] = 0;
      kinds[i] = null;
    }
    if (keepExisting && l.label.isNotEmpty) continue;
    if (!l.ordered) {
      l.label = bulletForLevel(l.level);
      l.format = 'bullet';
    } else {
      if (l.format == 'bullet' || l.format == 'none') {
        l.format = defaultOrderedFormat(l.level);
      }
      l.label = '${formatListNumber(counters[l.level], l.format)}.';
    }
  }
}

String bulletForLevel(int level) => const ['•', '◦', '▪'][level % 3];

String defaultOrderedFormat(int level) =>
    const ['decimal', 'lowerLetter', 'lowerRoman'][level % 3];

/// Formats [n] in a Word number format.
String formatListNumber(int n, String format) {
  switch (format) {
    case 'lowerLetter':
      return _letters(n).toLowerCase();
    case 'upperLetter':
      return _letters(n);
    case 'lowerRoman':
      return _roman(n).toLowerCase();
    case 'upperRoman':
      return _roman(n);
    case 'decimalZero':
      return n < 10 ? '0$n' : '$n';
    case 'ordinal':
      final s = n % 100 >= 11 && n % 100 <= 13
          ? 'th'
          : const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th';
      return '$n$s';
    case 'none':
      return '';
    case 'bullet':
      return '•';
    default:
      return '$n';
  }
}

String _letters(int n) {
  if (n <= 0) return '$n';
  // Word repeats letters: a..z, aa..zz, aaa..
  final letter = String.fromCharCode(0x41 + (n - 1) % 26);
  return letter * ((n - 1) ~/ 26 + 1);
}

String _roman(int n) {
  if (n <= 0 || n >= 4000) return '$n';
  const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const syms = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
  final sb = StringBuffer();
  var v = n;
  for (var i = 0; i < vals.length; i++) {
    while (v >= vals[i]) {
      sb.write(syms[i]);
      v -= vals[i];
    }
  }
  return sb.toString();
}

/// Statistics shown in the info sheet.
class DocStats {
  DocStats(this.words, this.characters, this.charactersNoSpaces,
      this.paragraphs, this.tables, this.images);

  final int words;
  final int characters;
  final int charactersNoSpaces;
  final int paragraphs;
  final int tables;
  final int images;

  factory DocStats.of(DocModel m) {
    var words = 0, chars = 0, noSpace = 0, paras = 0, tables = 0, images = 0;
    final wordRe = RegExp(r"[\p{L}\p{N}][\p{L}\p{N}'’\-]*", unicode: true);
    void countBlocks(List<DocBlock> blocks) {
      for (final b in blocks) {
        if (b is DocTable) {
          tables++;
          for (final r in b.rows) {
            for (final c in r.cells) {
              if (!c.covered) countBlocks(c.blocks);
            }
          }
        } else if (b is DocFrame) {
          countBlocks(b.blocks);
        } else if (b is DocParagraph) {
          final t = b.plainText.replaceAll('\uFFFC', '');
          for (final i in b.inlines) {
            if (i is DocImage) images++;
          }
          if (t.trim().isEmpty) continue;
          paras++;
          words += wordRe.allMatches(t).length;
          chars += t.replaceAll('\n', '').length;
          noSpace += t.replaceAll(RegExp(r'\s'), '').length;
        }
      }
    }

    countBlocks(m.blocks);
    return DocStats(words, chars, noSpace, paras, tables, images);
  }
}
