import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../doc_model.dart';
import 'doc_render_context.dart';

/// A block measured at a fixed width. Geometry is computed with
/// [TextPainter]s using exactly the spans the widgets paint, so slices cut
/// at [breaks] never split a line.
abstract class LaidBlock {
  double get height;

  /// Allowed page-cut positions, ascending, strictly inside (0, height).
  List<double> get breaks;

  /// Content ends here; anything below is trailing spacing that may be
  /// dropped at a page bottom.
  double get contentEnd => height;

  bool get keepWithNext => false;
  double get width;

  /// Builds the block. [from]/[to] is the visible vertical range, which lets
  /// big tables skip rows that are clipped away.
  Widget build(DocRenderContext ctx, {double from = 0, double to = double.infinity});
}

enum LaidMarkerKind { pageBreak, sectionBreak }

class LaidMarker extends LaidBlock {
  LaidMarker(this.kind, {this.newPage = true});
  final LaidMarkerKind kind;
  final bool newPage;
  @override
  double get height => 0;
  @override
  List<double> get breaks => const [];
  @override
  double get width => 0;
  @override
  Widget build(DocRenderContext ctx, {double from = 0, double to = double.infinity}) =>
      const SizedBox.shrink();
}

class LaidParagraph extends LaidBlock {
  LaidParagraph({
    required this.paragraph,
    required this.width,
    required this.height,
    required this.breaks,
    required this.contentEnd,
    required this.textX,
    required this.textY,
    required this.textWidth,
    required this.textHeight,
    required this.labelX,
    required this.labelWidth,
    required this.spaceBefore,
  });

  final DocParagraph paragraph;
  @override
  final double width;
  @override
  final double height;
  @override
  final List<double> breaks;
  @override
  final double contentEnd;
  final double textX;
  final double textY;
  final double textWidth;
  final double textHeight;
  final double labelX;
  final double labelWidth;
  final double spaceBefore;

  @override
  bool get keepWithNext => paragraph.keepNext;

  /// Vertical position (within the block) of the caret at [offset].
  double caretY(DocRenderContext ctx, int offset) {
    final span = buildParagraphSpan(paragraph, ctx, maxWidth: textWidth, measure: true);
    final tp = TextPainter(
      text: span.span,
      textAlign: paragraphAlign(paragraph),
      textDirection: paragraph.rtl ? TextDirection.rtl : TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      strutStyle: paragraphStrut(paragraph),
    );
    tp.setPlaceholderDimensions(span.placeholders);
    tp.layout(maxWidth: textWidth);
    final lead = paragraph.firstLine > 0 && paragraph.list == null ? 1 : 0;
    final o = tp.getOffsetForCaret(
        TextPosition(offset: offset + lead), Rect.zero);
    tp.dispose();
    return textY + o.dy;
  }

  @override
  Widget build(DocRenderContext ctx, {double from = 0, double to = double.infinity}) =>
      _ParagraphView(laid: this, ctx: ctx);
}

class _ParagraphView extends StatefulWidget {
  const _ParagraphView({required this.laid, required this.ctx});
  final LaidParagraph laid;
  final DocRenderContext ctx;

  @override
  State<_ParagraphView> createState() => _ParagraphViewState();
}

