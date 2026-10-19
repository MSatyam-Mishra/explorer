import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
import 'package:flutter/material.dart';

import 'downloader_text.dart';

/// Lets the user pick one exact format; returns it, or null.
Future<VideoFormat?> showFormatPicker(
  BuildContext context, {
  required VideoInfo info,
  required bool hasFfmpeg,
  VideoFormat? selected,
}) {
  return showModalBottomSheet<VideoFormat>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => _FormatList(
        info: info,
        hasFfmpeg: hasFfmpeg,
        selected: selected,
        scrollController: scroll,
      ),
    ),
  );
}

class _FormatList extends StatelessWidget {
  const _FormatList({
    required this.info,
    required this.hasFfmpeg,
    required this.selected,
    required this.scrollController,
  });

  final VideoInfo info;
  final bool hasFfmpeg;
  final VideoFormat? selected;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formats = info.pickableFormats;
    final groups = <String, List<VideoFormat>>{
      'Video and audio': formats.where((f) => !f.isAudioOnly && !f.isVideoOnly).toList(),
      'Video only': formats.where((f) => f.isVideoOnly).toList(),
      'Audio only': formats.where((f) => f.isAudioOnly).toList(),
    }..removeWhere((_, list) => list.isEmpty);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text('Choose a format', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            hasFfmpeg
                ? 'Video-only formats are combined with the best audio.'
                : 'Without FFmpeg, video-only formats are saved without sound.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              group.key,
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
          for (final f in group.value)
            ListTile(
              selected: selected?.id == f.id,
              leading: Icon(
                f.isAudioOnly
                    ? Icons.audiotrack_outlined
                    : f.isVideoOnly
                        ? Icons.videocam_off_outlined
                        : Icons.movie_outlined,
              ),
              title: Text(f.shortLabel),
              subtitle: Text(
                [
                  ?f.codecLabel,
                  if (f.filesize != null)
                    '${f.filesizeApprox ? '≈' : ''}${DownloaderText.bytes(f.filesize)}',
                  if (f.tbr != null) '${f.tbr!.round()} kbit/s',
                  if (f.note != null && f.note!.isNotEmpty) f.note!,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text('#${f.id}', style: theme.textTheme.labelSmall),
              onTap: () => Navigator.pop(context, f),
            ),
        ],
      ],
    );
  }
}
