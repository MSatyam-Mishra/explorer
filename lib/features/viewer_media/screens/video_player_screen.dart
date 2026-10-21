import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:explorer/features/viewer_kit/viewer_kit.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

class VideoPlayerScreen extends StatefulWidget {
  final File videoFile;

  const VideoPlayerScreen({super.key, required this.videoFile});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final controller = VideoPlayerController.file(widget.videoFile);
    _videoPlayerController = controller;
    try {
      await controller.initialize();
      // Left the screen while the player was preparing: dispose() already
      // released it; don't start playback behind the user's back.
      if (!mounted) return;

      // The player always sits on black, so its controls use the dark
      // palette of the current colour scheme.
      final colors = immersiveShadTheme(context).colorScheme;
      final progress = ChewieProgressColors(
        playedColor: colors.primary,
        handleColor: colors.foreground,
        bufferedColor: colors.foreground.withValues(alpha: 0.35),
        backgroundColor: colors.foreground.withValues(alpha: 0.18),
      );
      _chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        aspectRatio: controller.value.aspectRatio,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        materialProgressColors: progress,
        cupertinoProgressColors: progress,
        errorBuilder: (context, errorMessage) => ViewerMessage(
          icon: LucideIcons.videoOff,
          title: "Can't play this video",
          details: errorMessage,
        ),
      );

      setState(() {});
    } catch (e) {
      debugPrint('Error initializing video player: $e');
      if (mounted) {
        setState(() => _error =
            "This video's format or codec isn't supported by the built-in player.");
      }
    }
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ImmersiveTheme(child: Builder(builder: _build));
  }

  Widget _build(BuildContext context) {
    final chewie = _chewieController;
    final Widget content;
    if (_error != null) {
      content = ViewerMessage(
        icon: LucideIcons.videoOff,
        title: "Can't play this video",
        message: _error,
        actions: [
          FilledButton.icon(
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('Open with another app'),
            onPressed: () => OpenFilex.open(widget.videoFile.path),
          ),
        ],
      );
    } else if (chewie != null &&
        chewie.videoPlayerController.value.isInitialized) {
      content = Chewie(controller: chewie);
    } else {
      content = const ViewerLoading();
    }
    return ExplorerScaffold(
      backgroundColor: Colors.black,
      title: p.basename(widget.videoFile.path),
      body: Padding(
        padding: EdgeInsets.only(
          top: DockedGlossyTopBar.contentTopInset(context),
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        child: Center(child: content),
      ),
    );
  }
}
