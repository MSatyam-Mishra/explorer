import 'package:flutter/material.dart';

/// Loading card shown over the 3D canvas while a model is read and parsed.
///
/// Uses an opaque-ish surface instead of a blur because backdrop filters
/// can't sample platform views (the WebView) on Android.
class ViewerProgressCard extends StatelessWidget {
  const ViewerProgressCard({super.key, required this.label, this.progress});

  final String label;

  /// 0..1, or null for an indeterminate spinner.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = progress == null ? null : (progress! * 100).clamp(0, 100).round();
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      elevation: 6,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 4,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  Icon(Icons.view_in_ar_outlined, color: scheme.primary, size: 22),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              percent == null ? '$label…' : '$label  $percent%',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// Friendly error state with "Open with another app" and optional retry.
class ViewerErrorView extends StatelessWidget {
  const ViewerErrorView({
    super.key,
    required this.message,
    required this.onOpenWith,
    this.detail,
    this.onRetry,
  });

  final String message;
  final String? detail;
  final VoidCallback onOpenWith;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
          elevation: 6,
          shadowColor: Colors.black45,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.view_in_ar_outlined, size: 48, color: scheme.error),
                const SizedBox(height: 12),
                Text(
                  "Can't display this model",
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (detail != null && detail!.trim().isNotEmpty && detail != message)
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        'Technical details',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      children: [
                        SelectableText(
                          detail!,
                          maxLines: 8,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onRetry != null)
                      OutlinedButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    FilledButton.icon(
                      onPressed: onOpenWith,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open with another app'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
