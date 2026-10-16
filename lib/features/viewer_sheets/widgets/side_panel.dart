import 'package:flutter/material.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/input_parser.dart' show formulaDisplayText;
import '../model/workbook.dart';
import 'format_toolbar.dart' show numberFormatLabel;
import 'status_bar.dart' show formatStat;

/// Docked pane for wide screens: sheet list and a cell inspector.
class SheetSidePanel extends StatelessWidget {
  const SheetSidePanel({
    super.key,
    required this.controller,
    required this.onTabMenu,
    this.onAdd,
  });

  final SpreadsheetController controller;
  final void Function(int index, Offset globalPosition) onTabMenu;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final wb = controller.workbook;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text('Sheets', style: theme.textTheme.titleSmall)),
                      if (onAdd != null)
                        IconButton(
                          tooltip: 'Add sheet',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add_rounded),
                          onPressed: onAdd,
                        ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: wb.sheets.length,
                itemBuilder: (context, i) {
                  final s = wb.sheets[i];
                  final hidden = s.visibility != SheetVisibility.visible;
                  return GestureDetector(
                    onSecondaryTapUp: (d) => onTabMenu(i, d.globalPosition),
                    onLongPressStart: (d) => onTabMenu(i, d.globalPosition),
                    child: ListTile(
                      dense: true,
                      selected: i == wb.activeSheet,
                      selectedTileColor: scheme.primary.withValues(alpha: 0.1),
                      leading: Icon(hidden ? Icons.visibility_off_outlined : Icons.grid_on_rounded, size: 18),
                      title: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: hidden ? const TextStyle(fontStyle: FontStyle.italic) : null,
                      ),
                      subtitle: Text(
                        s.usedRows == 0 ? 'Empty' : '${s.usedRows} rows · ${s.usedCols} columns',
                        maxLines: 1,
                      ),
                      onTap: () => controller.activateSheet(i),
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(child: Divider(height: 24)),
              SliverToBoxAdapter(child: _Inspector(controller: controller)),
            ],
          );
        },
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({required this.controller});
  final SpreadsheetController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final cell = c.activeCell;
    final st = cell?.style ?? CellStyle.plain;
    final v = cell?.value;
    final type = cell == null || cell.isBlank
        ? 'Empty'
        : cell.formula != null
            ? 'Formula'
            : v is double
                ? (numberFormatLabel(st.numFmt) == 'Date' ? 'Date' : 'Number')
                : v is bool
                    ? 'Boolean'
                    : v is CellError
                        ? 'Error'
                        : 'Text';
    final rows = <(String, String)>[
      ('Cell', '${c.sheet.name}!${cellName(c.selRow, c.selCol)}'),
      ('Type', type),
      if (cell?.formula != null) ('Formula', formulaDisplayText(cell!.formula!)),
      if (v != null) ('Value', v is double ? v.toString() : v.toString()),
      if (v != null) ('Shows', c.display(cell).text),
      ('Format', '${numberFormatLabel(st.numFmt)}${st.numFmt == 'General' ? '' : '  (${st.numFmt})'}'),
      if (st.bold || st.italic || st.underline)
        ('Font', [if (st.bold) 'Bold', if (st.italic) 'Italic', if (st.underline) 'Underline'].join(', ')),
      if (st.fontColor != null) ('Text color', _hex(st.fontColor!)),
      if (st.fillColor != null) ('Fill', _hex(st.fillColor!)),
      if (st.hAlign != HAlign.general) ('Align', st.hAlign.name),
      if (c.sheet.mergeAt(c.selRow, c.selCol) != null) ('Merged', c.sheet.mergeAt(c.selRow, c.selCol)!.toA1()),
    ];
    final stats = c.selectionStats();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cell', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final (k, val) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(k, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(child: SelectableText(val, style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          if (stats.cells > 1) ...[
            const SizedBox(height: 16),
            Text('Selection', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              [
                '${stats.cells} cells, ${stats.count} with values',
                if (stats.numericCount > 0) 'Sum ${formatStat(stats.sum)}',
                if (stats.numericCount > 0) 'Average ${formatStat(stats.average!)}',
                if (stats.numericCount > 0) 'Min ${formatStat(stats.min!)} · Max ${formatStat(stats.max!)}',
              ].join('\n'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  static String _hex(int c) => '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
