import 'dart:async';
import 'dart:io';

import 'package:explorer/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';

/// Windows, Linux and macOS: plays [file] with media_kit (libmpv), which
/// decodes whatever FFmpeg can (MKV, HEVC, AV1, VP9, old AVI and WMV...)
/// with hardware decoding where available. Desktop controls: seek bar,
/// volume, fullscreen, and keys (Space, ←/→, ↑/↓, F, M).
class DesktopVideoPlayer extends StatefulWidget {
  const DesktopVideoPlayer({super.key, required this.file});

  final File file;

  @override
  State<DesktopVideoPlayer> createState() => _DesktopVideoPlayerState();
}

class _DesktopVideoPlayerState extends State<DesktopVideoPlayer> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<String>? _errors;
  String? _error;

  @override
  void initState() {
    super.initState();
    _errors = _player.stream.error.listen((message) {
      // Errors after playback started (a bad frame) don't stop it.
      if (!mounted || _player.state.duration > Duration.zero) return;
      setState(() => _error = message);
    });
    _player.open(Media(widget.file.path));
  }

  @override
  void dispose() {
    _errors?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ViewerMessage(
        icon: LucideIcons.videoOff,
        title: "Can't play this video",
        message: _error,
        actions: [
          FilledButton.icon(
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('Open with another app'),
            onPressed: () => OpenFilex.open(widget.file.path),
          ),
        ],
      );
    }
    final colors = immersiveShadTheme(context).colorScheme;
    final theme = MaterialDesktopVideoControlsThemeData(
      seekBarPositionColor: colors.primary,
      seekBarThumbColor: colors.primary,
      seekBarBufferColor: colors.foreground.withValues(alpha: 0.35),
      seekBarColor: colors.foreground.withValues(alpha: 0.18),
    );
    return MaterialDesktopVideoControlsTheme(
      normal: theme,
      fullscreen: theme,
      child: Video(
        controller: _controller,
        controls: MaterialDesktopVideoControls,
        // Shown until the first frame.
        fill: Colors.black,
      ),
    );
  }
}
