import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

import 'downloader_backend.dart';

/// Programs the desktop video downloader downloads into [directory] when the
/// computer doesn't have them:
/// * FFmpeg, which merges video and audio and converts to MP3, from
///   yt-dlp's FFmpeg builds (patched for yt-dlp);
/// * Deno, the JavaScript runtime yt-dlp needs for YouTube.
/// yt-dlp itself comes from YtDlpInstaller. Each download is checked
/// against the SHA-256 sums its project publishes.
class DesktopTools {
  DesktopTools(
    this.directory, {
    this.ffmpegBase =
        'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download',
    this.denoBase = 'https://github.com/denoland/deno/releases/latest/download',
  });

  final Directory directory;

  /// Where the releases are downloaded from (tests use a local server).
  final String ffmpegBase;
  final String denoBase;

  static String _exe(String name) => Platform.isWindows ? '$name.exe' : name;

  /// yt-dlp's FFmpeg build for this computer; null where there is none
  /// (macOS: install FFmpeg with Homebrew).
  static String? ffmpegAsset() {
    final abi = Abi.current();
    return switch (abi) {
      Abi.windowsX64 => 'ffmpeg-master-latest-win64-gpl-shared.zip',
      Abi.windowsArm64 => 'ffmpeg-master-latest-winarm64-gpl-shared.zip',
      Abi.linuxX64 => 'ffmpeg-master-latest-linux64-gpl.tar.xz',
      Abi.linuxArm64 => 'ffmpeg-master-latest-linuxarm64-gpl.tar.xz',
      _ => null,
    };
  }

  /// Deno's release for this computer.
  static String? denoAsset() => switch (Abi.current()) {
        Abi.windowsX64 => 'deno-x86_64-pc-windows-msvc.zip',
        Abi.windowsArm64 => 'deno-aarch64-pc-windows-msvc.zip',
        Abi.linuxX64 => 'deno-x86_64-unknown-linux-gnu.zip',
        Abi.linuxArm64 => 'deno-aarch64-unknown-linux-gnu.zip',
        Abi.macosX64 => 'deno-x86_64-apple-darwin.zip',
        Abi.macosArm64 => 'deno-aarch64-apple-darwin.zip',
        _ => null,
      };

  /// About how much each download is and takes once unpacked, for the
  /// question before downloading (the real sizes come with the download).
  static int get ffmpegDownloadBytes => Platform.isWindows ? 92000000 : 157000000;
  static int get ffmpegDiskBytes => Platform.isWindows ? 180000000 : 280000000;
  static const denoDownloadBytes = 42000000;
  static const denoDiskBytes = 115000000;

  Directory get _ffmpegDir => Directory(p.join(directory.path, 'ffmpeg'));
  Directory get _denoDir => Directory(p.join(directory.path, 'deno'));

  File get ffmpeg => File(p.join(_ffmpegDir.path, 'bin', _exe('ffmpeg')));
  File get deno => File(p.join(_denoDir.path, _exe('deno')));

  bool get hasFfmpeg => ffmpeg.existsSync();
  bool get hasDeno => deno.existsSync();