class _ParagraphViewState extends State<_ParagraphView> {
  final List<GestureRecognizer> _recognizers = [];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final l = widget.laid;
    final p = l.paragraph;
    final ctx = widget.ctx;
    final span = buildParagraphSpan(p, ctx,
        maxWidth: l.textWidth, recognizers: _recognizers);
    final rtl = p.rtl;
    final children = <Widget>[];
    final innerTop = l.spaceBefore;
    final innerBottom = l.contentEnd;
    if (p.shading != null) {
      children.add(Positioned(
        left: math.max(0, p.indentLeft - 2),
        right: math.max(0, p.indentRight - 2),
        top: innerTop,
        height: math.max(0, innerBottom - innerTop),
        child: ColoredBox(color: ctx.fillColor(p.shading!)),
      ));
    }
    if (p.borderTop != null) {
      children.add(Positioned(
        left: p.indentLeft,
        right: p.indentRight,
        top: innerTop,
        height: p.borderTop!.width,
        child: ColoredBox(color: ctx.textColor(p.borderTop!.color)),
      ));
    }
    if (p.borderBottom != null) {
      children.add(Positioned(
        left: p.indentLeft,
        right: p.indentRight,
        top: innerBottom - p.borderBottom!.width,
        height: p.borderBottom!.width,
        child: ColoredBox(color: ctx.textColor(p.borderBottom!.color)),
      ));
    }
    final list = p.list;
    if (list != null && list.label.isNotEmpty) {
      final labelStyle = docTextStyle(list.labelStyle ?? p.markStyle, ctx);
      children.add(Positioned(
        left: rtl ? null : l.labelX,
        right: rtl ? l.labelX : null,
        top: l.textY,
        child: RichText(
          text: TextSpan(text: list.label, style: labelStyle),
          textScaler: TextScaler.noScaling,
          maxLines: 1,
          softWrap: false,
          strutStyle: paragraphStrut(p),
        ),
      ));
    }
    children.add(Positioned(
      left: rtl ? null : l.textX,
      right: rtl ? l.textX : null,
      top: l.textY,
      width: l.textWidth,
      child: RichText(
        text: span.span,
        textAlign: paragraphAlign(p),
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        strutStyle: paragraphStrut(p),
      ),
    ));
    return SizedBox(
      width: l.width,
      height: l.height,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }
}

class LaidCell {
  LaidCell(this.cell, this.row, this.col, this.blocks, this.contentHeight);
  final DocTableCell cell;
  final int row;
  final int col;
  final List<LaidBlock> blocks;
  final double contentHeight;
  Rect rect = Rect.zero;
}

class LaidTable extends LaidBlock {
  LaidTable({
    required this.table,
    required this.width,
    required this.x,
    required this.tableWidth,
    required this.rowY,
    required this.cells,
    required this.padding,
  });

  final DocTable table;
  @override
  final double width;
  final double x;
  final double tableWidth;
  final List<double> rowY;
  final List<LaidCell> cells;
  final double padding;

  static const double vPad = 1.5;

  @override
  double get height => rowY.last + 0.5;

  @override
  List<double> get breaks {
    // Row boundaries not crossed by a vertically merged cell.
    final blocked = <int>{};
    for (final c in cells) {
      for (var r = c.row + 1; r < c.row + c.cell.rowSpan; r++) {
        blocked.add(r);
      }
    }
    return [
      for (var r = 1; r < rowY.length - 1; r++)
        if (!blocked.contains(r)) rowY[r],
    ];
  }

  /// Top of the row containing [p], if it's inside this table.
  double? yOfParagraph(DocParagraph p) {
    for (final c in cells) {
      if (DocModel.paragraphsIn(c.cell.blocks).contains(p)) return c.rect.top;
    }
    return null;
  }

  @override
  Widget build(DocRenderContext ctx, {double from = 0, double to = double.infinity}) {
    final border = table.borders
        ? Border.all(color: ctx.textColor(table.borderColor), width: 0.5)
        : null;
    final children = <Widget>[];
    for (final c in cells) {
      if (c.rect.bottom < from - 1 || c.rect.top > to + 1) continue;
      final innerW = math.max(1.0, c.rect.width - padding * 2);
      final free = c.rect.height - vPad * 2 - c.contentHeight;
      final dy = switch (c.cell.vAlign) {
        DocCellVAlign.top => 0.0,
        DocCellVAlign.center => math.max(0.0, free / 2),
        DocCellVAlign.bottom => math.max(0.0, free),
      };
      children.add(Positioned.fromRect(
        rect: c.rect,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.cell.shading == null ? null : ctx.fillColor(c.cell.shading!),
            border: border,
          ),
          child: ClipRect(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, vPad + dy, padding, 0),
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minHeight: 0,
                maxHeight: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final b in c.blocks)
                      SizedBox(width: innerW, height: b.height, child: b.build(ctx)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
    }
    return SizedBox(
      width: width,
      height: height,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: x,
          top: 0,
          width: tableWidth,
          height: height,
          child: Stack(clipBehavior: Clip.none, children: children),
        ),
      ]),
    );
  }
}

