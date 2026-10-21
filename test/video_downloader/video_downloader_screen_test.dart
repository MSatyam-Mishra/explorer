import 'dart:async';

import 'package:explorer/core/services/video_downloader/downloader_backend.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
import 'package:explorer/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:explorer/features/video_downloader/screens/video_downloader_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

const _info = '''
{"id": "abc", "title": "Test clip", "uploader": "Someone", "duration": 75, "_type": "video",
 "webpage_url": "https://example.com/watch/abc", "extractor_key": "Example",
 "formats": [
  {"format_id": "a1", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128, "filesize": 1000000},
  {"format_id": "v360", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "height": 360, "width": 640, "filesize": 3000000},
  {"format_id": "v720", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "height": 720, "width": 1280, "filesize": 9000000}
 ]}
''';

const _playlist = '''
{"_type": "playlist", "id": "pl", "title": "A playlist", "webpage_url": "https://example.com/pl",
 "entries": [
  {"_type": "url", "url": "https://example.com/watch/1", "title": "First", "duration": 10},
  {"_type": "url", "url": "https://example.com/watch/2", "title": "Second", "duration": 20},
  {"_type": "playlist", "webpage_url": "https://example.com/pl/tab", "title": "Nested", "extractor_key": "ExampleTab"}
 ]}
''';

/// In-memory backend: jobs "download" when told to.
class FakeBackend extends VideoDownloaderBackend {
  final _events = StreamController<BackendEvent>.broadcast();
  final jobsById = <String, DownloadJob>{};
  final specs = <JobSpec>[];

  /// Android's downloaded engine; null like desktop.
  EngineInfo? engine;
  int engineDownloads = 0;

  /// Holds the engine download until completed (or cancelled).
  Completer<void>? holdDownload;

  @override
  Future<BackendStatus> status() async => BackendStatus(
        ready: engine?.installed ?? true,
        needsSetup: !(engine?.installed ?? true),
        hasFfmpeg: true,
        engine: engine,
      );

  @override
  Future<void> prepare({void Function(double? progress, String message)? onProgress}) async {
    final e = engine;
    if (e == null || e.installed) return;
    engineDownloads++;
    onProgress?.call(0.25, 'Downloading the video engine: 12 of 50 MB');
    await holdDownload?.future;
    engine = EngineInfo(installed: true, downloadBytes: e.downloadBytes, diskBytes: e.diskBytes);
  }

  @override
  Future<void> cancelPrepare() async =>
      holdDownload?.completeError(const DownloaderException('Cancelled', cancelled: true));

  @override
  Future<void> removeEngine() async {
    final e = engine!;
    engine = EngineInfo(installed: false, downloadBytes: e.downloadBytes, diskBytes: e.diskBytes);
  }

  @override
  Future<String?> version() async => '2026.08.19';

  @override
  Future<UpdateResult> update() async => const UpdateResult(updated: false, version: '2026.08.19');

  @override
  Future<BackendPaths> paths() async =>
      const BackendPaths(defaultOutputDir: '/downloads/Explorer Videos', workRoot: '/tmp/work');

  @override
  Future<bool> canWrite(String dir) async => true;

  @override
  Future<String> fetchInfoJson(String url, {required String requestId}) async =>
      url.contains('/pl') ? _playlist : _info;

  @override
  Future<void> cancelFetch(String requestId) async {}

  @override
  Stream<BackendEvent> get events => _events.stream;

  void emit(DownloadJob job) {
    jobsById[job.id] = job;
    _events.add(JobChanged(job));
  }

  @override
  Future<void> enqueue(JobSpec spec) async {
    specs.add(spec);
    emit(DownloadJob(
      id: spec.id,
      url: spec.url,
      title: spec.title,
      status: JobStatus.running,
      createdAt: DateTime.now(),
      percent: 42,
      downloaded: 4200000,
      total: 10000000,
      speed: 1500000,
      eta: 4,
      stage: 'download',
      part: 1,
      meta: spec.meta,
    ));
  }

  @override
  Future<void> cancel(String id) async {
    final j = jobsById[id]!;
    emit(DownloadJob(id: id, url: j.url, title: j.title, status: JobStatus.cancelled, createdAt: j.createdAt));
  }

  @override
  Future<void> retry(String id) async {}

  @override
  Future<void> remove(String id) async {
    jobsById.remove(id);
    _events.add(JobRemoved(id));
  }

  @override
  Future<List<DownloadJob>> jobs() async => jobsById.values.toList();
}

Widget _app(Widget home) => themedApp(home);

