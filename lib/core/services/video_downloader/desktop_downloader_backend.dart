import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'downloader_backend.dart';
import 'ytdlp_args.dart';
import 'ytdlp_installer.dart';
import 'ytdlp_models.dart';
import 'ytdlp_output.dart';

/// Windows, macOS and Linux: the official yt-dlp executable (downloaded on
/// first use into the app support folder), with FFmpeg from the system when
/// there is one. Jobs run in this process, so they continue while the app
/// is open, whichever screen is showing.
class DesktopDownloaderBackend extends VideoDownloaderBackend {
  DesktopDownloaderBackend({Directory? supportDirectory, Directory? tempDirectory})
      : _supportOverride = supportDirectory,
        _tempOverride = tempDirectory;

  final Directory? _supportOverride;
  final Directory? _tempOverride;
  final _events = StreamController<BackendEvent>.broadcast();
  final _jobs = <String, _DesktopJob>{};
  final _fetches = <String, Process>{};
  final _cancelledFetches = <String>{};
  YtDlpInstaller? _installer;
  _Tools? _tools;
  String? _versionCache;
  DateTime? _versionStamp;

  @override
  int get maxConcurrent => 2;

  Future<YtDlpInstaller> _ytDlp() async {
    if (_installer != null) return _installer!;
    final base = _supportOverride ?? await getApplicationSupportDirectory();
    return _installer = YtDlpInstaller(Directory(p.join(base.path, 'video_downloader')));
  }

  _Tools _findTools() => _tools ??= _Tools.find();

  @override
  Future<BackendStatus> status() async {
    final installer = await _ytDlp();
    final tools = _findTools();
    return BackendStatus(
      ready: installer.isInstalled,
      needsSetup: !installer.isInstalled,
      hasFfmpeg: tools.ffmpeg != null,
      ffmpegNote: tools.ffmpeg != null
          ? 'Using FFmpeg at ${tools.ffmpeg}.'
          : 'FFmpeg was not found. Without it Explorer can only download '
              'formats that already contain both video and audio (often '
              'lower quality), and cannot convert to MP3 or embed '
              'thumbnails. Install FFmpeg and make sure it is on your PATH, '
              'then reopen the downloader.',
      setupNote: 'The first time, Explorer downloads the official yt-dlp '
          'program (${YtDlpInstaller.assetName()}, about 20–40 MB) from '
          'github.com/yt-dlp/yt-dlp and checks its SHA-256 checksum.',
    );
  }

  @override
  Future<void> prepare({void Function(double? progress, String message)? onProgress}) async {
    final installer = await _ytDlp();
    if (installer.isInstalled) return;
    onProgress?.call(null, 'Downloading yt-dlp…');
    await installer.install(onProgress: (received, total) {
      final mb = (received / 1e6).toStringAsFixed(1);
      onProgress?.call(
        total == null ? null : received / total,
        total == null
            ? 'Downloading yt-dlp… $mb MB'
            : 'Downloading yt-dlp… $mb of ${(total / 1e6).toStringAsFixed(1)} MB',
      );
    });
  }

  @override
  Future<String?> version() async {
    final installer = await _ytDlp();
    if (!installer.isInstalled) return null;
    final modified = await installer.binary.lastModified();
    if (_versionCache != null && _versionStamp == modified) return _versionCache;
    final result = await Process.run(installer.binary.path, ['--version'],
        environment: _env, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) return null;
    _versionStamp = modified;
    return _versionCache = (result.stdout as String).trim();
  }

  @override
  Future<UpdateResult> update() async {
    if (_jobs.values.any((j) => j.isActive) || _fetches.isNotEmpty) {
      throw const DownloaderException(
          'Wait for the downloads to finish, then update yt-dlp.');
    }
    final installer = await _ytDlp();
    final latest = await installer.latestTag();
    final current = await version();
    if (current == latest) return UpdateResult(updated: false, version: current);
    await installer.install(tag: latest);
    _versionCache = null;
    return UpdateResult(updated: true, version: await version() ?? latest);
  }

  @override
  Future<BackendPaths> paths() async {
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {}
    downloads ??= await getApplicationDocumentsDirectory();
    final temp = _tempOverride ?? await getTemporaryDirectory();
    return BackendPaths(
      defaultOutputDir: p.join(downloads.path, 'Explorer Videos'),
      workRoot: p.join(temp.path, 'explorer_video_work'),
    );
  }

