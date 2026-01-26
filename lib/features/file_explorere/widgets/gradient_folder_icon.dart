import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

class GradientFolderIcon extends StatelessWidget {
  final double size;
  const GradientFolderIcon({super.key, this.size = 42});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient, // Use the gradient from our theme
        borderRadius: BorderRadius.circular(size * 0.2), // Proportional radius
      ),
      child: Icon(
        BootstrapIcons.folder_fill,
        color: Colors.white,
        size: size * 0.57, // Proportional icon size (~24/42)
      ),
    );
  }
}
