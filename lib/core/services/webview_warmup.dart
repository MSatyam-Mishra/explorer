import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Pre-initializes the platform WebView once per process.
///
/// The first WebView created in a process pays for loading the engine
/// (Chromium's WebView provider on Android, WebKit's processes on Apple
/// platforms, the WebView2 environment on Windows): often the single most
/// expensive step of opening a WebView-based viewer such as the e-book
/// reader. Doing it once while the app is idle makes the first real viewer
/// start much faster.
///
/// Call [warmUp] a few seconds after the first frame. It is idempotent,
/// never throws, and does nothing where no WebView is available.
class WebViewWarmup {
  WebViewWarmup._();

  static Future<void>? _done;

  static Future<void> warmUp() => _done ??= _run();

  static bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  static Future<void> _run() async {
    if (!_supported) return;
    HeadlessInAppWebView? webView;
    try {
      final loaded = Completer<void>();
      void done() {
        if (!loaded.isCompleted) loaded.complete();
      }

      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('about:blank')),
        initialSettings: InAppWebViewSettings(
          cacheEnabled: false,
          transparentBackground: true,
        ),
        onLoadStop: (_, __) => done(),
        onReceivedError: (_, __, ___) => done(),
      );
      // Creating the view loads the engine; loading a page also starts the
      // renderer once, which primes the rest of the pipeline.
      await webView.run();
      await loaded.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } catch (e) {
      debugPrint('WebViewWarmup: $e');
    } finally {
      try {
        await webView?.dispose();
      } catch (_) {}
    }
  }
}
