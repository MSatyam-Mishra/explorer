import 'package:flutter/material.dart';

import '../book/book_models.dart';
import '../book/book_source.dart';

/// Holds the last search so reopening the sheet shows previous results.
class ReaderSearchController extends ChangeNotifier {
  String query = '';
  List<SearchHit> results = const [];
  bool searching = false;
  bool truncated = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;

  static const maxResults = 500;

  Future<void> run(BookSource source, String text) async {
    final q = text.trim();
    final gen = ++_generation;
    query = q;
    error = null;
    if (q.isEmpty) {
      results = const [];
      searching = false;
      _notify();
      return;
    }
    searching = true;
    _notify();
    try {
      final hits = await source.search(q, maxResults: maxResults);
      if (gen != _generation) return;
      results = hits;
      truncated = hits.length >= maxResults;
    } catch (e) {
      if (gen != _generation) return;
      results = const [];
      error = 'Search failed: $e';
    }
    searching = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ReaderSearchSheet extends StatefulWidget {
  const ReaderSearchSheet({
    super.key,
    required this.controller,
    required this.source,
    required this.titleForSpine,
    required this.onSelect,
  });

  final ReaderSearchController controller;
  final BookSource source;
  final String Function(int spineIndex) titleForSpine;
  final ValueChanged<SearchHit> onSelect;

  static Future<void> show(
    BuildContext context, {
    required ReaderSearchController controller,
    required BookSource source,
    required String Function(int spineIndex) titleForSpine,
    required ValueChanged<SearchHit> onSelect,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (sheetContext) => ReaderSearchSheet(
        controller: controller,
        source: source,
        titleForSpine: titleForSpine,
        onSelect: (hit) {
          Navigator.of(sheetContext).pop();
          onSelect(hit);
        },
      ),
    );
  }

  @override
  State<ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<ReaderSearchSheet> {
  late final TextEditingController _text =
      TextEditingController(text: widget.controller.query);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => widget.controller.run(widget.source, _text.text);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: media.size.height * 0.82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _text,
                autofocus: widget.controller.results.isEmpty,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: 'Search in book',
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _submit,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final c = widget.controller;
                  if (c.searching) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (c.error != null) {
                    return Center(child: Text(c.error!));
                  }
                  if (c.query.isEmpty) {
                    return Center(
                      child: Text(
                        'Type a word or phrase and press search.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  if (c.results.isEmpty) {
                    return Center(child: Text('No matches for "${c.query}".'));
                  }
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            c.truncated
                                ? 'First ${c.results.length} matches'
                                : '${c.results.length} match${c.results.length == 1 ? '' : 'es'}',
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          itemCount: c.results.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 16),
                          itemBuilder: (context, i) =>
                              _hitTile(context, c.results[i]),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hitTile(BuildContext context, SearchHit hit) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    return ListTile(
      title: Text(
        widget.titleForSpine(hit.spineIndex),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
      subtitle: Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: hit.before),
            TextSpan(
              text: hit.match,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                backgroundColor:
                    theme.colorScheme.tertiaryContainer.withValues(alpha: 0.8),
              ),
            ),
            TextSpan(text: hit.after),
          ],
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => widget.onSelect(hit),
    );
  }
}
