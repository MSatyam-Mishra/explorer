import 'package:explorer/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:explorer/features/viewer_pdf/services/pdf_page_rasterizer.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_page_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Page organiser: select, reorder (drag or move up/down), rotate, delete and
/// insert blank pages. Changes are collected locally and applied in one go
/// with [onApply]; extracting and inserting another PDF act immediately.
class PdfPageManager extends StatefulWidget {
  const PdfPageManager({
    super.key,
    required this.metas,
    required this.rasterizer,
    required this.currentPage,
    required this.busy,
    required this.onOpenPage,
    required this.onApply,
    required this.onExtract,
    required this.onInsertPdf,
    required this.onNeedData,
  });

  /// Pages of the current document; null while loading.
  final List<PdfPageMeta>? metas;
  final PdfPageRasterizer? rasterizer;

  /// 1-based page shown in the viewer.
  final ValueListenable<int> currentPage;
  final bool busy;
  final ValueChanged<int> onOpenPage;
  final ValueChanged<List<PagePlanEntry>> onApply;
  final ValueChanged<Set<int>> onExtract;
  final VoidCallback onInsertPdf;

  /// Asks the owner to load [metas]/[rasterizer]; called while they're null
  /// and the manager is on screen.
  final VoidCallback onNeedData;

  @override
  State<PdfPageManager> createState() => _PdfPageManagerState();
}

class _PlanItem {
  _PlanItem(this.id, this.entry);

  final int id;
  PagePlanEntry entry;
}

enum _MoreAction { moveUp, moveDown, moveFirst, moveLast, extract, insertPdf }

