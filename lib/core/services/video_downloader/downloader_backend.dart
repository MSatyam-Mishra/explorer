import 'dart:io';

import 'android_downloader_backend.dart';
import 'desktop_downloader_backend.dart';
import 'ytdlp_models.dart';

/// Thrown by backends with a message fit to show the user.
class DownloaderException implements Exception {
  const DownloaderException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// What the backend can do right now.
class BackendStatus {
  const BackendStatus({
    required this.ready,
    required this.needsSetup,
    required this.hasFfmpeg,
    this.ffmpegNote,
    this.setupNote,
  });

  /// yt-dlp can run without further setup.
  final bool ready;

  /// The first [VideoDownloaderBackend.prepare] does heavy work (unpack
  /// Python and FFmpeg, download yt-dlp).
  final bool needsSetup;
  final bool hasFfmpeg;

  /// Why FFmpeg is missing, or where it comes from.
  final String? ffmpegNote;

  /// What the first-time setup will do.
  final String? setupNote;
}

class BackendPaths {
  const BackendPaths({required this.defaultOutputDir, required this.workRoot});

  final String defaultOutputDir;

  /// Parent of the per-job folders for partial files.
  final String workRoot;
}

/// Result of a yt-dlp update.
class UpdateResult {
  const UpdateResult({required this.updated, required this.version});

  final bool updated;
  final String? version;
}

sealed class BackendEvent {
  const BackendEvent();
}

class JobChanged extends BackendEvent {
  const JobChanged(this.job);

  final DownloadJob job;
}

class JobRemoved extends BackendEvent {
  const JobRemoved(this.id);

  final String id;
}

/// Runs yt-dlp on one platform: Android through youtubedl-android in a
/// foreground service, desktop with the official yt-dlp binary.
abstract class VideoDownloaderBackend {
  const VideoDownloaderBackend();

  static VideoDownloaderBackend forPlatform() {
    if (Platform.isAndroid) return AndroidDownloaderBackend();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return DesktopDownloaderBackend();
    }
    return const UnsupportedDownloaderBackend();
  }

  /// Null when supported, else why not.
  String? get unsupportedReason => null;

  /// Most jobs that run at once.
  int get maxConcurrent => 2;

  Future<BackendStatus> status();

  /// Sets yt-dlp up; slow the first time. [onProgress] gets 0–1 when the
  /// work can be measured, else null.
  Future<void> prepare({void Function(double? progress, String message)? onProgress});

  Future<String?> version();

  /// Updates yt-dlp to the latest stable release.
  Future<UpdateResult> update();

  Future<BackendPaths> paths();

  /// Whether files can be written to [dir].
  Future<bool> canWrite(String dir);

  /// `yt-dlp -J` output for [url]; cancel with [cancelFetch].
  Future<String> fetchInfoJson(String url, {required String requestId});

  Future<void> cancelFetch(String requestId);

  Stream<BackendEvent> get events;

  Future<void> enqueue(JobSpec spec);

  Future<void> cancel(String id);

  Future<void> retry(String id);

  /// Forgets a job and deletes its partial files.
  Future<void> remove(String id);

  Future<List<DownloadJob>> jobs();

  /// Jobs that finished while nobody listened (Android: app closed).
  Future<List<DownloadJob>> takeFinished() async => const [];

  Future<void> ackFinished(List<String> ids) async {}

  /// Tells the platform a file was deleted (Android: media index).
  Future<void> fileDeleted(String path) async {}
}

/// iOS and web: no yt-dlp.
class UnsupportedDownloaderBackend extends VideoDownloaderBackend {
  const UnsupportedDownloaderBackend();

  static const _reason = "Video downloading isn't available on this device. "
      'It needs yt-dlp, which iOS apps cannot run. Use Explorer on Android, '
      'Windows, macOS or Linux to download videos.';

  @override
  String? get unsupportedReason => _reason;

  Never _fail() => throw const DownloaderException(_reason);

  @override
  Future<BackendStatus> status() async =>
      const BackendStatus(ready: false, needsSetup: false, hasFfmpeg: false);

  @override
  Future<void> prepare({void Function(double? progress, String message)? onProgress}) async =>
      _fail();

  @override
  Future<String?> version() async => null;

  @override
  Future<UpdateResult> update() async => _fail();

  @override
  Future<BackendPaths> paths() async => _fail();

  @override
  Future<bool> canWrite(String dir) async => false;

  @override
  Future<String> fetchInfoJson(String url, {required String requestId}) async => _fail();

  @override
  Future<void> cancelFetch(String requestId) async {}

  @override
  Stream<BackendEvent> get events => const Stream.empty();

  @override
  Future<void> enqueue(JobSpec spec) async => _fail();

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<void> retry(String id) async {}

  @override
  Future<void> remove(String id) async {}

  @override
  Future<List<DownloadJob>> jobs() async => const [];
}
