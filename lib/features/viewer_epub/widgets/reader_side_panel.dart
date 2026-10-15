import 'dart:typed_data';

import 'package:explorer/core/services/bookmark_service.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../book/book_models.dart';

/// Contents (nested TOC) and bookmarks, used as a drawer on phones and as a
/// docked pane on tablets/foldables.
class ReaderSidePanel extends StatefulWidget {
  const ReaderSidePanel({
    super.key,
    required this.info,
    required this.cover,
    required this.current,
    required this.bookmarks,
    required this.bookmarkLabel,
    required this.onTocTap,
    required this.onBookmarkTap,
    required this.onBookmarkDelete,
    this.onClose,
  });

  final BookInfo info;
  final Uint8List? cover;

  /// The TOC entry being read (highlighted and scrolled into view).
  final FlatTocEntry? current;
  final List<Bookmark> bookmarks;
  final String Function(Bookmark) bookmarkLabel;
  final ValueChanged<TocEntry> onTocTap;
  final ValueChanged<Bookmark> onBookmarkTap;
  final ValueChanged<Bookmark> onBookmarkDelete;

  /// Shown as a close button in the header (docked mode).
  final VoidCallback? onClose;

  @override
  State<ReaderSidePanel> createState() => _ReaderSidePanelState();
}

class _ReaderSidePanelState extends State<ReaderSidePanel> {
  static const _rowHeight = 48.0;
  final Set<int> _collapsed = {};
  late ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final flat = widget.info.flatToc;
    // Big books: start with deep levels collapsed.
    if (flat.length > 150) {
      for (final f in flat) {
        if (f.depth >= 1 && f.entry.children.isNotEmpty) _collapsed.add(f.order);
        if (f.depth == 0 && f.entry.children.length > 40) _collapsed.add(f.order);
      }
      _expandToCurrent();
    }
    final index = _visible().indexWhere((f) => f.order == widget.current?.order);
    _scroll = ScrollController(
      initialScrollOffset: index <= 3 ? 0 : (index - 3) * _rowHeight,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _expandToCurrent() {
    final current = widget.current;
    if (current == null) return;
    // Expand every ancestor of the current entry.
    final flat = widget.info.flatToc;
    var depth = current.depth;
    for (var i = current.order - 1; i >= 0 && depth > 0; i--) {
      if (flat[i].depth < depth) {
        _collapsed.remove(flat[i].order);
        depth = flat[i].depth;
      }
    }
  }

  static bool _hasTarget(TocEntry e) =>
      e.spineIndex != null || e.children.any(_hasTarget);

  List<FlatTocEntry> _visible() {
    final out = <FlatTocEntry>[];
    int? hideDeeperThan;
    for (final f in widget.info.flatToc) {
      if (hideDeeperThan != null) {
        if (f.depth > hideDeeperThan) continue;
        hideDeeperThan = null;
      }
      out.add(f);
      if (_collapsed.contains(f.order)) hideDeeperThan = f.depth;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          _Header(
            info: widget.info,
            cover: widget.cover,
            onClose: widget.onClose,
          ),
          TabBar(
            tabs: [
              const Tab(text: 'Contents'),
              Tab(text: 'Bookmarks (${widget.bookmarks.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildToc(theme),
                _buildBookmarks(theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToc(ThemeData theme) {
    final visible = _visible();
    if (visible.isEmpty) {
      return const Center(child: Text('This book has no table of contents.'));
    }
    final currentOrder = widget.current?.order;
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final f = visible[i];
          final selected = f.order == currentOrder;
          final hasChildren = f.entry.children.isNotEmpty;
          final enabled = _hasTarget(f.entry);
          return Material(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            child: InkWell(
              onTap: enabled ? () => widget.onTocTap(f.entry) : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _rowHeight),
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: 12.0 + f.depth * 16.0,
                    end: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          f.entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: selected || f.depth == 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: selected
                                ? theme.colorScheme.primary
                                : enabled
                                    ? null
                                    : theme.disabledColor,
                          ),
                        ),
                      ),
                      if (hasChildren)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: _collapsed.contains(f.order)
                              ? 'Expand'
                              : 'Collapse',
                          icon: Icon(
                            _collapsed.contains(f.order)
                                ? Icons.expand_more
                                : Icons.expand_less,
                          ),
                          onPressed: () => setState(() {
                            if (!_collapsed.remove(f.order)) {
                              _collapsed.add(f.order);
                            }
                          }),
                        )
                      else
                        const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBookmarks(ThemeData theme) {
    if (widget.bookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No bookmarks yet.\nUse the bookmark button in the top bar to '
            'save your place.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    final dateFormat = DateFormat.yMMMd();
    final sorted = [...widget.bookmarks]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return ListView.builder(
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final b = sorted[i];
        return ListTile(
          leading: const Icon(Icons.bookmark),
          title: Text(
            widget.bookmarkLabel(b),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(dateFormat.format(b.createdAt)),
          trailing: IconButton(
            tooltip: 'Remove bookmark',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => widget.onBookmarkDelete(b),
          ),
          onTap: () => widget.onBookmarkTap(b),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.info, required this.cover, this.onClose});

  final BookInfo info;
  final Uint8List? cover;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = info.metadata;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 56,
              height: 80,
              child: cover != null
                  ? Image.memory(
                      cover!,
                      fit: BoxFit.cover,
                      cacheWidth: 168,
                      errorBuilder: (_, __, ___) => _placeholder(theme),
                    )
                  : _placeholder(theme),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (meta.authorLine.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta.authorLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${info.format.name.toUpperCase()} · '
                  '${info.spine.length} section${info.spine.length == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              tooltip: 'Hide contents',
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }

  Widget _placeholder(ThemeData theme) => ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.menu_book,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
}