class _PdfPageManagerState extends State<PdfPageManager> {
  List<_PlanItem> _items = [];
  final Set<int> _selected = {};
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    _reset();
    _requestDataIfNeeded();
  }

  @override
  void didUpdateWidget(PdfPageManager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.metas, widget.metas)) _reset();
    _requestDataIfNeeded();
  }

  void _requestDataIfNeeded() {
    if (widget.metas != null && widget.rasterizer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onNeedData();
    });
  }

  void _reset() {
    final metas = widget.metas ?? const <PdfPageMeta>[];
    _nextId = 0;
    _items = [
      for (var i = 0; i < metas.length; i++)
        _PlanItem(_nextId++, PagePlanEntry.source(i)),
    ];
    _selected.clear();
  }

  bool get _hasChanges {
    final metas = widget.metas;
    if (metas == null) return false;
    if (_items.length != metas.length) return true;
    for (var i = 0; i < _items.length; i++) {
      final entry = _items[i].entry;
      if (entry.isBlank || entry.sourceIndex != i || entry.quarterTurns != 0) {
        return true;
      }
    }
    return false;
  }

  List<int> get _selectedPositions => [
    for (var i = 0; i < _items.length; i++)
      if (_selected.contains(_items[i].id)) i,
  ];

  void _toggle(_PlanItem item) => setState(() {
    if (!_selected.remove(item.id)) _selected.add(item.id);
  });

  void _rotateSelected(int turns) => setState(() {
    for (final item in _items) {
      if (_selected.contains(item.id)) {
        item.entry = item.entry.rotated(turns);
      }
    }
  });

  void _deleteSelected() {
    if (_selected.length >= _items.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A PDF needs at least one page')),
      );
      return;
    }
    setState(() {
      _items.removeWhere((item) => _selected.contains(item.id));
      _selected.clear();
    });
  }

  void _insertBlank() {
    final positions = _selectedPositions;
    final metas = widget.metas ?? const <PdfPageMeta>[];
    final at = positions.isEmpty ? _items.length : positions.last + 1;
    final neighbour = _items.isEmpty
        ? null
        : _items[(at - 1).clamp(0, _items.length - 1)];
    var size = const Size(595, 842);
    final source = neighbour?.entry.sourceIndex;
    if (neighbour != null && neighbour.entry.isBlank) {
      size = neighbour.entry.blankSize!;
    } else if (source != null && source < metas.length) {
      size = metas[source].displaySize;
      if ((neighbour!.entry.quarterTurns).isOdd) size = size.flipped;
    }
    setState(() {
      final item = _PlanItem(_nextId++, PagePlanEntry.blank(size));
      _items.insert(at, item);
      _selected
        ..clear()
        ..add(item.id);
    });
  }

  void _move(_MoreAction action) {
    final positions = _selectedPositions;
    if (positions.isEmpty) return;
    setState(() {
      final moving = [for (final i in positions) _items[i]];
      switch (action) {
        case _MoreAction.moveFirst:
          _items.removeWhere(moving.contains);
          _items.insertAll(0, moving);
        case _MoreAction.moveLast:
          _items.removeWhere(moving.contains);
          _items.addAll(moving);
        case _MoreAction.moveUp:
          for (final i in positions) {
            if (i == 0 || _selected.contains(_items[i - 1].id)) continue;
            final item = _items.removeAt(i);
            _items.insert(i - 1, item);
          }
        case _MoreAction.moveDown:
          for (final i in positions.reversed) {
            if (i >= _items.length - 1 ||
                _selected.contains(_items[i + 1].id)) {
              continue;
            }
            final item = _items.removeAt(i);
            _items.insert(i + 1, item);
          }
        default:
          break;
      }
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
  }

  void _onMore(_MoreAction action) {
    switch (action) {
      case _MoreAction.extract:
        final pages = {
          for (final item in _items)
            if (_selected.contains(item.id) && !item.entry.isBlank)
              item.entry.sourceIndex!,
        };
        if (pages.isNotEmpty) widget.onExtract(pages);
      case _MoreAction.insertPdf:
        widget.onInsertPdf();
      default:
        _move(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metas = widget.metas;
    if (metas == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final scheme = Theme.of(context).colorScheme;
    final hasSelection = _selected.isNotEmpty;
    final hasChanges = _hasChanges;
    final enabled = !widget.busy;
    final selectedRealPages = _items.any(
      (item) => _selected.contains(item.id) && !item.entry.isBlank,
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: hasSelection ? 'Clear selection' : 'Select all',
            icon: Icon(hasSelection ? Icons.deselect : Icons.select_all),
            onPressed: enabled
                ? () => setState(() {
                    if (hasSelection) {
                      _selected.clear();
                    } else {
                      _selected.addAll(_items.map((item) => item.id));
                    }
                  })
                : null,
          ),
          Expanded(
            child: Text(
              hasSelection
                  ? '${_selected.length} selected'
                  : '${_items.length} pages',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          IconButton(
            tooltip: 'Rotate left',
            icon: const Icon(Icons.rotate_left),
            onPressed: enabled && hasSelection
                ? () => _rotateSelected(3)
                : null,
          ),
          IconButton(
            tooltip: 'Rotate right',
            icon: const Icon(Icons.rotate_right),
            onPressed: enabled && hasSelection
                ? () => _rotateSelected(1)
                : null,
          ),
          IconButton(
            tooltip: 'Delete pages',
            icon: const Icon(Icons.delete_outline),
            onPressed: enabled && hasSelection ? _deleteSelected : null,
          ),
          IconButton(
            tooltip: hasSelection
                ? 'Insert blank page after selection'
                : 'Add blank page at the end',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: enabled ? _insertBlank : null,
          ),
          PopupMenuButton<_MoreAction>(
            tooltip: 'More page actions',
            enabled: enabled,
            onSelected: _onMore,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _MoreAction.moveUp,
                enabled: hasSelection,
                child: const Text('Move up'),
              ),
              PopupMenuItem(
                value: _MoreAction.moveDown,
                enabled: hasSelection,
                child: const Text('Move down'),
              ),
              PopupMenuItem(
                value: _MoreAction.moveFirst,
                enabled: hasSelection,
                child: const Text('Move to start'),
              ),
              PopupMenuItem(
                value: _MoreAction.moveLast,
                enabled: hasSelection,
                child: const Text('Move to end'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _MoreAction.extract,
                enabled: selectedRealPages && !hasChanges,
                child: Text(
                  hasChanges
                      ? 'Extract (apply changes first)'
                      : 'Extract to new PDF',
                ),
              ),
              PopupMenuItem(
                value: _MoreAction.insertPdf,
                enabled: !hasChanges,
                child: const Text('Insert PDF…'),
              ),
            ],
          ),
        ],
      ),
    );

    final list = ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _items.length,
      onReorderItem: enabled ? _onReorder : (_, _) {},
      itemBuilder: (context, index) {
        final item = _items[index];
        final entry = item.entry;
        final source = entry.sourceIndex;
        final meta = source != null && source < metas.length
            ? metas[source]
            : null;
        final selected = _selected.contains(item.id);
        final notes = <String>[
          if (entry.isBlank) 'New blank page',
          if (source != null && source != index) 'Was page ${source + 1}',
          if (entry.quarterTurns != 0) 'Rotated ${entry.quarterTurns * 90}°',
        ];
        return Material(
          key: ValueKey(item.id),
          color: selected
              ? scheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          child: InkWell(
            onTap: !enabled
                ? null
                : hasSelection
                ? () => _toggle(item)
                : source != null
                ? () => widget.onOpenPage(source)
                : null,
            onLongPress: enabled ? () => _toggle(item) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: enabled ? (_) => _toggle(item) : null,
                  ),
                  SizedBox(
                    width: 76,
                    child: Center(
                      child: ValueListenableBuilder<int>(
                        valueListenable: widget.currentPage,
                        builder: (context, current, _) => PdfPageThumbnail(
                          rasterizer: widget.rasterizer,
                          pageNumber: source == null ? null : source + 1,
                          displaySize:
                              meta?.displaySize ??
                              entry.blankSize ??
                              const Size(595, 842),
                          width: 56,
                          quarterTurns: entry.quarterTurns,
                          highlighted: source != null && current == source + 1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Page ${index + 1}',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (notes.isNotEmpty)
                          Text(
                            notes.join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    enabled: enabled,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    return Column(
      children: [
        header,
        const Divider(height: 1),
        Expanded(child: list),
        if (hasChanges) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: enabled ? () => setState(_reset) : null,
                    child: const Text('Discard'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: enabled
                        ? () => widget.onApply([
                            for (final item in _items) item.entry,
                          ])
                        : null,
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
