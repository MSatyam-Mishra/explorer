import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'file_type_icon.dart';
import 'gradient_folder_icon.dart';

class FileListItem extends StatelessWidget {
  final FileSystemEntity entity;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FileListItem({
    super.key,
    required this.entity,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final title = p.basename(entity.path);
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
          ],
        ),
      ),
    );
  }
}