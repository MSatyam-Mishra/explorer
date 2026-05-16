import 'dart:io';
import 'package:flutter/material.dart';
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
    const subtitle = '10 KB Aug 07, 2025'; // Placeholder

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
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.6),
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