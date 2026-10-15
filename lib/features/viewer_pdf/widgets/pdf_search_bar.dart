import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// Floating find bar: query field, match count, previous/next and options.
class PdfSearchBar extends StatelessWidget {
  const PdfSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.result,
    required this.searching,
    required this.matchCase,
    required this.wholeWords,
    required this.onSubmitted,
    required this.onOptionsChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final PdfTextSearchResult? result;

  /// True when a query was submitted and results are pending.
  final bool searching;
  final bool matchCase;
  final bool wholeWords;
  final ValueChanged<String> onSubmitted;
  final void Function({bool? matchCase, bool? wholeWords}) onOptionsChanged;
  final VoidCallback onClose;

  static const _compactButton = BoxConstraints(minWidth: 36, minHeight: 40);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 420;
    return Material(
      elevation: 6,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            const SizedBox(width: 12),
            if (!compact) ...[
              Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: onSubmitted,
                decoration: const InputDecoration(
                  hintText: 'Find in document',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            _ResultLabel(result: result, searching: searching),
            _buildNavigation(),
            PopupMenuButton<String>(
              tooltip: 'Search options',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 180),
              icon: const Icon(Icons.tune, size: 20),
              onSelected: (value) => value == 'case'
                  ? onOptionsChanged(matchCase: !matchCase)
                  : onOptionsChanged(wholeWords: !wholeWords),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: 'case',
                  checked: matchCase,
                  child: const Text('Match case'),
                ),
                CheckedPopupMenuItem(
                  value: 'words',
                  checked: wholeWords,
                  child: const Text('Whole words'),
                ),
              ],
            ),
            IconButton(
              tooltip: 'Close search',
              constraints: _compactButton,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close, size: 20),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    final result = this.result;
    if (result == null) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Previous match',
            constraints: _compactButton,
            padding: EdgeInsets.zero,
            icon: Icon(Icons.keyboard_arrow_up),
            onPressed: null,
          ),
          IconButton(
            tooltip: 'Next match',
            constraints: _compactButton,
            padding: EdgeInsets.zero,
            icon: Icon(Icons.keyboard_arrow_down),
            onPressed: null,
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: result,
      builder: (context, _) {
        final enabled = result.hasResult && result.totalInstanceCount > 0;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Previous match',
              constraints: _compactButton,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: enabled ? result.previousInstance : null,
            ),
            IconButton(
              tooltip: 'Next match',
              constraints: _compactButton,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: enabled ? result.nextInstance : null,
            ),
          ],
        );
      },
    );
  }
}

class _ResultLabel extends StatelessWidget {
  const _ResultLabel({required this.result, required this.searching});

  final PdfTextSearchResult? result;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    final result = this.result;
    if (result == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: result,
      builder: (context, _) {
        String text;
        if (result.hasResult && result.totalInstanceCount > 0) {
          text = '${result.currentInstanceIndex}/${result.totalInstanceCount}';
          if (!result.isSearchCompleted) text += '+';
        } else if (result.isSearchCompleted || !searching) {
          text = 'No matches';
        } else {
          text = 'Searching…';
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(text, style: style),
        );
      },
    );
  }
}
