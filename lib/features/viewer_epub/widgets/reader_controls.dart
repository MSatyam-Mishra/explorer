import 'package:flutter/material.dart';

import '../reader/reader_settings.dart';

/// Always-visible slim status line under the page.
class ReaderFooter extends StatelessWidget {
  const ReaderFooter({
    super.key,
    required this.theme,
    required this.title,
    required this.status,
  });

  final ReaderTheme theme;
  final String title;
  final String status;

  static const height = 26.0;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: theme.foreground.withValues(alpha: 0.62),
      fontSize: 12,
    );
    return Container(
      color: theme.background,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 12),
          Text(status, style: style),
        ],
      ),
    );
  }
}

/// Bottom controls shown when the centre of the page is tapped: chapter
/// title, page in chapter, overall progress and a scrubber.
class ReaderControlsPanel extends StatelessWidget {
  const ReaderControlsPanel({
    super.key,
    required this.theme,
    required this.title,
    required this.detail,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.labelFor,
    this.onPrevChapter,
    this.onNextChapter,
  });

  final ReaderTheme theme;
  final String title;
  final String detail;

  /// Overall progress 0..1.
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String Function(double) labelFor;
  final VoidCallback? onPrevChapter;
  final VoidCallback? onNextChapter;

  @override
  Widget build(BuildContext context) {
    final fg = theme.foreground;
    final accent = theme.link;
    return Material(
      color: Color.alphaBlend(
        (theme.isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
        theme.background,
      ),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous chapter',
                  color: fg,
                  disabledColor: fg.withValues(alpha: 0.3),
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: onPrevChapter,
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: accent,
                      inactiveTrackColor: fg.withValues(alpha: 0.2),
                      thumbColor: accent,
                      overlayColor: accent.withValues(alpha: 0.15),
                      valueIndicatorColor: accent,
                    ),
                    child: Slider(
                      value: value.clamp(0.0, 1.0),
                      label: labelFor(value),
                      divisions: 1000,
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next chapter',
                  color: fg,
                  disabledColor: fg.withValues(alpha: 0.3),
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: onNextChapter,
                ),
              ],
            ),
            Text(
              detail,
              style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
