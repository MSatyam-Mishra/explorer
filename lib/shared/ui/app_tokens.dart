import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

extension AppTokens on BuildContext {
  /// shadcn colour tokens for the current theme (light/dark, scheme).
  ShadColorScheme get colors => ShadTheme.of(this).colorScheme;

  /// shadcn typography (h1…h4, p, large, small, muted, …).
  ShadTextTheme get typography => ShadTheme.of(this).textTheme;

  bool get isDarkMode => ShadTheme.of(this).brightness == Brightness.dark;
}

/// Text and icon colours for content drawn on the page background.
abstract final class AppForeground {
  static Color icon(BuildContext context) => context.colors.foreground;

  static Color primaryText(BuildContext context) => context.colors.foreground;

  static Color secondaryText(BuildContext context) =>
      context.colors.mutedForeground;

  static TextStyle title(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium ??
      TextStyle(
        color: context.colors.foreground,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      );
}
