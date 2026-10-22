import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// shadcn-style dropdown menus (compact rows, muted icons, check marks)
/// anchored under the widget that opened them.
abstract final class ExplorerMenu {
  /// Opens [items] under the widget owning [anchorContext].
  static Future<T?> show<T>(
    BuildContext anchorContext, {
    required List<PopupMenuEntry<T>> items,
    double minWidth = 200,
  }) {
    final anchor = anchorContext.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(anchorContext).overlay!.context
        .findRenderObject()! as RenderBox;
    final gap = Offset(0, anchor.size.height + 4);
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        anchor.localToGlobal(gap, ancestor: overlay),
        anchor.localToGlobal(
          anchor.size.bottomRight(Offset.zero) + gap,
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    return showMenu<T>(
      context: anchorContext,
      position: position,
      items: items,
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: 320),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
    );
  }

  /// Opens [items] at [globalPosition], e.g. where a right-click happened.
  static Future<T?> showAt<T>(
    BuildContext context,
    Offset globalPosition, {
    required List<PopupMenuEntry<T>> items,
    double minWidth = 220,
  }) {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(globalPosition);
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        point & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: 320),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
    );
  }

  /// A row with an optional leading icon, and a trailing check mark or
  /// keyboard [shortcut] hint ("Ctrl+C").
  static PopupMenuItem<T> item<T>(
    BuildContext context, {
    required T value,
    required String label,
    IconData? icon,
    String? shortcut,
    bool checked = false,
    bool destructive = false,
    bool enabled = true,
  }) {
    final colors = context.colors;
    final fg = destructive ? colors.destructive : colors.popoverForeground;
    return PopupMenuItem<T>(
      value: value,
      enabled: enabled,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 16,
              color: destructive ? colors.destructive : colors.mutedForeground,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: enabled ? fg : colors.mutedForeground),
            ),
          ),
          if (checked) ...[
            const SizedBox(width: 12),
            Icon(LucideIcons.check, size: 16, color: colors.foreground),
          ],
          if (shortcut != null) ...[
            const SizedBox(width: 16),
            Text(
              shortcut,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }

  /// Muted heading inside a menu ("Sort by").
  static PopupMenuItem<T> label<T>(BuildContext context, String text) {
    return PopupMenuItem<T>(
      enabled: false,
      height: 28,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }

  static PopupMenuEntry<T> divider<T>() => const PopupMenuDivider(height: 9);
}
