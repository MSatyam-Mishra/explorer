import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';

/// Floating card showing a running file operation (copy, move…).
///
/// Returns a [Positioned], so place it directly in a [Stack]: it sits at the
/// bottom of the stack, full width on phones and bottom-right on wide
/// screens. The cancel / hide buttons only appear when their callbacks are
/// given.
class ProgressCard extends StatelessWidget {
  final String title;
  final String message;
  final double progress;
  final VoidCallback? onCancel;
  final VoidCallback? onHide;

  const ProgressCard({
    super.key,
    required this.title,
    required this.message,
    required this.progress,
    this.onCancel,
    this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final bottom = MediaQuery.paddingOf(context).bottom + 16;
    final value = progress.isFinite ? progress.clamp(0.0, 1.0) : null;
    final percent = value == null ? null : '${(value * 100).round()}%';

    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom,
      child: Align(
        alignment: Alignment.bottomRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AppPanel(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                    ),
                    if (percent != null)
                      Text(
                        percent,
                        style: text.labelMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: value, minHeight: 6),
                if (onCancel != null || onHide != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (onHide != null)
                        TextButton(
                          onPressed: onHide,
                          child: const Text('Hide'),
                        ),
                      if (onCancel != null) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: onCancel,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
