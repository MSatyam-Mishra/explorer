import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// Shared setup for the viewer screenshot tests (SCREENSHOTS=1).
///
/// Each test runs in light and dark mode on a phone (390×844) and a tablet
/// (1280×800); [body] gets a tag like `dark_tablet` for file names.
void viewerShots(
  String name,
  Future<void> Function(WidgetTester tester, ShotContext shot) body, {
  List<String> devices = const ['phone', 'tablet'],
}) {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final device in devices) {
      final size = device == 'phone'
          ? const Size(390, 844)
          : const Size(1280, 800);
      final tag = '${mode.name}_$device';
      testWidgets('$name $tag', (tester) async {
        SharedPreferences.setMockInitialValues({});
        setScreenSize(tester, size);
        await body(
          tester,
          ShotContext(tester, mode, tag, device == 'tablet'),
        );
        // Unmount, then let timers the screens started (debounces,
        // timeouts) run out.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(minutes: 5));
      }, skip: !screenshotsEnabled);
    }
  }
}

class ShotContext {
  ShotContext(this.tester, this.mode, this.tag, this.tablet);

  final WidgetTester tester;
  final ThemeMode mode;
  final String tag;
  final bool tablet;

  /// Shows [screen] as a pushed route (so it has a back button), themed.
  Future<void> open(Widget screen, {String colorScheme = 'blue'}) async {
    await tester.pumpWidget(
      screenshotFrame(
        themedApp(
          _Launcher(screen, key: UniqueKey()),
          themeMode: mode,
          colorScheme: colorScheme,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> shot(String name) => saveScreenshot(tester, '${name}_$tag');
}

class _Launcher extends StatefulWidget {
  const _Launcher(this.screen, {super.key});

  final Widget screen;

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => widget.screen,
          transitionDuration: Duration.zero,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

/// WebViews can't render in tests: this platform draws an empty, labelled
/// box instead, so the chrome around a WebView can be judged.
class FakeWebViewPlatform extends InAppWebViewPlatform {
  static void install() => InAppWebViewPlatform.instance = FakeWebViewPlatform();

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) =>
      _FakeWebView(params);
}

class _FakeWebView extends PlatformInAppWebViewWidget {
  _FakeWebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

/// Lets real I/O and isolates finish and animations run.
Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
