import 'dart:io';

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
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
            icon: Icons.history,
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
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 0, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${history.length} ${history.length == 1 ? 'download' : 'downloads'}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _confirmClear(context),
                      child: const Text('Clear history'),
                    ),
                  ],
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
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
    final theme = Theme.of(context);
    final exists = File(entry.filePath).existsSync();
    final subtitle = exists
        ? [
            if (entry.sizeBytes != null) DownloaderText.bytes(entry.sizeBytes),
            if (entry.duration != null) DownloaderText.duration(entry.duration),
            _date.format(entry.completedAt),
            DownloaderText.site(entry.extractor, entry.url),
          ].where((s) => s.isNotEmpty).join(' · ')
        : 'File no longer exists';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        leading: Opacity(
          opacity: exists ? 1 : 0.4,
          child: FileIcon(path: entry.filePath, size: 40),
        ),
        title: Text(
          entry.title.isEmpty ? p.basename(entry.filePath) : entry.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: exists ? null : TextStyle(color: theme.colorScheme.error),
        ),
        onTap: exists ? () => _open(context) : null,
        trailing: PopupMenuButton<_HistoryAction>(
          tooltip: 'More',
          onSelected: (action) => _run(context, action, exists),
          itemBuilder: (context) => [
            if (exists) ...const [
              PopupMenuItem(value: _HistoryAction.open, child: Text('Open')),
              PopupMenuItem(value: _HistoryAction.share, child: Text('Share')),
            ],
            const PopupMenuItem(value: _HistoryAction.copyLink, child: Text('Copy link')),
            if (exists)
              const PopupMenuItem(value: _HistoryAction.deleteFile, child: Text('Delete file')),
            const PopupMenuItem(value: _HistoryAction.remove, child: Text('Remove from history')),
          ],
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
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
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
