import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:flutter/material.dart';

/// Folder icon in the explorer: the glass folder from assets/iocns/glass.
class GradientFolderIcon extends StatelessWidget {
  final double size;
  const GradientFolderIcon({super.key, this.size = 42});

  @override
  Widget build(BuildContext context) => FolderIcon(size: size);
}
