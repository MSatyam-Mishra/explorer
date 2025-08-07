import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class FileListItem extends StatelessWidget {
  final FileSystemEntity entity;
  final VoidCallback onTap;

  const FileListItem({
    super.key,
    required this.entity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDirectory = entity is Directory;
    final title = p.basename(entity.path);
    final icon = isDirectory ? Icons.folder_rounded : Icons.insert_drive_file_outlined;
    final iconColor = isDirectory ? Colors.amber.shade600 : Colors.grey.shade400;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: BackdropFilter(
          //5
          filter: ImageFilter.blur(sigmaX: 2.0, sigmaY: 2.0),
          child: InkWell(
            onTap: onTap,
            splashColor: Colors.white.withOpacity(0.1),
            highlightColor: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12.0),
            child: Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08), // The subtle glass color
                borderRadius: BorderRadius.circular(12.0),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Icon(icon, color: iconColor),
                  const SizedBox(width: 16),
                  // Use Expanded to make sure long file names don't overflow
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      overflow: TextOverflow.ellipsis, //
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}