import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

/// The translucent window on computers: Windows' Acrylic, macOS's
/// vibrancy, and on Linux a see-through window that the compositor blurs
/// where it can (KDE). The app's backgrounds then let it show through
/// ([backgroundAlpha]); dialogs, sheets and menus stay solid.
abstract final class WindowEffects {
  /// Computers only; widget tests have no window.
  static final bool supported = (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  /// Whether the effect is on (set by [apply]); the theme reads it.
  static bool get active => _active;
  static bool _active = false;

  /// Turns it on at start-up when [enabled], before the first frame (the
  /// Linux window is shown by the plugin once it can be see-through).
  static Future<void> init({required bool enabled}) async {
    if (!supported) return;
    await Window.initialize();
    _active = enabled;
  }

  static bool? _lastEnabled;
  static bool? _lastDark;

  /// Applies the effect for the current theme ([dark]).
  static Future<void> apply({required bool enabled, required bool dark}) async {
    if (!supported) return;
    if (_lastEnabled == enabled && _lastDark == dark) return;
    _lastEnabled = enabled;
    _lastDark = dark;
    _active = enabled;
    if (!enabled) {
      await Window.setEffect(effect: WindowEffect.disabled);
      return;
    }
    if (Platform.isWindows) {
      await Window.setEffect(
        effect: WindowEffect.acrylic,
        // A light wash; the app's own background tints it further.
        color: dark ? const Color(0x22101010) : const Color(0x22F8F8F8),
        dark: dark,
      );
    } else if (Platform.isMacOS) {
      await Window.setEffect(effect: WindowEffect.underWindowBackground, dark: dark);
    } else {
      await Window.setEffect(effect: WindowEffect.transparent);
    }
  }

  /// How opaque the app's main background is while the effect is on: about
  /// half where the system blurs, mostly solid on Linux where it may not.
  static double backgroundAlpha(Brightness brightness) {
    if (Platform.isLinux) return brightness == Brightness.dark ? 0.86 : 0.88;
    return brightness == Brightness.dark ? 0.5 : 0.58;
  }
}