class LaidFrame extends LaidBlock {
  LaidFrame(this.frame, this.width, this.children);
  final DocFrame frame;
  @override
  final double width;
  final List<LaidBlock> children;
  static const pad = 6.0;
  static const margin = 4.0;

  @override
  double get height =>
      children.fold<double>(0, (s, b) => s + b.height) + pad * 2 + margin * 2;

  @override
  List<double> get breaks {
    final out = <double>[];
    var y = margin + pad;
    for (final c in children) {
      for (final b in c.breaks) {
        out.add(y + b);
      }
      y += c.height;
      out.add(y);
    }
    if (out.isNotEmpty) out.removeLast();
    return out;
  }

  @override
  Widget build(DocRenderContext ctx, {double from = 0, double to = double.infinity}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: margin),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(pad),
        decoration: BoxDecoration(
          border: Border.all(
              color: ctx.borderColor.withValues(alpha: 0.35), width: 0.75),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in children)
              SizedBox(
                  width: width - pad * 2 - 1.5,
                  height: c.height,
                  child: c.build(ctx)),
          ],
        ),
      ),
    );
  }
}

/// Measures blocks into [LaidBlock]s.
class DocLayoutEngine {
  DocLayoutEngine(this.model, this.ctx);

  final DocModel model;

  /// Context used for measuring (colours/highlights don't matter).
  final DocRenderContext ctx;

  List<LaidBlock> layoutBlocks(List<DocBlock> blocks, double width) {
    final spacing = _effectiveSpacing(blocks);
    return [
      for (var i = 0; i < blocks.length; i++)
        layoutBlock(blocks[i], width, spacing: spacing[i]),
    ];
  }