  @override
  Future<bool> canWrite(String dir) async {
    try {
      await Directory(dir).create(recursive: true);
      final probe = File(p.join(dir, '.explorer-write-test'));
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _env = {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'};

  Future<List<String>> _commonArgs() async {
    final tools = _findTools();
    return [
      if (tools.ffmpeg != null) ...['--ffmpeg-location', tools.ffmpeg!],
      if (tools.jsRuntime != null) ...['--js-runtimes', tools.jsRuntime!],
    ];
  }

  @override
  Future<String> fetchInfoJson(String url, {required String requestId}) async {
    final installer = await _ytDlp();
    final args = [...YtDlpArgs.info(), ...await _commonArgs(), '--', url];
    final process = await Process.start(installer.binary.path, args, environment: _env);
    _fetches[requestId] = process;
    try {
      final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
      final err = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
      final code = await process.exitCode;
      final stdout = await out;
      final stderr = await err;
      if (_cancelledFetches.remove(requestId)) {
        throw const DownloaderException('Cancelled', cancelled: true);
      }
      if (code != 0 && !stdout.trimLeft().startsWith('{')) {
        throw DownloaderException(YtDlpOutputParser.errorMessage(stderr));
      }
      return stdout;
    } finally {
      _fetches.remove(requestId);
    }
  }

  @override
  Future<void> cancelFetch(String requestId) async {
    final process = _fetches[requestId];
    if (process == null) return;
    _cancelledFetches.add(requestId);
    await _kill(process);
  }

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  Future<void> enqueue(JobSpec spec) async {
    if (_jobs.containsKey(spec.id)) return;
    final job = _DesktopJob(spec);
    _jobs[spec.id] = job;
    _emit(job);
    _pump();
  }

  @override
  Future<void> cancel(String id) async {
    final job = _jobs[id];
    if (job != null) await _cancel(job);
  }

  Future<void> _cancel(_DesktopJob job) async {
    if (!job.isActive) return;
    job.cancelRequested = true;
    if (job.status == JobStatus.queued) {
      job.status = JobStatus.cancelled;
      job.finishedAt = DateTime.now();
      _emit(job);
      return;
    }
    final process = job.process;
    if (process != null) await _kill(process);
  }

  @override
  Future<void> retry(String id) async {
    final job = _jobs[id];
    if (job == null ||
        (job.status != JobStatus.failed && job.status != JobStatus.cancelled)) {
      return;
    }
    job.reset();
    _emit(job);
    _pump();
  }

  @override
  Future<void> remove(String id) async {
    final job = _jobs.remove(id);
    if (job == null) return;
    job.removed = true;
    final running = job.status == JobStatus.running;
    await _cancel(job);
    if (!running) await _deleteDir(job.spec.workDir);
    _events.add(JobRemoved(id));
    _pump();
  }

  @override
  Future<List<DownloadJob>> jobs() async => [for (final j in _jobs.values) j.snapshot()];

  void _pump() {
    var running = _jobs.values.where((j) => j.status == JobStatus.running).length;
    for (final job in _jobs.values.toList()) {
      if (running >= maxConcurrent) break;
      if (job.status == JobStatus.queued && !job.cancelRequested) {
        job.status = JobStatus.running;
        running++;
        _emit(job);
        unawaited(_run(job));
      }
    }
  }

  Future<void> _run(_DesktopJob job) async {
    final spec = job.spec;
    try {
      final installer = await _ytDlp();
      if (!installer.isInstalled) await prepare();
      await Directory(spec.outputDir).create(recursive: true);
      await Directory(spec.workDir).create(recursive: true);
      final args = [...spec.args, ...await _commonArgs(), '--', spec.url];
      if (job.cancelRequested) throw const DownloaderException('Cancelled', cancelled: true);
      final process = await Process.start(installer.binary.path, args,
          workingDirectory: spec.workDir, environment: _env);
      job.process = process;
      if (job.cancelRequested) await _kill(process);
      void onLine(String line) {
        final urgent = job.tracker.apply(line);
        _emit(job, throttle: !urgent);
      }

      final out = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine)
          .asFuture<void>();
      final err = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine)
          .asFuture<void>();
      final code = await process.exitCode;
      await Future.wait([out, err]).catchError((Object _) => <void>[]);
      if (job.cancelRequested) {
        job.status = JobStatus.cancelled;
      } else if (code == 0) {
        job.status = JobStatus.done;
        job.tracker.percent = 100;
        job.tracker.stage = null;
      } else {
        job.status = JobStatus.failed;
        var error = job.tracker.failureMessage('yt-dlp exited with code $code');
        if (_findTools().ffmpeg == null && error.contains('Requested format is not available')) {
          error = 'This video is only offered as separate video and audio '
              'streams, which need FFmpeg to be combined. Install FFmpeg, make '
              'sure it is on your PATH, reopen the downloader and retry.';
        }
        job.error = error;
      }
    } on DownloaderException catch (e) {
      job.status = e.cancelled || job.cancelRequested ? JobStatus.cancelled : JobStatus.failed;
      job.error = e.cancelled ? null : e.message;
    } catch (e) {
      job.status = job.cancelRequested ? JobStatus.cancelled : JobStatus.failed;
      job.error = job.cancelRequested ? null : '$e';
    } finally {
      job.process = null;
      job.finishedAt = DateTime.now();
    }
    if (job.removed || job.status == JobStatus.done) {
      // Nothing to resume.
      await _deleteDir(spec.workDir);
    }
    if (!job.removed) _emit(job);
    _pump();
  }

  void _emit(_DesktopJob job, {bool throttle = false}) {
    if (job.removed) return;
    final now = DateTime.now();
    if (throttle && now.difference(job.lastEmit) < const Duration(milliseconds: 300)) {
      return;
    }
    job.lastEmit = now;
    _events.add(JobChanged(job.snapshot()));
  }

  Future<void> _kill(Process process) async {
    if (Platform.isWindows) {
      // yt-dlp.exe is a PyInstaller bootloader with a child process, which
      // may have started FFmpeg: end the whole tree.
      final r = await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      if (r.exitCode != 0) process.kill();
      return;
    }
    // SIGINT lets yt-dlp stop FFmpeg and clean up; force it if it lingers.
    process.kill(ProcessSignal.sigint);
    unawaited(process.exitCode.timeout(const Duration(seconds: 4), onTimeout: () {
      Process.run('pkill', ['-KILL', '-P', '${process.pid}']).ignore();
      process.kill(ProcessSignal.sigkill);
      return -1;
    }));
  }

  Future<void> _deleteDir(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

class _DesktopJob {
  _DesktopJob(this.spec) : createdAt = DateTime.now();

  final JobSpec spec;
  final DateTime createdAt;
  JobStatus status = JobStatus.queued;
  JobProgressTracker tracker = JobProgressTracker();
  bool cancelRequested = false;
  bool removed = false;
  Process? process;
  String? error;
  DateTime? finishedAt;
  DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive => status == JobStatus.queued || status == JobStatus.running;

  void reset() {
    status = JobStatus.queued;
    tracker = JobProgressTracker();
    cancelRequested = false;
    error = null;
    finishedAt = null;
  }

  DownloadJob snapshot() => DownloadJob(
        id: spec.id,
        url: spec.url,
        status: status,
        createdAt: createdAt,
        title: tracker.title ?? spec.title,
        thumbnail: spec.thumbnail ?? tracker.thumbnail,
        outputDir: spec.outputDir,
        workDir: spec.workDir,
        meta: spec.meta,
        percent: tracker.percent,
        downloaded: tracker.downloaded,
        total: tracker.total,
        speed: tracker.speed,
        eta: tracker.eta,
        stage: tracker.stage,
        part: tracker.part,
        filePath: tracker.filePath,
        error: error,
        log: status == JobStatus.failed ? tracker.log.join('\n') : null,
        finishedAt: finishedAt,
      );
}

/// FFmpeg and a JavaScript runtime (yt-dlp needs one for YouTube), looked
/// up on PATH and in the usual install folders: apps started from the
/// macOS Finder don't get the shell's PATH.
class _Tools {
  const _Tools({this.ffmpeg, this.jsRuntime});

  final String? ffmpeg;

  /// yt-dlp `--js-runtimes` value, e.g. "node:/usr/bin/node". Null when
  /// none was found, or deno is on PATH (yt-dlp's default).
  final String? jsRuntime;

  static _Tools find() {
    final ffmpeg = which('ffmpeg');
    String? js;
    for (final runtime in const ['deno', 'node', 'bun']) {
      final path = which(runtime);
      if (path != null) {
        js = '$runtime:$path';
        break;
      }
    }
    return _Tools(ffmpeg: ffmpeg, jsRuntime: js);
  }

  static String? which(String name) {
    final env = Platform.environment;
    final dirs = <String>[
      ...?(env['PATH'] ?? env['Path'])?.split(Platform.isWindows ? ';' : ':'),
      if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin'],
      if (Platform.isLinux) ...['/usr/local/bin', '/usr/bin', '/snap/bin'],
      if (Platform.isWindows && env['LOCALAPPDATA'] != null)
        p.join(env['LOCALAPPDATA']!, 'Microsoft', 'WinGet', 'Links'),
    ];
    final names = Platform.isWindows ? ['$name.exe'] : [name];
    for (final dir in dirs) {
      if (dir.trim().isEmpty) continue;
      for (final n in names) {
        final candidate = p.join(dir.trim(), n);
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}
