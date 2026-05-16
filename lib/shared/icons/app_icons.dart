import 'package:explorer/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

/// Central HugeIcons access with consistent smaller sizing.
abstract final class AppIcons {
  static const double sm = AppTheme.iconSize;
  static const double md = 22;

  static Widget huge(
    List<List<dynamic>> icon, {
    double? size,
    Color? color,
  }) {
    return HugeIcon(
      icon: icon,
      size: size ?? sm,
      color: color,
    );
  }

  static Widget back({Color? color}) =>
      huge(HugeIcons.strokeRoundedArrowLeft01, color: color);

  static Widget cancel({Color? color}) =>
      huge(HugeIcons.strokeRoundedCancel01, color: color);

  static Widget archive({Color? color}) =>
      huge(HugeIcons.strokeRoundedArchive01, color: color);

  static Widget delete({Color? color}) =>
      huge(HugeIcons.strokeRoundedDelete02, color: color);

  static Widget globe({Color? color}) =>
      huge(HugeIcons.strokeRoundedGlobe02, color: color);

  static Widget grid({Color? color}) =>
      huge(HugeIcons.strokeRoundedGrid02, color: color);

  static Widget sort({Color? color}) =>
      huge(HugeIcons.strokeRoundedSortByDown02, color: color);

  /// Three-line menu (drawer).
  static Widget drawerMenu({Color? color}) =>
      huge(HugeIcons.strokeRoundedMenu01, color: color);

  /// Three-dot options menu.
  static Widget optionsMenu({Color? color}) =>
      huge(HugeIcons.strokeRoundedMore03, color: color);

  @Deprecated('Use drawerMenu or optionsMenu')
  static Widget menu({Color? color}) => optionsMenu(color: color);

  static Widget clipboard({Color? color}) =>
      huge(HugeIcons.strokeRoundedClipboard, color: color);

  static Widget sun({Color? color}) =>
      huge(HugeIcons.strokeRoundedSun01, color: color);

  static Widget moon({Color? color}) =>
      huge(HugeIcons.strokeRoundedMoon01, color: color);

  static Widget listView({Color? color}) =>
      huge(HugeIcons.strokeRoundedLeftToRightListBullet, color: color);

  static Widget check({Color? color, double? size}) =>
      huge(HugeIcons.strokeRoundedTick02, color: color, size: size ?? 18);

  static Widget bookmark({Color? color}) =>
      huge(HugeIcons.strokeRoundedBookmark01, color: color);
}