  /// Applies contextual spacing between same-style paragraphs.
  List<(double, double)?> _effectiveSpacing(List<DocBlock> blocks) {
    final out = List<(double, double)?>.filled(blocks.length, null);
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is! DocParagraph) continue;
      var sb = b.spaceBefore;
      var sa = b.spaceAfter;
      if (b.contextualSpacing) {
        final prev = i > 0 ? blocks[i - 1] : null;
        final next = i + 1 < blocks.length ? blocks[i + 1] : null;
        if (prev is DocParagraph && prev.styleId == b.styleId) sb = 0;
        if (next is DocParagraph && next.styleId == b.styleId) sa = 0;
      }
      out[i] = (sb, sa);
    }
    return out;
  }

  LaidBlock layoutBlock(DocBlock b, double width, {(double, double)? spacing}) {
    switch (b) {
      case DocParagraph():
        return layoutParagraph(b, width,
            spaceBefore: spacing?.$1, spaceAfter: spacing?.$2);
      case DocTable():
        return layoutTable(b, width);
      case DocFrame():
        return LaidFrame(
          b,
          width,
          layoutBlocks(b.blocks, math.max(24, width - LaidFrame.pad * 2 - 1.5)),
        );
      case DocPageBreak():
        return LaidMarker(LaidMarkerKind.pageBreak);
      case DocSectionBreak():
        return LaidMarker(LaidMarkerKind.sectionBreak, newPage: b.newPage);
    }
  }

  LaidParagraph layoutParagraph(DocParagraph p, double width,
      {double? spaceBefore, double? spaceAfter}) {
    final sb = spaceBefore ?? p.spaceBefore;
    final sa = spaceAfter ?? p.spaceAfter;
    final topBorder = p.borderTop == null ? 0.0 : p.borderTop!.width + p.borderTop!.space;
    final bottomBorder =
        p.borderBottom == null ? 0.0 : p.borderBottom!.width + p.borderBottom!.space;

    var textX = math.max(0.0, p.indentLeft);
    var labelX = textX;
    var labelW = 0.0;
    final list = p.list;
    if (list != null && list.label.isNotEmpty) {
      final hanging = p.firstLine < 0 ? -p.firstLine : 0.0;
      final tp = TextPainter(
        text: TextSpan(
            text: list.label,
            style: docTextStyle(list.labelStyle ?? p.markStyle, ctx)),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        maxLines: 1,
      )..layout();
      labelW = tp.width;
      tp.dispose();
      labelX = math.max(0.0, p.indentLeft - hanging);
      if (hanging < labelW + 2) {
        textX = math.max(textX, labelX + labelW + 6);
      }
    }
    final textW = math.max(24.0, width - textX - math.max(0.0, p.indentRight));

    final span = buildParagraphSpan(p, ctx, maxWidth: textW, measure: true);
    final tp = TextPainter(
      text: span.span,
      textAlign: paragraphAlign(p),
      textDirection: p.rtl ? TextDirection.rtl : TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      strutStyle: paragraphStrut(p),
    );
    tp.setPlaceholderDimensions(span.placeholders);
    tp.layout(maxWidth: textW);
    final textH = tp.height;
    final lines = tp.computeLineMetrics();
    tp.dispose();

    final textY = sb + topBorder;
    final breaks = <double>[];
    var y = textY;
    for (final lm in lines) {
      y += lm.height;
      breaks.add(y);
    }
    final contentEnd = textY + textH + bottomBorder;
    final height = contentEnd + sa;
    final filtered = [
      for (final b in breaks)
        if (b > 0.01 && b < height - 0.01) b,
    ];
    return LaidParagraph(
      paragraph: p,
      width: width,
      height: height,
      breaks: filtered,
      contentEnd: contentEnd,
      textX: textX,
      textY: textY,
      textWidth: textW,
      textHeight: textH,
      labelX: labelX,
      labelWidth: labelW,
      spaceBefore: sb,
    );
  }

  LaidTable layoutTable(DocTable t, double width) {
    final n = math.max(1, t.columnCount);
    var widths = <double>[];
    if (t.columnWidths.length >= n) {
      widths = t.columnWidths.sublist(0, n);
    } else if (t.columnWidths.isNotEmpty) {
      final avg = t.columnWidths.reduce((a, b) => a + b) / t.columnWidths.length;
      widths = [...t.columnWidths, ...List.filled(n - t.columnWidths.length, avg)];
    } else {
      final total = math.min(width, t.width ?? width);
      widths = List.filled(n, total / n);
    }
    widths = [for (final w in widths) math.max(w, 8.0)];
    var total = widths.fold<double>(0, (a, b) => a + b);
    if (total > width) {
      final f = width / total;
      widths = [for (final w in widths) w * f];
      total = width;
    }
    double x;
    switch (t.align) {
      case DocAlign.center:
        x = (width - total) / 2;
      case DocAlign.right:
        x = width - total;
      default:
        x = t.indent.clamp(0.0, math.max(0.0, width - total));
    }
    final colX = <double>[0];
    for (final w in widths) {
      colX.add(colX.last + w);
    }
    final pad = t.cellPadding.clamp(0.0, 20.0);

    final cells = <LaidCell>[];
    final rowH = List<double>.filled(t.rows.length, 0);
    for (var r = 0; r < t.rows.length; r++) {
      var c = 0;
      for (final cell in t.rows[r].cells) {
        final span = cell.colSpan.clamp(1, n);
        if (!cell.covered && c < n) {
          final end = math.min(n, c + span);
          final cw = colX[end] - colX[c];
          final inner = math.max(8.0, cw - pad * 2);
          final laid = layoutBlocks(cell.blocks, inner);
          final h = laid.fold<double>(0, (s, b) => s + b.height);
          final lc = LaidCell(cell, r, c, laid, h)
            ..rect = Rect.fromLTWH(colX[c], 0, cw, 0);
          cells.add(lc);
          if (cell.rowSpan <= 1) {
            rowH[r] = math.max(rowH[r], h + LaidTable.vPad * 2);
          }
        }
        c += span;
      }
      final row = t.rows[r];
      if (row.height != null) {
        rowH[r] = row.exactHeight ? row.height! : math.max(rowH[r], row.height!);
      }
      if (rowH[r] <= 0) rowH[r] = 12;
    }
    // Vertically merged cells may need extra height on their last row.
    for (final lc in cells) {
      final span = lc.cell.rowSpan;
      if (span <= 1) continue;
      final last = math.min(t.rows.length - 1, lc.row + span - 1);
      var have = 0.0;
      for (var r = lc.row; r <= last; r++) {
        have += rowH[r];
      }
      final need = lc.contentHeight + LaidTable.vPad * 2;
      if (need > have) rowH[last] += need - have;
    }
    final rowY = <double>[0];
    for (final h in rowH) {
      rowY.add(rowY.last + h);
    }
    for (final lc in cells) {
      final span = lc.cell.rowSpan < 1 ? 1 : lc.cell.rowSpan;
      final last = math.min<int>(t.rows.length, lc.row + span);
      lc.rect = Rect.fromLTRB(lc.rect.left, rowY[lc.row], lc.rect.right, rowY[last]);
    }
    return LaidTable(
      table: t,
      width: width,
      x: x,
      tableWidth: total,
      rowY: rowY,
      cells: cells,
      padding: pad,
    );
  }
}

