import 'package:flutter/material.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import 'color_palette.dart';
import 'text_prompt.dart';

/// Number format presets offered in the toolbar.
const kNumberFormatPresets = <(String, String)>[
  ('General', 'General'),
  ('Number', '#,##0.00'),
  ('Currency', r'"$"#,##0.00'),
  ('Percent', '0.00%'),
  ('Date', 'yyyy-mm-dd'),
  ('Date & time', 'yyyy-mm-dd h:mm'),
  ('Time', 'h:mm:ss'),
  ('Scientific', '0.00E+00'),
  ('Text', '@'),
];

String numberFormatLabel(String code) {
  for (final p in kNumberFormatPresets) {
    if (p.$2 == code) return p.$1;
  }
  if (NumberFormats.isDateFormat(code)) {
    return NumberFormats.isTimeOnlyFormat(code) ? 'Time' : 'Date';
  }
  if (code.contains('%')) return 'Percent';
  if (code.contains(r'$') || code.contains('€') || code.contains('£')) return 'Currency';
  if (code == '@') return 'Text';
  return 'Custom';
}

/// Cell formatting controls: bold/italic/underline, colours, alignment,
/// wrap, number format, decimals and merge.
class FormatToolbar extends StatelessWidget {
  const FormatToolbar({
    super.key,
    required this.controller,
    this.showUndoRedo = false,
    this.scrollable = true,
  });

  final SpreadsheetController controller;
  final bool showUndoRedo;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final st = c.activeStyle;
        final scheme = Theme.of(context).colorScheme;
        final items = <Widget>[
          if (showUndoRedo) ...[
            _ToolButton(
              icon: Icons.undo_rounded,
              tooltip: c.undoLabel == null ? 'Undo' : 'Undo ${c.undoLabel}',
              onPressed: c.canUndo ? c.undo : null,
            ),
            _ToolButton(
              icon: Icons.redo_rounded,
              tooltip: c.redoLabel == null ? 'Redo' : 'Redo ${c.redoLabel}',
              onPressed: c.canRedo ? c.redo : null,
            ),
            const _Sep(),
          ],
          _ToolButton(icon: Icons.format_bold_rounded, tooltip: 'Bold', selected: st.bold, onPressed: c.toggleBold),
          _ToolButton(icon: Icons.format_italic_rounded, tooltip: 'Italic', selected: st.italic, onPressed: c.toggleItalic),
          _ToolButton(
            icon: Icons.format_underlined_rounded,
            tooltip: 'Underline',
            selected: st.underline,
            onPressed: c.toggleUnderline,
          ),
          _ColorButton(
            icon: Icons.format_color_text_rounded,
            tooltip: 'Text color',
            color: st.fontColor == null ? scheme.onSurface : Color(st.fontColor!),
            onPressed: () async {
              final choice = await showColorPalette(context,
                  title: 'Text color', noneLabel: 'Automatic', current: st.fontColor);
              if (choice != null) c.setFontColor(choice.color);
            },
          ),
          _ColorButton(
            icon: Icons.format_color_fill_rounded,
            tooltip: 'Fill color',
            color: st.fillColor == null ? Colors.transparent : Color(st.fillColor!),
            onPressed: () async {
              final choice = await showColorPalette(context,
                  title: 'Fill color', noneLabel: 'No fill', current: st.fillColor);
              if (choice != null) c.setFillColor(choice.color);
            },
          ),
          const _Sep(),
          _ToolButton(
            icon: Icons.format_align_left_rounded,
            tooltip: 'Align left',
            selected: st.hAlign == HAlign.left,
            onPressed: () => c.setAlignment(st.hAlign == HAlign.left ? HAlign.general : HAlign.left),
          ),
          _ToolButton(
            icon: Icons.format_align_center_rounded,
            tooltip: 'Center',
            selected: st.hAlign == HAlign.center,
            onPressed: () => c.setAlignment(st.hAlign == HAlign.center ? HAlign.general : HAlign.center),
          ),
          _ToolButton(
            icon: Icons.format_align_right_rounded,
            tooltip: 'Align right',
            selected: st.hAlign == HAlign.right,
            onPressed: () => c.setAlignment(st.hAlign == HAlign.right ? HAlign.general : HAlign.right),
          ),
          _ToolButton(icon: Icons.wrap_text_rounded, tooltip: 'Wrap text', selected: st.wrap, onPressed: c.toggleWrap),
          _ToolButton(
            icon: c.selectionHasMerge ? Icons.call_split_rounded : Icons.merge_type_rounded,
            tooltip: c.selectionHasMerge ? 'Unmerge cells' : 'Merge cells',
            onPressed: c.selectionHasMerge
                ? c.unmergeSelection
                : (c.selection.isSingle ? null : c.mergeSelection),
          ),
          const _Sep(),
          _NumberFormatButton(controller: c, current: st.numFmt),
          _ToolButton(
            icon: Icons.exposure_neg_1_rounded,
            tooltip: 'Decrease decimals',
            onPressed: () => c.changeDecimals(-1),
          ),
          _ToolButton(
            icon: Icons.exposure_plus_1_rounded,
            tooltip: 'Increase decimals',
            onPressed: () => c.changeDecimals(1),
          ),
        ];
        final row = Row(mainAxisSize: MainAxisSize.min, children: items);
        if (!scrollable) return row;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: row,
        );
      },
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: Theme.of(context).colorScheme.outlineVariant,
      );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      style: IconButton.styleFrom(
        backgroundColor: selected ? scheme.primary.withValues(alpha: 0.14) : null,
        foregroundColor: selected ? scheme.primary : scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.onSurface),
          const SizedBox(height: 1),
          Container(
            width: 18,
            height: 4,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
              border: Border.all(color: scheme.outlineVariant, width: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberFormatButton extends StatelessWidget {
  const _NumberFormatButton({required this.controller, required this.current});

  final SpreadsheetController controller;
  final String current;

  @override
  Widget build(BuildContext context) {
    final label = numberFormatLabel(current);
    return PopupMenuButton<String>(
      tooltip: 'Number format',
      onSelected: (code) async {
        if (code == '__custom') {
          final custom = await _askCustom(context, current);
          if (custom != null && custom.isNotEmpty) controller.setNumberFormat(custom);
        } else {
          controller.setNumberFormat(code);
        }
      },
      itemBuilder: (context) => [
        for (final p in kNumberFormatPresets)
          CheckedPopupMenuItem<String>(
            value: p.$2,
            checked: p.$2 == current,
            child: Row(
              children: [
                Expanded(child: Text(p.$1)),
                Text(
                  _sample(p.$2),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: '__custom', child: Text('Custom format…')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.onetwothree_rounded, size: 22),
            const SizedBox(width: 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 76),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.arrow_drop_down_rounded, size: 20),
          ],
        ),
      ),
    );
  }

  static String _sample(String code) {
    if (code == 'General') return '1234.5';
    if (code == '@') return 'abc';
    final v = NumberFormats.isDateFormat(code) ? 45322.5625 : 1234.5;
    return NumberFormats.format(code == '0.00%' ? 0.125 : v, code).text;
  }

  Future<String?> _askCustom(BuildContext context, String current) => showTextPrompt(
        context,
        title: 'Custom number format',
        initial: current,
        label: 'Format code',
        helper: 'e.g. #,##0.000  or  dd/mm/yyyy',
        action: 'Apply',
      );
}
