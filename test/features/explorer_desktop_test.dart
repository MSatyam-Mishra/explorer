import 'dart:io';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Mouse and keyboard in the file list, as on a desktop (the tests run on
/// a desktop OS, so the desktop menus apply).
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_desktop_test');
    await Directory(p.join(root.path, 'Docs')).create();
    for (final name in ['alpha.txt', 'beta.txt', 'gamma.txt', '.hidden']) {
      await File(p.join(root.path, name)).writeAsString(name);
    }
    ExplorerPaths.startFolder = root.path;
  });

  tearDown(() async {
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final context = tester.element(find.byType(Scaffold).first);
    final bloc = BlocProvider.of<FileExplorerBloc>(context);
    for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester);
    }
    await settle(tester);
    return bloc;
  }

  FileListItem row(WidgetTester tester, String name) => tester.widget<FileListItem>(
        find.ancestor(of: find.text(name), matching: find.byType(FileListItem)),
      );

  Future<void> click(WidgetTester tester, String name, {int buttons = kPrimaryButton}) async {
    await tester.tap(find.text(name), kind: PointerDeviceKind.mouse, buttons: buttons);
    await tester.pump();
  }

  testWidgets('click highlights, double-click opens, hidden files are hidden', (tester) async {
    final bloc = await open(tester);
    expect(find.text('.hidden'), findsNothing, reason: 'hidden on desktop');

    await click(tester, 'alpha.txt');
    expect(row(tester, 'alpha.txt').isSelected, isTrue);
    expect((bloc.state as FileExplorerLoaded).isSelectionMode, isFalse,
        reason: 'one click only highlights');

    // Another item: the highlight moves.
    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'beta.txt');
    expect(row(tester, 'alpha.txt').isSelected, isFalse);
    expect(row(tester, 'beta.txt').isSelected, isTrue);

    // Double-click a folder opens it.
    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'Docs');
    await click(tester, 'Docs');
    await settle(tester);
    expect((bloc.state as FileExplorerLoaded).path, p.join(root.path, 'Docs'));
  });

  testWidgets('Ctrl-click and Shift-click select several; keys act on them', (tester) async {
    final bloc = await open(tester);
    FileExplorerLoaded state() => bloc.state as FileExplorerLoaded;

    await click(tester, 'alpha.txt');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await click(tester, 'gamma.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(state().selectedItems.map((e) => p.basename(e.path)), unorderedEquals(['alpha.txt', 'gamma.txt']));
    expect(state().isSelectionMode, isTrue, reason: 'several: the selection bar');

    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'alpha.txt');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(tester, 'gamma.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(state().selectedItems.map((e) => p.basename(e.path)),
        unorderedEquals(['alpha.txt', 'beta.txt', 'gamma.txt']));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state().selectedItems, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(state().selectedItems, hasLength(4));
  });

  testWidgets('right-click shows a context menu', (tester) async {
    await open(tester);
    await click(tester, 'beta.txt', buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    for (final label in ['Open', 'Open with…', 'Copy', 'Rename', 'Properties', 'Delete']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(row(tester, 'beta.txt').isSelected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // On empty space: the folder's menu.
    await tester.tapAt(const Offset(900, 760), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Open in new window'), findsOneWidget);
  });
}