// ---------------------------------------------------------------------------
// Pagination

class DocPageSlice {
  DocPageSlice(this.blockIndex, this.offset, this.height, this.y);
  final int blockIndex;
  final double offset;
  final double height;
  final double y;
}

class DocPageLayout {
  DocPageLayout(this.setup);
  final DocPageSetup setup;
  final List<DocPageSlice> slices = [];
}

class DocLayoutResult {
  DocLayoutResult({
    required this.blocks,
    required this.pages,
    required this.header,
    required this.footer,
  });

  final List<LaidBlock> blocks;
  final List<DocPageLayout> pages;
  final List<LaidBlock> header;
  final List<LaidBlock> footer;

  /// Page index and y (within the page content) for [blockIndex] at
  /// [yInBlock].
  (int, double)? locate(int blockIndex, double yInBlock) {
    (int, double)? first;
    for (var p = 0; p < pages.length; p++) {
      for (final s in pages[p].slices) {
        if (s.blockIndex != blockIndex) continue;
        first ??= (p, s.y);
        if (yInBlock >= s.offset - 0.5 && yInBlock <= s.offset + s.height + 0.5) {
          return (p, s.y + (yInBlock - s.offset));
        }
      }
    }
    return first;
  }
}

/// Lays out [model] into print pages. Yields to the UI between batches so
/// big documents don't freeze it.
Future<DocLayoutResult> layoutDocument(
  DocModel model,
  DocRenderContext ctx, {
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
}) async {
  final engine = DocLayoutEngine(model, ctx);
  final blocks = model.blocks;

  // Page setup per block: a section break carries the setup of the section
  // it ends.
  final setups = List<DocPageSetup>.filled(blocks.length, model.page);
  var cur = model.page;
  for (var i = blocks.length - 1; i >= 0; i--) {
    final b = blocks[i];
    if (b is DocSectionBreak) cur = b.page;
    setups[i] = cur;
  }

  final spacing = engine._effectiveSpacing(blocks);
  final laid = <LaidBlock>[];
  final sw = Stopwatch()..start();
  for (var i = 0; i < blocks.length; i++) {
    laid.add(engine.layoutBlock(blocks[i], setups[i].contentWidth,
        spacing: spacing[i]));
    if (sw.elapsedMilliseconds > 12) {
      onProgress?.call(i / blocks.length);
      await Future<void>.delayed(Duration.zero);
      if (cancelled?.call() ?? false) break;
      sw.reset();
    }
  }

  final pages = <DocPageLayout>[];
  var setup = blocks.isEmpty ? model.page : setups.first;
  var page = DocPageLayout(setup);
  var y = 0.0;

  void newPage(DocPageSetup s) {
    pages.add(page);
    page = DocPageLayout(s);
    y = 0;
  }

  for (var i = 0; i < laid.length; i++) {
    final lb = laid[i];
    final s = setups[i];
    if (lb is LaidMarker) {
      if (lb.kind == LaidMarkerKind.pageBreak ||
          (lb.kind == LaidMarkerKind.sectionBreak && lb.newPage)) {
        newPage(i + 1 < setups.length ? setups[i + 1] : s);
      }
      continue;
    }
    final para = blocks[i] is DocParagraph ? blocks[i] as DocParagraph : null;
    if (para != null && para.pageBreakBefore && page.slices.isNotEmpty) {
      newPage(s);
    }
    var h = page.setup.contentHeight;
    // Keep headings with the next block.
    if (lb.keepWithNext && y > 0 && i + 1 < laid.length) {
      final next = laid[i + 1];
      final nextNeed = next.breaks.isNotEmpty ? next.breaks.first : next.height;
      if (y + lb.height + math.min(nextNeed, h * 0.5) > h && lb.height < h) {
        newPage(s);
      }
    }
    var off = 0.0;
    while (off < lb.contentEnd - 0.01) {
      h = page.setup.contentHeight;
      final remaining = lb.height - off;
      final space = h - y;
      if (remaining <= space + 0.5 || lb.contentEnd - off <= space + 0.5) {
        final take = math.min(remaining, math.max(space, lb.contentEnd - off));
        page.slices.add(DocPageSlice(i, off, take, y));
        y += take;
        break;
      }
      double? best;
      for (final b in lb.breaks) {
        if (b > off + 0.01 && b - off <= space + 0.5) best = b;
      }
      if (best != null) {
        page.slices.add(DocPageSlice(i, off, best - off, y));
        off = best;
        newPage(s);
        continue;
      }
      if (y > 0.5) {
        newPage(s);
        continue;
      }
      // Taller than a page with no break point: cut it.
      page.slices.add(DocPageSlice(i, off, space, y));
      off += space;
      newPage(s);
    }
  }
  pages.add(page);
  // Drop a trailing empty page created by a final break.
  if (pages.length > 1 && pages.last.slices.isEmpty) pages.removeLast();

  final hw = model.page.contentWidth;
  return DocLayoutResult(
    blocks: laid,
    pages: pages,
    header: engine.layoutBlocks(model.header, hw),
    footer: engine.layoutBlocks(model.footer, hw),
  );
}

