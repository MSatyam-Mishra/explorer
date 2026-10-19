import 'package:explorer/core/services/video_downloader/downloader_backend.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'downloader_text.dart';
import 'format_picker_sheet.dart';
import 'media_thumbnail.dart';

/// Link field, preview of what the link offers, download options and (for
/// playlists) the items to download.
class DownloadPanel extends StatefulWidget {
  const DownloadPanel({
    super.key,
    required this.controller,
    required this.onQueued,
    required this.onOpenSettings,
    required this.ensureRights,
    this.initialUrl,
    this.padding = EdgeInsets.zero,
  });

  final VideoDownloaderController controller;
  final String? initialUrl;

  /// Jobs were added to the queue.
  final void Function(int count) onQueued;
  final VoidCallback onOpenSettings;

  /// Shows the rights notice if needed; false when the user declined.
  final Future<bool> Function() ensureRights;
  final EdgeInsets padding;

  @override
  State<DownloadPanel> createState() => DownloadPanelState();
}

class DownloadPanelState extends State<DownloadPanel> {
  final _url = TextEditingController();
  VideoInfo? _info;
  bool _fetching = false;
  String? _error;
  late DownloadOptions _options;
  Set<int> _selected = {};
  bool _queuing = false;
  int _fetchToken = 0;

