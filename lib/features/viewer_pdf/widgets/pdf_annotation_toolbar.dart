import 'package:explorer/features/viewer_office/common/viewer_ui.dart';
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
    final colors = context.colors;
    final hint = hintFor(mode, selected);
    final compact = MediaQuery.sizeOf(context).width < 480;
    final size = compact ? 36.0 : 40.0;
    final iconSize = compact ? 18.0 : 20.0;

    Widget tool(PdfAnnotationMode value, IconData icon, String tooltip) {
      final active = mode == value;
      return ViewerAction(
        tooltip: tooltip,
        icon: icon,
        size: size,
        iconSize: iconSize,
        selected: active,
        onPressed: enabled
            ? () => onModeChanged(active ? PdfAnnotationMode.none : value)
            : null,
      );
    }

    Widget action(
      IconData icon,
      String tooltip,
      VoidCallback? onPressed, {
      bool destructive = false,
    }) {
      return ViewerAction(
        tooltip: tooltip,
        icon: icon,
        size: size,
        iconSize: iconSize,
        color: destructive && enabled && onPressed != null
            ? colors.destructive
            : null,
        onPressed: enabled ? onPressed : null,
      );
    }

    final selection = selected;
    final colorButton = IconButton(
      tooltip: selection != null ? 'Annotation colour' : 'Colour',
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: enabled && (selection == null || !selection.isLocked)
          ? onPickColor
          : null,
      icon: ViewerSwatch(color: color, size: iconSize),
    );
    final children = <Widget>[
      tool(PdfAnnotationMode.none, LucideIcons.mousePointer2, 'Select / scroll'),
      tool(PdfAnnotationMode.highlight, LucideIcons.highlighter, 'Highlight'),
      tool(PdfAnnotationMode.underline, LucideIcons.underline, 'Underline'),
      tool(
        PdfAnnotationMode.strikethrough,
        LucideIcons.strikethrough,
        'Strikethrough',
      ),
      tool(PdfAnnotationMode.squiggly, LucideIcons.spline, 'Squiggly underline'),
      tool(PdfAnnotationMode.stickyNote, LucideIcons.stickyNote, 'Sticky note'),
      ViewerToolDivider(spacing: compact ? 2 : 4),
      ViewerMenuButton<VoidCallback>(
        tooltip: 'Add to page',
        icon: LucideIcons.plus,
        size: size,
        enabled: enabled,
        minMenuWidth: 200,
        onSelected: (action) => action(),
        itemBuilder: (context) => [
          viewerMenuItem(
            value: onDraw,
            icon: LucideIcons.penTool,
            label: 'Draw on page',
          ),
          viewerMenuItem(value: onText, icon: LucideIcons.type, label: 'Add text'),
          viewerMenuItem(
            value: onImage,
            icon: LucideIcons.imagePlus,
            label: 'Add image or stamp',
          ),
          viewerMenuItem(
            value: onSignature,
            icon: LucideIcons.signature,
            label: 'Add signature',
          ),
        ],
      ),
      if (selection == null) colorButton,
    ];

    // Always visible on the right, even when the tools scroll.
    final pinned = <Widget>[
      if (selection != null) colorButton,
      if (selection is StickyNoteAnnotation)
        action(
          LucideIcons.squarePen,
          'Edit note',
          selection.isLocked ? null : onEditNote,
        ),
      if (selection != null)
        action(
          LucideIcons.trash2,
          'Delete annotation',
          selection.isLocked ? null : onDeleteSelected,
          destructive: true,
        ),
      action(LucideIcons.undo2, 'Undo', canUndo ? onUndo : null),
      action(LucideIcons.redo2, 'Redo', canRedo ? onRedo : null),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ViewerPill(text: hint),
          ),
        AppPanel(
          translucent: true,
          padding: const EdgeInsets.all(4),
          child: Material(
            type: MaterialType.transparency,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: children,
                    ),
                  ),
                ),
                ViewerToolDivider(spacing: compact ? 2 : 4),
                ...pinned,
              ],
            ),
          ),
        ),
      ],
    );
  }
}