/// Draws one print page at its natural size (points as logical pixels).
class DocPageView extends StatelessWidget {
  const DocPageView({
    super.key,
    required this.result,
    required this.pageIndex,
    required this.ctx,
  });

  final DocLayoutResult result;
  final int pageIndex;
  final DocRenderContext ctx;

  @override
  Widget build(BuildContext context) {
    final page = result.pages[pageIndex];
    final s = page.setup;
    final pctx = ctx.forPage(pageIndex + 1, result.pages.length);
    final children = <Widget>[];

    // Header from the header distance; footer ending at the footer distance.
    if (result.header.isNotEmpty) {
      var y = s.headerDistance;
      final hc = <Widget>[];
      for (final b in result.header) {
        hc.add(Positioned(
            left: 0, top: y - s.headerDistance, width: b.width, height: b.height,
            child: b.build(pctx)));
        y += b.height;
      }
      children.add(Positioned(
        left: s.marginLeft,
        top: s.headerDistance,
        width: s.contentWidth,
        height: math.max(0, s.height / 3),
        child: ClipRect(child: Stack(clipBehavior: Clip.none, children: hc)),
      ));
    }
    if (result.footer.isNotEmpty) {
      final total = result.footer.fold<double>(0, (a, b) => a + b.height);
      var y = 0.0;
      final fc = <Widget>[];
      for (final b in result.footer) {
        fc.add(Positioned(
            left: 0, top: y, width: b.width, height: b.height, child: b.build(pctx)));
        y += b.height;
      }
      final top = math.max(s.height * 0.6, s.height - s.footerDistance - total);
      children.add(Positioned(
        left: s.marginLeft,
        top: top,
        width: s.contentWidth,
        height: math.max(0, s.height - top),
        child: ClipRect(child: Stack(clipBehavior: Clip.none, children: fc)),
      ));
    }

    for (final slice in page.slices) {
      final b = result.blocks[slice.blockIndex];
      children.add(Positioned(
        left: s.marginLeft,
        top: s.marginTop + slice.y,
        width: s.contentWidth,
        height: math.max(0.0, slice.height),
        child: ClipRect(
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
              left: 0,
              top: -slice.offset,
              width: b.width,
              height: b.height,
              child: b.build(pctx, from: slice.offset, to: slice.offset + slice.height),
            ),
          ]),
        ),
      ));
    }
    return Container(
      width: s.width,
      height: s.height,
      color: ctx.pageColor,
      child: Stack(clipBehavior: Clip.hardEdge, children: children),
    );
  }
}