  Future<void> installFfmpeg({
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final asset = ffmpegAsset();
    if (asset == null) {
      throw const DownloaderException(
          'Explorer has no FFmpeg download for this computer. Install FFmpeg '
          '(on a Mac: brew install ffmpeg) and reopen the downloader.');
    }
    final sums = await _getText(Uri.parse('$ffmpegBase/checksums.sha256'));
    final expected = _hashFor(sums, asset);
    if (expected == null) {
      throw DownloaderException('The FFmpeg builds list no checksum for $asset.');
    }
    await _install(
      name: 'FFmpeg',
      url: Uri.parse('$ffmpegBase/$asset'),
      asset: asset,
      sha256: expected,
      target: _ffmpegDir,
      // The archive holds ffmpeg-…/bin, doc, include, lib: keep bin, but
      // not ffplay (a player; in the static Linux build another ~130 MB).
      pick: (unpacked) async {
        final exe = await _find(unpacked, _exe('ffmpeg'));
        if (exe == null) return null;
        final ffplay = File(p.join(exe.parent.path, _exe('ffplay')));
        if (await ffplay.exists()) await ffplay.delete();
        return exe.parent;
      },
      into: 'bin',
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<void> installDeno({
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final asset = denoAsset();
    if (asset == null) {
      throw const DownloaderException('Explorer has no Deno download for this computer.');
    }
    final sum = await _getText(Uri.parse('$denoBase/$asset.sha256sum'));
    // "hash  name", or PowerShell's "Hash : HASH" for Windows builds.
    final expected = RegExp(r'[0-9a-fA-F]{64}').firstMatch(sum)?.group(0)?.toLowerCase();
    if (expected == null) {
      throw DownloaderException('Deno lists no checksum for $asset.');
    }
    await _install(
      name: 'Deno',
      url: Uri.parse('$denoBase/$asset'),
      asset: asset,
      sha256: expected,
      target: _denoDir,
      pick: (unpacked) async => unpacked,
      into: null,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Deletes the downloaded FFmpeg and Deno.
  Future<void> remove() async {
    for (final dir in [_ffmpegDir, _denoDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Downloads [url] (checked against [sha256]), unpacks it and moves the
  /// folder [pick] chooses to [target] (or [target]/[into]), replacing what
  /// was there only once everything worked.
  Future<void> _install({
    required String name,
    required Uri url,
    required String asset,
    required String sha256,
    required Directory target,
    required Future<Directory?> Function(Directory unpacked) pick,
    required String? into,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await directory.create(recursive: true);
    final work = await directory.createTemp('.download-');
    try {
      final archive = File(p.join(work.path, asset));
      await _download(url, archive, sha256,
          name: name, onProgress: onProgress, isCancelled: isCancelled);
      final unpacked = Directory(p.join(work.path, 'unpacked'));
      await unpacked.create();
      await _extract(archive, unpacked);
      final picked = await pick(unpacked);
      if (picked == null) {
        throw DownloaderException("The $name download didn't contain the program.");
      }
      final staged = Directory(p.join(work.path, 'staged'));
      if (into == null) {
        await picked.rename(staged.path);
      } else {
        await staged.create();
        await picked.rename(p.join(staged.path, into));
      }
      if (!Platform.isWindows) {
        await Process.run('chmod', ['-R', 'u+rwX,go+rX', staged.path]);
        await for (final entity in staged.list(recursive: true)) {
          if (entity is File && p.extension(entity.path).isEmpty) {
            await Process.run('chmod', ['755', entity.path]);
          }
        }
      }
      if (await target.exists()) await target.delete(recursive: true);
      await staged.rename(target.path);
    } finally {
      if (await work.exists()) await work.delete(recursive: true);
    }
  }

  static Future<void> _extract(File archive, Directory out) async {
    // System tar is much faster for .tar.xz; Windows' tar.exe also reads zip.
    if (archive.path.endsWith('.tar.xz') || Platform.isWindows) {
      try {
        final result = await Process.run('tar', ['-xf', archive.path, '-C', out.path]);
        if (result.exitCode == 0) return;
      } catch (_) {}
      await for (final e in out.list()) {
        await e.delete(recursive: true);
      }
    }
    await extractFileToDisk(archive.path, out.path);
  }

  static Future<File?> _find(Directory root, String name) async {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path) == name) return entity;
    }
    return null;
  }

  static HttpClient _client() => HttpClient()
    ..userAgent = 'Explorer-VideoDownloader'
    ..connectionTimeout = const Duration(seconds: 20);

  /// Tries again this many times when the connection drops, continuing
  /// where it stopped.
  static const _attempts = 6;

  static Future<void> _download(
    Uri url,
    File out,
    String sha256, {
    required String name,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = _client();
    var digest = SHA256Digest();
    var received = 0;
    int? total;
    try {
      for (var attempt = 1;; attempt++) {
        try {
          final request = await client.getUrl(url);
          if (received > 0) {
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
          }
          final response = await request.close();
          final resumed = received > 0 && response.statusCode == 206;
          if (!resumed && response.statusCode != 200) {
            throw DownloaderException(
                "Couldn't download $name (the server said ${response.statusCode}).");
          }
          if (!resumed) {
            // A fresh start (first try, or the server can't continue).
            digest = SHA256Digest();
            received = 0;
            total = response.contentLength > 0 ? response.contentLength : null;
          }
          final sink = out.openWrite(mode: resumed ? FileMode.append : FileMode.write);
          try {
            await for (final chunk in response) {
              if (isCancelled?.call() ?? false) {
                throw const DownloaderException('Cancelled', cancelled: true);
              }
              final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
              digest.update(bytes, 0, bytes.length);
              sink.add(bytes);
              received += bytes.length;
              onProgress?.call(received, total);
            }
          } finally {
            await sink.close();
          }
          if (total != null && received < total) {
            throw const HttpException('Connection closed while receiving data');
          }
          break;
        } on IOException {
          // Dropped or timed out (SocketException, HttpException):
          // continue from where it stopped.
          if (attempt >= _attempts) rethrow;
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
      final hash = Uint8List(digest.digestSize);
      digest.doFinal(hash, 0);
      final actual = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (actual != sha256) {
        throw DownloaderException(
            'The downloaded $name failed its checksum test, so it was not installed.');
      }
    } on SocketException catch (e) {
      throw DownloaderException("Couldn't download $name: ${e.message}");
    } on HttpException catch (e) {
      throw DownloaderException("Couldn't download $name: ${e.message}");
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _getText(Uri url) async {
    final client = _client();
    try {
      final response = await (await client.getUrl(url)).close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw DownloaderException(
            "Couldn't download ${p.basename(url.path)} (the server said ${response.statusCode}).");
      }
      return body;
    } on SocketException catch (e) {
      throw DownloaderException("Couldn't reach GitHub: ${e.message}");
    } finally {
      client.close(force: true);
    }
  }

  /// The hash for [asset] in a `hash  name` checksum list.
  static String? _hashFor(String sums, String asset) {
    for (final line in const LineSplitter().convert(sums)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length == 2 && parts[1].replaceFirst('*', '') == asset) {
        return parts[0].toLowerCase();
      }
    }
    return null;
  }
}
