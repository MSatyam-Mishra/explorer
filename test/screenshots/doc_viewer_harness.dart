import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// The four looks every document viewer is reviewed in.
const shotVariants = <(ThemeMode, String, Size)>[
  (ThemeMode.light, 'phone', Size(390, 844)),
  (ThemeMode.dark, 'phone', Size(390, 844)),
  (ThemeMode.light, 'tablet', Size(1280, 800)),
  (ThemeMode.dark, 'tablet', Size(1280, 800)),
];

/// Lets real I/O (file reads, isolates, image decoding) finish and
/// animations run.
Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Settles until [finder] matches (or [maxRounds] pass), for work whose
/// duration varies (isolates, servers).
Future<void> settleUntil(
  WidgetTester tester,
  Finder finder, {
  int maxRounds = 80,
}) async {
  for (var i = 0; i < maxRounds && finder.evaluate().isEmpty; i++) {
    await settle(tester, rounds: 1);
  }
  await settle(tester, rounds: 3);
}

/// Pumps the themed app with an empty home page and pushes [screen] on top,
/// so the viewer shows its back button like it does in the app.
Future<void> pumpViewer(
  WidgetTester tester,
  Widget screen, {
  required ThemeMode mode,
  required Size size,
  String colorScheme = 'blue',
  Future<void> Function()? beforePush,
}) async {
  SharedPreferences.setMockInitialValues({});
  setScreenSize(tester, size);
  await tester.pumpWidget(
    screenshotFrame(
      themedApp(
        const Scaffold(body: SizedBox.expand()),
        themeMode: mode,
        colorScheme: colorScheme,
      ),
    ),
  );
  await tester.pump();
  if (beforePush != null) await tester.runAsync(beforePush);
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
  await settle(tester);
}

/// Disposes the app and lets leftover timers (debounces, timeouts) run out.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 15));
}

/// Closes the top route (dialog, sheet or menu).
Future<void> dismissTop(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.pop();
  await settle(tester, rounds: 3);
}

// ---------------------------------------------------------------------------
// A page of fake document content: drawn into the sample PDF and into the
// bitmaps the fake renderer returns, so pages look like a real document.

class SampleLine {
  const SampleLine(
    this.text, {
    required this.y,
    this.x = 64,
    this.size = 11,
    this.bold = false,
    this.color = const Color(0xFF1F2328),
  });

  final String text;
  final double x;
  final double y;
  final double size;
  final bool bold;
  final Color color;
}

const _body = [
  'Revenue grew across every region this quarter, led by strong',
  'subscription renewals and the launch of two new product lines.',
  'Operating costs stayed flat while headcount rose by four percent.',
  'The board approved the revised plan for the second half.',
];

/// Pages of the sample report (A4, points).
final List<List<SampleLine>> samplePages = [
  for (var page = 0; page < 6; page++)
    [
      SampleLine(
        page == 0 ? 'Quarterly report' : 'Section ${page + 1}',
        y: 72,
        size: page == 0 ? 26 : 20,
        bold: true,
      ),
      SampleLine(
        page == 0 ? 'Prepared for the board · October 2026' : 'Details',
        y: page == 0 ? 112 : 104,
        size: 12,
        color: const Color(0xFF59636E),
      ),
      for (var p = 0; p < 4; p++)
        for (var l = 0; l < _body.length; l++)
          SampleLine(_body[(l + p + page) % _body.length], y: 160.0 + p * 92 + l * 18),
      SampleLine('Highlights', y: 560, size: 15, bold: true),
      for (var l = 0; l < 3; l++)
        SampleLine('•  ${_body[(l + page) % _body.length]}', y: 590.0 + l * 20),
      SampleLine('${page + 1}', x: 290, y: 800, size: 10, color: const Color(0xFF8C959F)),
    ],
];

const samplePageSize = Size(595, 842);

/// Registers the app's Geist font under the family names documents ask for
/// (Calibri, Arial, …): the test engine has no system fonts, and unknown
/// families would draw as boxes.
Future<void> loadDocumentFontAliases() async {
  final geist = rootBundle.load('packages/shadcn_ui/fonts/Geist[wght].ttf');
  final mono = rootBundle.load('packages/shadcn_ui/fonts/GeistMono[wght].ttf');
  for (final family in const [
    'Calibri', 'Cambria', 'Arial', 'Helvetica', 'Times New Roman', 'Georgia',
    'Verdana', 'Segoe UI', 'Aptos', 'Roboto', 'Liberation Sans',
    'Liberation Serif', 'DejaVu Sans', 'Noto Sans', 'Open Sans', 'serif',
    'sans-serif', 'Calibri Light',
  ]) {
    await (FontLoader(family)..addFont(geist)).load();
  }
  for (final family in const ['Courier New', 'Consolas', 'monospace']) {
    await (FontLoader(family)..addFont(mono)).load();
  }
}

/// A fresh temp folder for sample files.
Future<Directory> sampleDir(String tag) =>
    Directory.systemTemp.createTemp('explorer_${tag}_');