void main() {
  late FakeBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakeBackend();
    VideoDownloaderController.instance = VideoDownloaderController(backend);
  });

  Future<void> pumpScreen(WidgetTester tester, Size size, {String? url}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(VideoDownloaderScreen(initialUrl: url)));
    await tester.pumpAndSettle();
  }

  testWidgets('phone: notice, fetch shared link, download, queue', (tester) async {
    await pumpScreen(tester, const Size(390, 844), url: 'Look https://example.com/watch/abc');
    expect(find.text('Before you download'), findsOneWidget);
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    // The shared link was fetched right away.
    expect(find.text('Test clip'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsNothing, reason: 'no format that tall');
    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();
    expect(find.textContaining('About 10 MB'), findsOneWidget);

    final panel = find
        .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first;
    final download = find.widgetWithText(FilledButton, 'Download');
    await tester.scrollUntilVisible(download, 100, scrollable: panel);
    await tester.ensureVisible(download);
    await tester.pumpAndSettle();
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(backend.specs, hasLength(1));
    expect(backend.specs.single.args, containsAllInOrder(['--format-sort', 'res:720,fps,vcodec:h264,acodec:aac']));
    expect(backend.specs.single.outputDir, '/downloads/Explorer Videos');

    await tester.tap(find.text('Downloads (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.textContaining('1.5 MB/s'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cancelled'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('No downloads yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet: playlist selection and side pane', (tester) async {
    await pumpScreen(tester, const Size(1280, 800));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'https://example.com/pl');
    await tester.pump(); // the Fetch button enables on the next frame
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(find.text('A playlist'), findsOneWidget);
    expect(find.text('2 of 2 selected'), findsOneWidget);
    final panel = find
        .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('Open'), 100, scrollable: panel);
    expect(find.text('Open'), findsOneWidget, reason: 'nested playlist');

    await tester.tap(find.text('1. First'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 selected'), findsOneWidget);
    await tester.ensureVisible(find.text('Download 1 item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download 1 item'));
    await tester.pumpAndSettle();
    expect(backend.specs.single.url, 'https://example.com/watch/2');
    expect(backend.specs.single.outputDir, p.join('/downloads/Explorer Videos', 'A playlist'));
    // The queue is visible beside the panel.
    expect(find.textContaining('42%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  const missingEngine = EngineInfo(installed: false, downloadBytes: 49930835, diskBytes: 119773698);

  testWidgets('engine: asks before downloading it; nothing works without it', (tester) async {
    backend.engine = missingEngine;
    await pumpScreen(tester, const Size(390, 844));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    expect(find.text('Download the video engine?'), findsOneWidget);
    expect(find.textContaining('50 MB, Wi-Fi recommended'), findsOneWidget);
    expect(find.text('120 MB'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(backend.engineDownloads, 0);
    expect(find.text('Download the video engine to start'), findsOneWidget);

    // Fetching asks again; agreeing downloads it, then the fetch goes on.
    await tester.enterText(find.byType(TextField), 'https://example.com/watch/abc');
    await tester.pump();
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(find.text('Download the video engine?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();
    expect(backend.engineDownloads, 1);
    expect(find.text('Download the video engine to start'), findsNothing);
    expect(find.text('Test clip'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('engine: the download can be cancelled', (tester) async {
    backend.engine = missingEngine;
    backend.holdDownload = Completer<void>();
    await pumpScreen(tester, const Size(390, 844));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    // A spinner runs while downloading, so no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Downloading the video engine: 12 of 50 MB'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download the video engine to start'), findsOneWidget);
    expect(find.textContaining("couldn't"), findsNothing, reason: 'cancelling is no error');

    // The card's button downloads without asking again.
    backend.holdDownload = null;
    await tester.ensureVisible(find.text('Download (50 MB)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download (50 MB)'));
    await tester.pumpAndSettle();
    expect(find.text('Download the video engine?'), findsNothing);
    expect(find.text('Download the video engine to start'), findsNothing);
    expect(backend.engine!.installed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: the engine can be removed', (tester) async {
    backend.engine = const EngineInfo(installed: true, downloadBytes: 49930835, diskBytes: 119773698);
    final controller = VideoDownloaderController.instance;
    await controller.start();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(VideoDownloaderSettingsScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Video engine'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Python and FFmpeg, 120 MB'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove the video engine?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(backend.engine!.installed, isFalse);
    expect(find.textContaining('Not downloaded'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Download'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings screen builds', (tester) async {
    final controller = VideoDownloaderController.instance;
    await controller.start();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(VideoDownloaderSettingsScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('Downloader settings'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Licenses'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Licenses'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
