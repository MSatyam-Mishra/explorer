import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// Compact toolbar shown in edit mode.
///
/// Text markup and sticky notes are live viewer annotations. Drawing, text
/// boxes, images and signatures open the page canvas editor.
class PdfAnnotationToolbar extends StatelessWidget {
  const PdfAnnotationToolbar({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.color,
    required this.onPickColor,
    required this.onDraw,
    required this.onText,
    required this.onImage,
    required this.onSignature,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.selected,
    required this.onDeleteSelected,
    required this.onEditNote,
    this.enabled = true,
  });

  final PdfAnnotationMode mode;
  final ValueChanged<PdfAnnotationMode> onModeChanged;
  final Color color;
  final VoidCallback onPickColor;
  final VoidCallback onDraw;
  final VoidCallback onText;
  final VoidCallback onImage;
  final VoidCallback onSignature;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final Annotation? selected;
  final VoidCallback onDeleteSelected;
  final VoidCallback onEditNote;
  final bool enabled;

  static String? hintFor(PdfAnnotationMode mode, Annotation? selected) {
    if (selected != null) {
      return selected.isLocked
          ? 'This annotation is locked'
          : 'Annotation selected: change its colour or delete it';
    }
    return switch (mode) {
      PdfAnnotationMode.highlight => 'Drag across text to highlight it',
      PdfAnnotationMode.underline => 'Drag across text to underline it',
      PdfAnnotationMode.strikethrough => 'Drag across text to strike it out',
      PdfAnnotationMode.squiggly => 'Drag across text to add a squiggly line',
      PdfAnnotationMode.stickyNote => 'Tap the page where the note goes',
      PdfAnnotationMode.none => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = hintFor(mode, selected);

    Widget tool(PdfAnnotationMode value, IconData icon, String tooltip) {
      final active = mode == value;
      return IconButton(
        tooltip: tooltip,
        isSelected: active,
        onPressed: enabled
            ? () => onModeChanged(active ? PdfAnnotationMode.none : value)
            : null,
        style: active
            ? IconButton.styleFrom(
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
              )
            : null,
        icon: Icon(icon),
      );
    }

    Widget action(IconData icon, String tooltip, VoidCallback? onPressed) {
      return IconButton(
        tooltip: tooltip,
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon),
      );
    }

    final divider = SizedBox(
      height: 24,
      child: VerticalDivider(width: 12, color: scheme.outlineVariant),
    );

    final selection = selected;
    final children = <Widget>[
      tool(
        PdfAnnotationMode.none,
        Icons.pan_tool_alt_outlined,
        'Select / scroll',
      ),
      tool(
        PdfAnnotationMode.highlight,
        Icons.border_color_outlined,
        'Highlight',
      ),
      tool(PdfAnnotationMode.underline, Icons.format_underlined, 'Underline'),
      tool(
        PdfAnnotationMode.strikethrough,
        Icons.format_strikethrough,
        'Strikethrough',
      ),
      tool(PdfAnnotationMode.squiggly, Icons.waves, 'Squiggly underline'),
      tool(
        PdfAnnotationMode.stickyNote,
        Icons.sticky_note_2_outlined,
        'Sticky note',
      ),
      divider,
      action(Icons.brush_outlined, 'Draw on page', onDraw),
      action(Icons.text_fields, 'Add text', onText),
      action(Icons.add_photo_alternate_outlined, 'Add image or stamp', onImage),
      action(Icons.draw_outlined, 'Add signature', onSignature),
      divider,
      IconButton(
        tooltip: selection != null ? 'Annotation colour' : 'Colour',
        onPressed: enabled && (selection == null || !selection.isLocked)
            ? onPickColor
            : null,
        icon: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outline),
          ),
        ),
      ),
      if (selection is StickyNoteAnnotation)
        action(
          Icons.edit_note,
          'Edit note',
          selection.isLocked ? null : onEditNote,
        ),
      if (selection != null)
        action(
          Icons.delete_outline,
          'Delete annotation',
          selection.isLocked ? null : onDeleteSelected,
        ),
      action(Icons.undo, 'Undo', canUndo ? onUndo : null),
      action(Icons.redo, 'Redo', canRedo ? onRedo : null),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: scheme.inverseSurface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  hint,
                  style: TextStyle(
                    color: scheme.onInverseSurface,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        Material(
          elevation: 6,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ],
    );
  }
}
