import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Windows, Linux and macOS support that phones don't need.
abstract final class Desktop {
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Windows and Linux play video and audio with media_kit (libmpv, with
  /// FFmpeg's decoders): video in DesktopVideoPlayer, audio through
  /// just_audio, which has no implementation there of its own. macOS keeps
  /// the AVFoundation players.
  static void initMedia() {
    if (!Platform.isWindows && !Platform.isLinux) return;
    String? libmpv;
    if (Platform.isLinux) {
      // The AppImage, the Flatpak and the archives carry their own libmpv
      // next to the app's libraries; the .deb, .rpm and snap use the
      // system's.
      final bundled = p.join(
        p.dirname(Platform.resolvedExecutable),
        'lib',
        'libmpv.so.2',
      );
      if (File(bundled).existsSync()) libmpv = bundled;
    }
    // Doesn't throw without libmpv: playback then reports an error instead.
    MediaKit.ensureInitialized(libmpv: libmpv);
    JustAudioMediaKit.ensureInitialized(
      windows: true,
      linux: true,
      libmpv: libmpv,
    );
  }

  /// Whether files can be shared with other apps (share_plus shares only
  /// text on Linux).
  static bool get canShareFiles => !Platform.isLinux;

  /// Whether flutter_inappwebview works here (it has no Linux version).
  static bool get webViewsSupported => !Platform.isLinux;

  static const _folderFlag = '--folder=';

  /// Opens another Explorer window showing [folder], or viewing [file]
  /// (over its folder). Each window is its own process, so it keeps working
  /// if another one closes.
  static Future<void> openWindow({String? folder, String? file}) =>
      launcher(Platform.resolvedExecutable, [
        if (file != null)
          file
        else if (folder != null)
          '$_folderFlag$folder',
      ]);

  /// Starts a window; tests replace it.
  @visibleForTesting
  static Future<void> Function(String executable, List<String> args) launcher =
      (executable, args) =>
          Process.start(executable, args, mode: ProcessStartMode.detached);

  /// What the command line asks to open: a folder (from [openWindow], or a
  /// folder passed by the system) or a file to view.
  static ({String? folder, String? file}) parseArgs(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith(_folderFlag)) {
        return (folder: arg.substring(_folderFlag.length), file: null);
      }
      if (arg.startsWith('-')) continue;
      if (FileSystemEntity.isDirectorySync(arg)) {
        return (folder: p.absolute(arg), file: null);
      }
      if (FileSystemEntity.isFileSync(arg)) {
        return (folder: p.dirname(p.absolute(arg)), file: p.absolute(arg));
      }
    }
    return (folder: null, file: null);
  }
}
