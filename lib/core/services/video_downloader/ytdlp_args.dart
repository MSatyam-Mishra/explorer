import 'downloader_settings.dart';
import 'ytdlp_models.dart';

/// Builds yt-dlp command lines. Shared by Android (youtubedl-android) and
/// desktop (official binaries), so both behave the same.
///
/// Downloads print machine-readable lines starting with the markers below
/// (parsed by `YtDlpOutputParser`, and by VideoDownloadJobs.kt on Android —
/// keep them in sync).
abstract final class YtDlpArgs {
  static const progressMarker = '__EXPL_P__';
  static const postprocessMarker = '__EXPL_PP__';
  static const fileMarker = '__EXPL_FILE__';
  static const titleMarker = '__EXPL_TITLE__';
  static const thumbnailMarker = '__EXPL_THUMB__';

  /// status|downloaded|total|estimate|speed|eta|format|fragment|fragments
  static const progressTemplate = 'download:$progressMarker'
      '%(progress.status)s|%(progress.downloaded_bytes)s|'
      '%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|'
      '%(progress.speed)s|%(progress.eta)s|%(info.format_id)s|'
      '%(progress.fragment_index)s|%(progress.fragment_count)s';

  static const postprocessTemplate = 'postprocess:$postprocessMarker'
      '%(progress.status)s|%(progress.postprocessor)s';

  /// Info for a link: one JSON document; playlists are listed, not resolved.
  static List<String> info() => const [
        '--dump-single-json',
        '--flat-playlist',
        '--no-update',
      ];

  /// Options for downloading one item (the URL is added by the backend,
  /// after `--`).
  static List<String> download({
    required DownloadOptions options,
    required DownloaderSettings settings,
    required bool hasFfmpeg,
    required String outputDir,
    String? workDir,
  }) {
    final args = <String>[
      '--newline',
      '--progress',
      '--no-update',
      '--no-playlist',
      '--no-mtime',
      '--no-simulate',
      '--concurrent-fragments', '4',
      '--progress-template', progressTemplate,
      '--progress-template', postprocessTemplate,
      '--print', 'video:$titleMarker%(title)s',
      '--print', 'video:$thumbnailMarker%(thumbnail)s',
      '--print', 'after_move:$fileMarker%(filepath)s',
      '--paths', 'home:$outputDir',
      if (workDir != null) ...['--paths', 'temp:$workDir'],
      '--output', settings.effectiveTemplate,
    ];

    final audio = options.kind == DownloadKind.audio ||
        (options.kind == DownloadKind.format &&
            (options.format?.isAudioOnly ?? false));

    switch (options.kind) {
      case DownloadKind.video:
        args.addAll(_videoSelection(options.quality, settings, hasFfmpeg));
      case DownloadKind.audio:
        args.addAll(_audioSelection(options.audioFormat, hasFfmpeg));
      case DownloadKind.format:
        final f = options.format;
        if (f == null) {
          args.addAll(_videoSelection(VideoQuality.best, settings, hasFfmpeg));
        } else if (f.isVideoOnly && hasFfmpeg) {
          // Add the best audio so the file has sound.
          args.addAll(['--format', '${f.id}+bestaudio/${f.id}']);
          args.addAll(_mergeFormat(settings));
        } else {
          args.addAll(['--format', f.id]);
        }
    }

    if (hasFfmpeg) {
      if (settings.embedMetadata) args.add('--embed-metadata');
      if (settings.embedThumbnail) args.add('--embed-thumbnail');
      if (settings.embedChapters && !audio) args.add('--embed-chapters');
    }

    if (settings.subtitles && !audio) {
      args.addAll([
        '--write-subs',
        if (settings.autoSubtitles) '--write-auto-subs',
        '--sub-langs',
        settings.subtitleLangs.trim().isEmpty ? 'en.*' : settings.subtitleLangs.trim(),
        // Without FFmpeg the subtitle files are saved next to the video.
        if (hasFfmpeg) '--embed-subs',
      ]);
    }
    return args;
  }

  static List<String> _videoSelection(
    VideoQuality quality,
    DownloaderSettings settings,
    bool hasFfmpeg,
  ) {
    final h = quality.height;
    // Format sorting (-S) rather than filters: "res:720" picks the best
    // stream up to 720p, or the smallest one above if there is none.
    final sort = <String>[
      h == null ? 'res' : 'res:$h',
      // "vcodec:h264": the best codec no newer than H.264 (so H.264 when
      // there is one), likewise AAC for audio.
      if (settings.preferCompatible) ...['fps', 'vcodec:h264', 'acodec:aac'],
      if (!hasFfmpeg) 'ext:mp4:m4a',
    ];
    if (!hasFfmpeg) {
      // Only formats that already contain video and audio.
      return ['--format', 'best', '--format-sort', sort.join(',')];
    }
    return [
      '--format', 'bestvideo*+bestaudio/best',
      '--format-sort', sort.join(','),
      ..._mergeFormat(settings),
    ];
  }

  static List<String> _mergeFormat(DownloaderSettings settings) =>
      switch (settings.container) {
        VideoContainer.auto => ['--merge-output-format', 'mp4/mkv'],
        VideoContainer.mp4 => ['--merge-output-format', 'mp4'],
        VideoContainer.mkv => ['--merge-output-format', 'mkv'],
      };

  static List<String> _audioSelection(AudioFormat format, bool hasFfmpeg) {
    if (!hasFfmpeg) {
      // No conversion possible: take an M4A stream as is when there is one.
      return ['--format', 'bestaudio[ext=m4a]/bestaudio/best'];
    }
    return switch (format) {
      AudioFormat.m4a => [
          '--format', 'bestaudio[ext=m4a]/bestaudio/best',
          '--extract-audio', '--audio-format', 'm4a', '--audio-quality', '0',
        ],
      AudioFormat.mp3 => [
          '--format', 'bestaudio/best',
          '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0',
        ],
    };
  }
}
