import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:flutter/material.dart';


class GradientFolderIcon extends StatelessWidget {
  const GradientFolderIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient, // Use the gradient from our theme
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        BootstrapIcons.folder_fill,
        color: Colors.white,
        size: 24,
      ),
    );
  }
}