import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/liquid_glass/explorer_liquid_glass.dart';
import 'package:flutter/material.dart';

export 'package:explorer/shared/liquid_glass/explorer_liquid_glass.dart'
    show
        ExplorerLiquidGlassBottomSheet,
        ExplorerLiquidGlassDrawer,
        ExplorerLiquidGlassForeground,
        ExplorerLiquidGlassLayer,
        ExplorerLiquidGlassTopBarScaffold;

typedef DockedTopBarScaffold = ExplorerLiquidGlassTopBarScaffold;

/// Toolbar row inside the liquid-glass top bar lens.
class DockedGlossyTopBar extends StatelessWidget {
  const DockedGlossyTopBar({
    super.key,
    required this.title,
    this.onMenuPressed,
    this.onMorePressed,
    this.leading,
    this.trailing,
    this.height = 54,
  });

  final String title;
  final VoidCallback? onMenuPressed;
  final VoidCallback? onMorePressed;
  final Widget? leading;
  final Widget? trailing;
  final double height;

  static double totalHeight(EdgeInsets margin, double barHeight) =>
      margin.top + barHeight + margin.bottom;

  static double contentTopInset(
    BuildContext context, {
    EdgeInsets barMargin = const EdgeInsets.fromLTRB(16, 12, 16, 12),
    double barHeight = 54,
  }) =>
      ExplorerLiquidGlassTopBarScaffold.contentTopInset(
        context,
        barMargin: barMargin,
        barHeight: barHeight,
      );

  @override
  Widget build(BuildContext context) {
    final iconColor = ExplorerLiquidGlassForeground.icon(context);
    final titleStyle = ExplorerLiquidGlassForeground.title(context);

    return IconTheme(
      data: IconThemeData(color: iconColor, size: 20),
      child: DefaultTextStyle(
        style: titleStyle,
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              leading ??
                  _BarIconButton(
                    icon: AppIcons.drawerMenu(color: iconColor),
                    tooltip: 'Open menu',
                    onPressed: onMenuPressed ??
                        () => Scaffold.of(context).openDrawer(),
                  ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: titleStyle,
                  ),
                ),
              ),
              trailing ??
                  (onMorePressed != null
                      ? _BarIconButton(
                          icon: AppIcons.optionsMenu(color: iconColor),
                          tooltip: 'Options',
                          onPressed: onMorePressed,
                        )
                      : const SizedBox(width: 8)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
      icon: icon,
    );
  }
}
