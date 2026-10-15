import 'package:explorer/core/services/bookmark_service.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// One entry of the document outline (the PDF's own bookmarks).
class PdfOutlineNode {
  PdfOutlineNode(this.title, this.bookmark, this.children);

  final String title;
  final PdfBookmark bookmark;
  final List<PdfOutlineNode> children;

  /// Reads the outline of [document]. Malformed entries are skipped.
  static List<PdfOutlineNode> read(PdfDocument document) {
    var budget = 5000;
    List<PdfOutlineNode> walk(PdfBookmarkBase parent, int depth) {
      final nodes = <PdfOutlineNode>[];
      int count;
      try {
        count = parent.count;
      } catch (_) {
        return nodes;
      }
      for (var i = 0; i < count && budget > 0; i++) {
        try {
          final bookmark = parent[i];
          budget--;
          final title = bookmark.title.trim();
          nodes.add(
            PdfOutlineNode(
              title.isEmpty ? 'Untitled' : title,
              bookmark,
              depth < 24 ? walk(bookmark, depth + 1) : const [],
            ),
          );
        } catch (_) {
          // Skip entries that can't be parsed.
        }
      }
      return nodes;
    }

    try {
      return walk(document.bookmarks, 0);
    } catch (_) {
      return const [];
    }
  }
}

/// Outline, user bookmarks and page manager in tabs. Used as a docked pane
/// on wide screens and inside the drawer on phones.
class PdfSidePanel extends StatefulWidget {
  const PdfSidePanel({
    super.key,
    required this.tabIndex,
    required this.onTabChanged,
    required this.outline,
    required this.onOutlineSelected,
    required this.bookmarks,
    required this.currentPage,
    required this.onBookmarkSelected,
    required this.onBookmarkRemoved,
    required this.onAddBookmark,
    required this.pages,
    this.onClose,
  });

  final int tabIndex;
  final ValueChanged<int> onTabChanged;

  /// Null while the document is loading.
  final List<PdfOutlineNode>? outline;
  final ValueChanged<PdfOutlineNode> onOutlineSelected;
  final List<Bookmark> bookmarks;
  final int currentPage;

  /// Called with the 0-based page index of the bookmark.
  final ValueChanged<int> onBookmarkSelected;
  final ValueChanged<Bookmark> onBookmarkRemoved;
  final VoidCallback? onAddBookmark;

  /// Content of the Pages tab.
  final Widget pages;
  final VoidCallback? onClose;

  @override
  State<PdfSidePanel> createState() => _PdfSidePanelState();
}

class _PdfSidePanelState extends State<PdfSidePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.tabIndex.clamp(0, 2),
  )..addListener(_onTab);
  final Set<String> _expanded = {};

  /// Tabs that have been shown; others aren't built until first visited so
  /// the page manager only loads its data when it is actually opened.
  late final Set<int> _visited = {_tabs.index};

  void _onTab() {
    _visited.add(_tabs.index);
    setState(() {});
    if (_tabs.index != widget.tabIndex) widget.onTabChanged(_tabs.index);
  }

  @override
  void didUpdateWidget(PdfSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only follow the owner when it asks for a different tab, so a rebuild
    // during a tab switch doesn't snap back to the old tab.
    final index = widget.tabIndex.clamp(0, 2);
    if (widget.tabIndex != oldWidget.tabIndex && index != _tabs.index) {
      _visited.add(index);
      _tabs.index = index;
    }
    if (!identical(oldWidget.outline, widget.outline)) _expanded.clear();
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foreground = ClearGlassForeground.icon(context);
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        listTileTheme: theme.listTileTheme.copyWith(
          textColor: foreground,
          iconColor: foreground,
        ),
        iconTheme: theme.iconTheme.copyWith(color: foreground),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tabs,
                    labelColor: foreground,
                    unselectedLabelColor: foreground.withValues(alpha: 0.6),
                    indicatorColor: theme.colorScheme.primary,
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(text: 'Outline'),
                      Tab(text: 'Bookmarks'),
                      Tab(text: 'Pages'),
                    ],
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: 'Hide panel',
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
              ],
            ),
            const Divider(height: 1),
            // An IndexedStack instead of a TabBarView: the latter skips child
            // updates while animating across tabs, leaving stale content.
            Expanded(
              child: IndexedStack(
                index: _tabs.index,
                children: [
                  _visited.contains(0)
                      ? _buildOutline(context, foreground)
                      : const SizedBox.shrink(),
                  _visited.contains(1)
                      ? _buildBookmarks(context, foreground)
                      : const SizedBox.shrink(),
                  _visited.contains(2) ? widget.pages : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutline(BuildContext context, Color foreground) {
    final outline = widget.outline;
    if (outline == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (outline.isEmpty) {
      return _EmptyMessage(
        icon: Icons.toc,
        text: 'This PDF has no outline',
        color: foreground,
      );
    }
    final rows = <(PdfOutlineNode, int, String)>[];
    void add(List<PdfOutlineNode> nodes, int depth, String prefix) {
      for (var i = 0; i < nodes.length; i++) {
        final key = '$prefix/$i';
        rows.add((nodes[i], depth, key));
        if (_expanded.contains(key)) add(nodes[i].children, depth + 1, key);
      }
    }

    add(outline, 0, '');
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final (node, depth, key) = rows[index];
        final expandable = node.children.isNotEmpty;
        final expanded = _expanded.contains(key);
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 12.0 + depth * 16, right: 4),
          title: Text(node.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => widget.onOutlineSelected(node),
          trailing: expandable
              ? IconButton(
                  tooltip: expanded ? 'Collapse' : 'Expand',
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() {
                    if (!_expanded.remove(key)) _expanded.add(key);
                  }),
                )
              : null,
        );
      },
    );
  }

  Widget _buildBookmarks(BuildContext context, Color foreground) {
    final bookmarks = [...widget.bookmarks]
      ..sort((a, b) => _page(a).compareTo(_page(b)));
    final alreadyMarked = bookmarks.any(
      (b) => _page(b) == widget.currentPage - 1,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: alreadyMarked ? null : widget.onAddBookmark,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: Text(
                alreadyMarked
                    ? 'Page ${widget.currentPage} is bookmarked'
                    : 'Bookmark page ${widget.currentPage}',
              ),
            ),
          ),
        ),
        Expanded(
          child: bookmarks.isEmpty
              ? _EmptyMessage(
                  icon: Icons.bookmark_border,
                  text: 'No bookmarks yet',
                  color: foreground,
                )
              : ListView.builder(
                  itemCount: bookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = bookmarks[index];
                    final created = bookmark.createdAt;
                    return ListTile(
                      leading: const Icon(Icons.bookmark_outline),
                      title: Text(bookmark.label),
                      subtitle: Text(
                        '${created.year}-${_two(created.month)}-'
                        '${_two(created.day)}',
                        style: TextStyle(
                          color: foreground.withValues(alpha: 0.7),
                        ),
                      ),
                      onTap: () => widget.onBookmarkSelected(_page(bookmark)),
                      trailing: IconButton(
                        tooltip: 'Remove bookmark',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => widget.onBookmarkRemoved(bookmark),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static int _page(Bookmark bookmark) {
    final position = bookmark.position;
    if (position is int) return position;
    if (position is num) return position.toInt();
    return int.tryParse('$position') ?? 0;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}
