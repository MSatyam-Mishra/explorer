import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/core/services/file_server/http_file_server.dart';
import 'package:explorer/features/network/widgets/server_status_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';
import 'viewer_shot_helpers.dart' show settle;

class _NoResources implements FileServerResources {
  @override
  String get folderIcon => 'folder';
  @override
  String iconFor(String name, {required bool dark}) => 'file';
  @override
  Future<String?> iconSvg(String id) async => null;
  @override
  Future<Uint8List?> font() async => null;
  @override
  Future<Uint8List?> thumbnail(File file, int size) async => null;
}

/// A server that isn't listening, with fixed addresses.
class _FakeServer extends HttpFileServer {
  _FakeServer({this.uploads = const []}) : super(resources: _NoResources());

  final List<String> uploads;

  @override
  List<String> get urls =>
      const ['http://192.168.1.42:8080', 'http://10.0.0.7:8080'];

  @override
  String? get url => urls.first;

  @override
  Stream<String> get received => Stream.fromIterable(uploads);
}

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  setUpAll(() async {
    if (screenshotsEnabled) await loadAppFonts();
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    final tag = mode.name;
    for (final (name, server) in [
      ('server_dialog', _FakeServer()),
      (
        'server_dialog_uploads',
        _FakeServer(uploads: ['/sdcard/Download/Holiday video.mp4'])
          ..allowUploads = true,
      ),
    ]) {
      testWidgets('$name $tag', (tester) async {
        SharedPreferences.setMockInitialValues({});
        setScreenSize(tester, const Size(390, 844));
        await tester.pumpWidget(screenshotFrame(themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ServerStatusDialog(
                      server: server,
                      folderName: 'Download',
                    ),
                  ),
                  child: const Text('Share'),
                ),
              ),
            ),
          ),
          themeMode: mode,
        )));
        await tester.tap(find.text('Share'));
        await settle(tester, rounds: 4);
        await saveScreenshot(tester, '${name}_$tag');
      }, skip: !screenshotsEnabled);
    }
  }
}
