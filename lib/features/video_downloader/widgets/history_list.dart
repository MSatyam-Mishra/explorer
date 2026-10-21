import 'dart:io';

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
import 'package:explorer/features/viewer_kit/viewer_kit.dart';
import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'downloader_text.dart';
import 'empty_state.dart';

enum _HistoryAction { open, share, copyLink, deleteFile, remove }

/// Finished downloads: open, share or delete them.
class HistoryList extends StatelessWidget {
  const HistoryList({super.key, required this.controller, this.padding = EdgeInsets.zero});

  final VideoDownloaderController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final history = controller.history;
        if (history.isEmpty) {
          return EmptyState(
            icon: LucideIcons.history,
            title: 'No downloads yet',
            message: 'Finished downloads are listed here.',
            padding: padding,
          );
        }
        return ListView.builder(
          padding: padding,
          itemCount: history.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return SectionLabel(
                '${history.length} ${history.length == 1 ? 'download' : 'downloads'}',
                padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
                trailing: TextButton(
                  onPressed: () => _confirmClear(context),
                  child: const Text('Clear history'),
                ),
              );
            }
            final entry = history[i - 1];
            return _HistoryTile(key: ValueKey(entry.id), entry: entry, controller: controller);
          },
        );
      },
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('The list is cleared. Downloaded files are kept.'),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok ?? false) await controller.clearHistory();
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({super.key, required this.entry, required this.controller});

  final HistoryEntry entry;
  final VideoDownloaderController controller;

  static final _date = DateFormat('d MMM y, HH:mm');

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final exists = File(entry.filePath).existsSync();
    final subtitle = exists
        ? [
            if (entry.sizeBytes != null) DownloaderText.bytes(entry.sizeBytes),
            if (entry.duration != null) DownloaderText.duration(entry.duration),
            _date.format(entry.completedAt),
            DownloaderText.site(entry.extractor, entry.url),
          ].where((s) => s.isNotEmpty).join(' · ')
        : 'File no longer exists';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: exists ? () => _open(context) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Opacity(
                  opacity: exists ? 1 : 0.4,
                  child: FileIcon(path: entry.filePath, size: 40),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title.isEmpty ? p.basename(entry.filePath) : entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: exists ? null : colors.destructive,
                        ),
                      ),
                    ],
                  ),
                ),
                MenuIconButton<_HistoryAction>(
                  onSelected: (action) => _run(context, action, exists),
                  itemBuilder: (context) => [
                    if (exists) ...[
                      menuItem(
                        value: _HistoryAction.open,
                        icon: LucideIcons.externalLink,
                        label: 'Open',
                      ),
                      menuItem(
                        value: _HistoryAction.share,
                        icon: LucideIcons.share2,
                        label: 'Share',
                      ),
                    ],
                    menuItem(
                      value: _HistoryAction.copyLink,
                      icon: LucideIcons.link,
                      label: 'Copy link',
                    ),
                    const PopupMenuDivider(),
                    menuItem(
                      value: _HistoryAction.remove,
                      icon: LucideIcons.listX,
                      label: 'Remove from history',
                    ),
                    if (exists)
                      menuItem(
                        value: _HistoryAction.deleteFile,
                        icon: LucideIcons.trash2,
                        label: 'Delete file',
                        destructive: true,
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

  void _open(BuildContext context) => FileOpener.open(context, File(entry.filePath));

  Future<void> _run(BuildContext context, _HistoryAction action, bool exists) async {
    switch (action) {
      case _HistoryAction.open:
        _open(context);
      case _HistoryAction.share:
        await SharePlus.instance.share(ShareParams(
          files: [XFile(entry.filePath)],
          subject: entry.title,
        ));
      case _HistoryAction.copyLink:
        await Clipboard.setData(ClipboardData(text: entry.url));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Link copied')));
        }
      case _HistoryAction.deleteFile:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete file?'),
            content: Text('${p.basename(entry.filePath)} will be deleted from this device.'),
            actions: [
              OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.destructive,
                  foregroundColor: context.colors.destructiveForeground,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (!(ok ?? false)) return;
        try {
          await controller.removeHistory(entry, deleteFile: true);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text("Couldn't delete the file: $e")));
          }
        }
      case _HistoryAction.remove:
        await controller.removeHistory(entry);
    }
  }
}
