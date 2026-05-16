import 'package:explorer/shared/liquid_glass/explorer_liquid_glass.dart';
import 'package:flutter/material.dart';

/// Side drawer with a full-height liquid-glass lens.
class GlossyDrawer extends StatelessWidget {
  const GlossyDrawer({
    super.key,
    required this.child,
    this.width,
  });

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return ExplorerLiquidGlassDrawer(
      width: width,
      child: child,
    );
  }
}