  VideoDownloaderController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _options = _c.settings.defaultOptions;
    _url.text = widget.initialUrl?.trim() ?? '';
    _url.addListener(_onText);
  }

  @override
  void dispose() {
    _url.removeListener(_onText);
    _url.dispose();
    super.dispose();
  }

  void _onText() => setState(() {});

  List<String> get _urls => DownloaderText.extractUrls(_url.text);

  /// Fetches [url], or the first link in the field.
  Future<void> fetch([String? url]) async {
    final target = url ?? _urls.firstOrNull;
    if (target == null) {
      setState(() => _error = 'Enter a link to a video, song or playlist.');
      return;
    }
    if (url != null) _url.text = url;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!await widget.ensureRights()) return;
    if (_fetching) await _c.cancelFetch();
    final token = ++_fetchToken;
    setState(() {
      _fetching = true;
      _error = null;
      _info = null;
    });
    try {
      final info = await _c.fetchInfo(target);
      if (!mounted || token != _fetchToken) return;
      setState(() {
        _info = info;
        _fetching = false;
        _options = _c.settings.defaultOptions;
        _selected = {
          for (var i = 0; i < info.entries.length; i++)
            if (!info.entries[i].isNested) i,
        };
      });
    } catch (e) {
      if (!mounted || token != _fetchToken) return;
      final cancelled = e is DownloaderException && e.cancelled;
      setState(() {
        _fetching = false;
        _error = cancelled ? null : (e is DownloaderException ? e.message : '$e');
      });
    }
  }

  void _cancelFetch() {
    _fetchToken++;
    _c.cancelFetch();
    setState(() => _fetching = false);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('The clipboard has no text')));
      return;
    }
    _url.text = text;
    if (DownloaderText.extractUrls(text).length == 1) fetch();
  }

  void _clear() {
    _fetchToken++;
    if (_fetching) _c.cancelFetch();
    _url.clear();
    setState(() {
      _info = null;
      _error = null;
      _fetching = false;
    });
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null || !await widget.ensureRights()) return;
    setState(() => _queuing = true);
    try {
      final entries = info.isPlaylist
          ? [for (final i in (_selected.toList()..sort())) info.entries[i]]
          : null;
      final count = await _c.download(info, options: _options, entries: entries);
      widget.onQueued(count);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _queuing = false);
    }
  }

  Future<void> _downloadAll(List<String> urls) async {
    if (!await widget.ensureRights()) return;
    setState(() => _queuing = true);
    try {
      final count = await _c.downloadUrls(urls);
      _url.clear();
      widget.onQueued(count);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _queuing = false);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(e is DownloaderException ? e.message : '$e'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final entries = info?.entries ?? const <PlaylistEntry>[];
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => CustomScrollView(
        slivers: [
          SliverPadding(
            padding: widget.padding.copyWith(bottom: 0),
            sliver: SliverList.list(children: [
              _urlCard(context),
              ..._statusCards(context),
              if (info != null) ...[
                _PreviewCard(info: info),
                const SizedBox(height: 12),
                _optionsCard(context, info),
                if (info.isPlaylist) _playlistHeader(context, info),
              ] else if (!_fetching && _error == null)
                _hintCard(context),
            ]),
          ),
          if (info != null && info.isPlaylist)
            SliverPadding(
              padding: EdgeInsets.only(left: widget.padding.left, right: widget.padding.right),
              sliver: SliverList.builder(
                itemCount: entries.length,
                // Own Material: the scaffold paints a background between
                // these tiles and its Material, which would hide their ink.
                itemBuilder: (context, i) => Material(
                  type: MaterialType.transparency,
                  child: _entryTile(context, entries[i], i),
                ),
              ),
            ),
          SliverPadding(padding: EdgeInsets.only(bottom: widget.padding.bottom + 24)),
        ],
      ),
    );
  }

  Widget _urlCard(BuildContext context) {
    final urls = _urls;
    final busy = _fetching || _c.engineState == EngineState.preparing;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              minLines: 1,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => urls.length > 1 ? null : fetch(),
              decoration: InputDecoration(
                hintText: 'Paste a video, song or playlist link',
                prefixIcon: const Icon(Icons.link),
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_url.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: _clear,
                      ),
                    IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste),
                      onPressed: _paste,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (urls.length > 1)
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy ? null : () => fetch(urls.first),
                    child: const Text('Open first link'),
                  ),
                  FilledButton.icon(
                    onPressed: busy || _queuing ? null : () => _downloadAll(urls),
                    icon: const Icon(Icons.download),
                    label: Text('Download all ${urls.length}'),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: busy || urls.isEmpty ? null : () => fetch(),
                  icon: const Icon(Icons.search),
                  label: const Text('Fetch'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _statusCards(BuildContext context) {
    final theme = Theme.of(context);
    final cards = <Widget>[];
    if (_c.engineState == EngineState.preparing) {
      cards.add(_StatusCard(
        progress: _c.engineProgress,
        title: _c.engineMessage ?? 'Preparing downloader…',
        subtitle: _c.needsSetup ? _c.backendStatus?.setupNote : null,
      ));
    } else if (_c.engineState == EngineState.failed && _c.engineError != null) {
      cards.add(_StatusCard(
        error: true,
        title: "The downloader couldn't start",
        subtitle: _c.engineError,
        action: TextButton(onPressed: () => fetch(), child: const Text('Try again')),
      ));
    } else if (_c.updating) {
      cards.add(const _StatusCard(title: 'Updating yt-dlp…'));
    }
    if (_fetching && _c.engineState == EngineState.ready && !_c.updating) {
      cards.add(_StatusCard(
        title: 'Fetching…',
        subtitle: 'Asking the site what this link offers',
        action: TextButton(onPressed: _cancelFetch, child: const Text('Cancel')),
      ));
    }
    if (_error != null) {
      cards.add(Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: theme.colorScheme.errorContainer,
        child: ListTile(
          leading: Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          title: Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          subtitle: _c.ytDlpVersion == null
              ? null
              : Text(
                  'If a site stopped working, updating yt-dlp often helps '
                  '(settings).',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
        ),
      ));
    }
    return cards;
  }

  Widget _hintCard(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Download videos and audio from YouTube, Vimeo, SoundCloud, the '
            'Internet Archive and well over a thousand other sites, with yt-dlp.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Paste one link to choose the quality, or several links to download '
            'them all with your default settings.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _saveTo(context),
        ],
      ),
    );
  }

  Widget _saveTo(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.folder_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _c.outputDir.isEmpty ? 'Default download folder' : _c.outputDir,
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(onPressed: widget.onOpenSettings, child: const Text('Change')),
      ],
    );
  }

  Widget _optionsCard(BuildContext context, VideoInfo info) {
    final theme = Theme.of(context);
    final hasFfmpeg = _c.hasFfmpeg;
    final heights = info.videoHeights;
    final maxHeight = heights.isEmpty ? null : heights.first;
    final presets = VideoQuality.values
        .where((q) => q.height == null || maxHeight == null || q.height! <= maxHeight)
        .toList();
    final kind = _options.kind == DownloadKind.format
        ? ((_options.format?.isAudioOnly ?? false) ? DownloadKind.audio : DownloadKind.video)
        : _options.kind;
    final selectedCount = _selected.length;
    final estimate = _estimate(info);
    final canDownload = !_queuing && (!info.isPlaylist || selectedCount > 0);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<DownloadKind>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: DownloadKind.video,
                  icon: Icon(Icons.movie_outlined),
                  label: Text('Video'),
                ),
                ButtonSegment(
                  value: DownloadKind.audio,
                  icon: Icon(Icons.audiotrack_outlined),
                  label: Text('Audio only'),
                ),
              ],
              selected: {kind},
              onSelectionChanged: (s) => setState(() {
                _options = DownloadOptions(
                  kind: s.first,
                  quality: _options.quality,
                  audioFormat: _options.audioFormat,
                );
              }),
            ),
            const SizedBox(height: 12),
            if (_options.kind == DownloadKind.format && _options.format != null)
              InputChip(
                avatar: const Icon(Icons.tune, size: 18),
                label: Text('Format ${_options.format!.id} · ${_options.format!.shortLabel}'),
                onDeleted: () => setState(() {
                  _options = DownloadOptions(
                    kind: kind,
                    quality: _options.quality,
                    audioFormat: _options.audioFormat,
                  );
                }),
              )
            else if (kind == DownloadKind.video)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in presets)
                    ChoiceChip(
                      label: Text(q.label),
                      selected: _options.quality == q,
                      onSelected: (_) => setState(() => _options = _options.copyWith(quality: q)),
                    ),
                ],
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in AudioFormat.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: _options.audioFormat == f,
                      onSelected: f == AudioFormat.mp3 && !hasFfmpeg
                          ? null
                          : (_) => setState(() => _options = _options.copyWith(audioFormat: f)),
                    ),
                ],
              ),
            if (!info.isPlaylist && info.pickableFormats.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final f = await showFormatPicker(
                      context,
                      info: info,
                      hasFfmpeg: hasFfmpeg,
                      selected: _options.format,
                    );
                    if (f != null && mounted) {
                      setState(() => _options = DownloadOptions(
                            kind: DownloadKind.format,
                            format: f,
                            quality: _options.quality,
                            audioFormat: _options.audioFormat,
                          ));
                    }
                  },
                  icon: const Icon(Icons.tune),
                  label: const Text('Choose exact format…'),
                ),
              ),
            if (!hasFfmpeg)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'FFmpeg was not found, so only formats with video and '
                        'audio in one file can be downloaded (often lower '
                        'quality), and audio is saved as is. Install FFmpeg to '
                        'get the best quality and MP3.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (info.isLive)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'This is a live stream: it records until the stream ends or you cancel.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    estimate == null ? '' : 'About ${DownloaderText.bytes(estimate)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed: canDownload ? _download : null,
                  icon: _queuing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(info.isPlaylist
                      ? 'Download $selectedCount ${selectedCount == 1 ? 'item' : 'items'}'
                      : 'Download'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _saveTo(context),
          ],
        ),
      ),
    );
  }

  /// Rough size of the chosen download, when the site reports sizes.
  int? _estimate(VideoInfo info) {
    if (info.isPlaylist) return null;
    final formats = info.formats.where((f) => !f.isStoryboard).toList();
    VideoFormat? bestAudio;
    for (final f in formats.where((f) => f.isAudioOnly && f.filesize != null)) {
      if (bestAudio == null || (f.abr ?? f.tbr ?? 0) > (bestAudio.abr ?? bestAudio.tbr ?? 0)) {
        bestAudio = f;
      }
    }
    switch (_options.kind) {
      case DownloadKind.format:
        final f = _options.format;
        if (f?.filesize == null) return null;
        return f!.filesize! + (f.isVideoOnly && _c.hasFfmpeg ? bestAudio?.filesize ?? 0 : 0);
      case DownloadKind.audio:
        return _options.audioFormat == AudioFormat.m4a ? bestAudio?.filesize : null;
      case DownloadKind.video:
        final limit = _options.quality.height ?? 1 << 30;
        VideoFormat? best;
        for (final f in formats) {
          if (f.isAudioOnly || f.height == null || f.height! > limit || f.filesize == null) continue;
          if (!_c.hasFfmpeg && f.isVideoOnly) continue;
          if (best == null || f.height! > best.height! ||
              (f.height == best.height && f.filesize! > best.filesize!)) {
            best = f;
          }
        }
        if (best == null) return null;
        return best.filesize! + (best.isVideoOnly ? bestAudio?.filesize ?? 0 : 0);
    }
  }

  Widget _playlistHeader(BuildContext context, VideoInfo info) {
    final theme = Theme.of(context);
    final selectable = [
      for (var i = 0; i < info.entries.length; i++)
        if (!info.entries[i].isNested) i,
    ];
    final all = _selected.length == selectable.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_selected.length} of ${selectable.length} selected',
              style: theme.textTheme.titleSmall,
            ),
          ),
          TextButton(
            onPressed: selectable.isEmpty
                ? null
                : () => setState(() => _selected = all ? {} : selectable.toSet()),
            child: Text(all ? 'Select none' : 'Select all'),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(BuildContext context, PlaylistEntry entry, int i) {
    final theme = Theme.of(context);
    final subtitle = [
      if (entry.duration != null) DownloaderText.duration(entry.duration),
      ?entry.uploader,
    ].join(' · ');
    final thumb = MediaThumbnail(url: entry.thumbnail, width: 72, height: 42, radius: 6);
    if (entry.isNested) {
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: thumb,
        title: Text(entry.title ?? entry.url, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('Playlist', style: theme.textTheme.bodySmall),
        trailing: TextButton(onPressed: () => fetch(entry.url), child: const Text('Open')),
      );
    }
    final checked = _selected.contains(i);
    return CheckboxListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      value: checked,
      onChanged: (v) => setState(() {
        if (v ?? false) {
          _selected.add(i);
        } else {
          _selected.remove(i);
        }
      }),
      secondary: thumb,
      title: Text(
        '${entry.index}. ${entry.title ?? entry.url}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 1),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.title,
    this.subtitle,
    this.progress,
    this.action,
    this.error = false,
  });

  final String title;
  final String? subtitle;
  final double? progress;
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = error ? theme.colorScheme.onErrorContainer : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: error ? theme.colorScheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (error)
                  Icon(Icons.error_outline, color: fg)
                else
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                ),
                ?action,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(34, 6, 8, 0),
                child: Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
              ),
            if (!error && progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(34, 10, 8, 0),
                child: LinearProgressIndicator(value: progress),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.info});

  final VideoInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      ?info.uploader,
      if (info.isPlaylist)
        '${info.playlistCount ?? info.entries.length} items'
      else if (info.duration != null)
        DownloaderText.duration(info.duration),
      DownloaderText.site(info.extractor, info.downloadUrl),
    ].where((s) => s.isNotEmpty).join(' · ');

    final details = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (info.isPlaylist)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('PLAYLIST',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
            ),
          Text(
            info.title ?? info.url,
            style: theme.textTheme.titleMedium,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(meta, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 520) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MediaThumbnail(url: info.thumbnail, width: 240, height: 135, radius: 0),
              Expanded(child: details),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: MediaThumbnail(url: info.thumbnail, radius: 0),
            ),
            details,
          ],
        );
      }),
    );
  }
}
