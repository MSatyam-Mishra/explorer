import 'dart:ui';

import 'package:explorer/core/theme/explorer_theme_extension.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Gradient app bar: solid at top, fades toward bottom with backdrop blur.
class GlossyAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlossyAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.centerTitle = false,
    this.automaticallyImplyLeading = true,
    this.bottom,
  });

  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final bool centerTitle;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(
        kToolbarHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    final explorer = context.explorerTheme;
    final appearance = explorer.appearance;
    final blur = explorer.glassBlurSigma;
    final canPop = Navigator.of(context).canPop();
    final resolvedLeading = leading ??
        (automaticallyImplyLeading && canPop
            ? BackButton(color: explorer.colorTheme.neutral)
            : null);

    final alignedTitle = title == null
        ? null
        : Align(
            alignment: Alignment.centerLeft,
            child: DefaultTextStyle.merge(
              style: Theme.of(context).appBarTheme.titleTextStyle,
              child: title!,
            ),
          );

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: centerTitle,
      titleSpacing: centerTitle ? null : 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      leading: resolvedLeading,
      title: alignedTitle,
      actions: actions,
      bottom: bottom,
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: explorer.appBarGradient,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: appearance.glassFill.withValues(alpha: 0.18),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: appearance.border.withValues(alpha: 0.22),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
