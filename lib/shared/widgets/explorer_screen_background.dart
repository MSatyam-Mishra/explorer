import 'package:explorer/core/theme/explorer_theme_extension.dart';
import 'package:flutter/material.dart';

/// Full-screen background from the active color theme (solid or gradient).
class ExplorerScreenBackground extends StatelessWidget {
  const ExplorerScreenBackground({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spec = context.explorerTheme.colorTheme;
    final appearance = context.explorerTheme.appearance;
    final gradient =
        appearance.screenGradient ?? spec.screenBackgroundGradient;

    if (gradient == null || gradient.length < 2) {
      return ColoredBox(
        color: appearance.background,
        child: child,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: gradient,
        ),
      ),
      child: child,
    );
  }
}
