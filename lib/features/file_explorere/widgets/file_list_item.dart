import 'dart:io';
import 'package:explorer/core/files/file_types.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'file_type_icon.dart';
import 'gradient_folder_icon.dart';

class FileListItem extends StatelessWidget {
  final FileSystemEntity entity;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? displayName;

  const FileListItem({
    super.key,
    required this.entity,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    this.displayName,
  });
  @override
  Widget build(BuildContext context) {
    final rawTitle = displayName ?? p.basename(entity.path);
    final title = rawTitle.isEmpty ? entity.path : rawTitle;
    final isDirectory = entity is Directory;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Row(
          children: [
            // Conditionally show the correct icon
          isDirectory ? const GradientFolderIcon() : FileTypeIcon(filePath: entity.path),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  _EntitySubtitle(
                    entity: entity,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),

            // Checkbox is now at the end, and only visible in selection mode
            if (isSelectionMode)
              Checkbox(
                value: isSelected,
                onChanged: (val) => onTap(),
              ),
          ],
        ),
      ),
    );
  }
}

/// "1.2 MB · PDF document · Mar 4, 2026" for files, date only for folders.
class _EntitySubtitle extends StatefulWidget {
  const _EntitySubtitle({required this.entity, this.style});

  final FileSystemEntity entity;
  final TextStyle? style;

  @override
  State<_EntitySubtitle> createState() => _EntitySubtitleState();
}

class _EntitySubtitleState extends State<_EntitySubtitle> {
  static final _date = DateFormat.yMMMd();
  late Future<FileStat> _stat = widget.entity.stat();

  @override
  void didUpdateWidget(_EntitySubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entity.path != widget.entity.path) {
      _stat = widget.entity.stat();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FileStat>(
      future: _stat,
      builder: (context, snapshot) {
        final stat = snapshot.data;
        String text = ' ';
        if (stat != null && stat.type != FileSystemEntityType.notFound) {
          final date = _date.format(stat.modified);
          text = widget.entity is Directory
              ? date
              : '${filesize(stat.size)} · '
                  '${FileTypes.describe(FileTypes.kindOf(widget.entity.path))} · $date';
        }
        return Text(
          text,
          style: widget.style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
