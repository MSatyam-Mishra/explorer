import 'package:explorer/core/theme/explorer_theme_extension.dart';
import 'package:explorer/shared/icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

class GradientFolderIcon extends StatelessWidget {
  final double size;
  const GradientFolderIcon({super.key, this.size = 42});

  @override
  Widget build(BuildContext context) {
    final theme = context.explorerTheme;
    final gradient = LinearGradient(
      colors: [
        theme.colorTheme.primary,
        theme.colorTheme.secondary,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(size * 0.2),
      ),
      child: Center(
        child: AppIcons.huge(
          HugeIcons.strokeRoundedFolder01,
          color: theme.colorTheme.neutral,
          size: size * 0.52,
        ),
      ),
    );
  }
}
