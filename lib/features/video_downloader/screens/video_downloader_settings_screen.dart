import 'dart:io';

import 'package:explorer/core/services/video_downloader/downloader_settings.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../widgets/rights_notice.dart';

/// Download folder, defaults, file names, extras and yt-dlp updates.
class VideoDownloaderSettingsScreen extends StatefulWidget {
  const VideoDownloaderSettingsScreen({super.key, required this.controller});

  final VideoDownloaderController controller;

  @override
  State<VideoDownloaderSettingsScreen> createState() => _VideoDownloaderSettingsScreenState();
}

class _VideoDownloaderSettingsScreenState extends State<VideoDownloaderSettingsScreen> {
  late final _template = TextEditingController(text: _c.settings.filenameTemplate);
  late final _langs = TextEditingController(text: _c.settings.subtitleLangs);

  VideoDownloaderController get _c => widget.controller;

  DownloaderSettings get _s => _c.settings;

  void _set(DownloaderSettings s) => _c.updateSettings(s);

  @override
  void initState() {
    super.initState();
    if (_c.engineState == EngineState.ready && _c.ytDlpVersion == null) _c.refreshVersion();
  }

  @override
  void dispose() {
    _template.dispose();
    _langs.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Save downloads in',
      initialDirectory: _c.outputDir.isEmpty ? null : _c.outputDir,
    );
    if (path == null || !mounted) return;
    if (!await _c.backend.canWrite(path)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(Platform.isAndroid
            ? "Explorer can't write to that folder. Allow Explorer to manage all files, or pick another folder."
            : "Explorer can't write to that folder."),
      ));
      return;
    }
    _set(_s.copyWith(outputDir: path));
  }

  Future<void> _update() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _c.updateYtDlp();
      messenger.showSnackBar(SnackBar(
        content: Text(r.updated
            ? 'yt-dlp updated to ${r.version}'
            : 'yt-dlp is up to date (${r.version ?? 'unknown version'})'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: 'Downloader settings',
      body: ListenableBuilder(
        listenable: _c,
        builder: (context, _) => ReadableWidth(
          maxWidth: 760,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              12,
              DockedGlossyTopBar.contentTopInset(context) + 4,
              12,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              _section(context, 'Save to'),
              _card([
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(_c.outputDir.isEmpty ? 'Default folder' : _c.outputDir),
                  subtitle: Text(_s.outputDir == null ? 'Default folder' : 'Custom folder'),
                  trailing: TextButton(onPressed: _pickFolder, child: const Text('Change')),
                ),
                if (_s.outputDir != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 4),
                      child: TextButton(
                        onPressed: () => _set(_s.copyWith(resetOutputDir: true)),
                        child: const Text('Use the default folder'),
                      ),
                    ),
                  ),
                SwitchListTile(
                  title: const Text('Playlists in their own folder'),
                  subtitle: const Text('A folder named after the playlist'),
                  value: _s.playlistFolder,
                  onChanged: (v) => _set(_s.copyWith(playlistFolder: v)),
                ),
              ]),
              _section(context, 'Defaults'),
              _card([
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: SegmentedButton<DownloadKind>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: DownloadKind.video, label: Text('Video')),
                      ButtonSegment(value: DownloadKind.audio, label: Text('Audio only')),
                    ],
                    selected: {
                      _s.defaultKind == DownloadKind.audio ? DownloadKind.audio : DownloadKind.video,
                    },
                    onSelectionChanged: (v) => _set(_s.copyWith(defaultKind: v.first)),
                  ),
                ),
                _dropdown<VideoQuality>(
                  title: 'Video quality',
                  value: _s.defaultQuality,
                  items: {for (final q in VideoQuality.values) q: q.label},
                  onChanged: (v) => _set(_s.copyWith(defaultQuality: v)),
                ),
                _dropdown<AudioFormat>(
                  title: 'Audio format',
                  value: _s.audioFormat,
                  items: {for (final f in AudioFormat.values) f: f.label},
                  onChanged: (v) => _set(_s.copyWith(audioFormat: v)),
                ),
                _dropdown<VideoContainer>(
                  title: 'Video file type',
                  value: _s.container,
                  items: {for (final c in VideoContainer.values) c: c.label},
                  onChanged: (v) => _set(_s.copyWith(container: v)),
                ),
                SwitchListTile(
                  title: const Text('Prefer compatible formats'),
                  subtitle: const Text(
                      'H.264 video and AAC audio, which play on almost any device'),
                  value: _s.preferCompatible,
                  onChanged: (v) => _set(_s.copyWith(preferCompatible: v)),
                ),
              ]),
              _section(context, 'File names'),
              _card([
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: _template,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Name template',
                      border: const OutlineInputBorder(),
                      helperText: 'yt-dlp output template, e.g. %(uploader)s/%(title)s.%(ext)s',
                      helperMaxLines: 2,
                      suffixIcon: IconButton(
                        tooltip: 'Reset',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: () {
                          _template.text = DownloaderSettings.defaultFilenameTemplate;
                          _set(_s.copyWith(
                              filenameTemplate: DownloaderSettings.defaultFilenameTemplate));
                        },
                      ),
                    ),
                    onChanged: (v) => _set(_s.copyWith(filenameTemplate: v)),
                  ),
                ),
              ]),
              _section(context, 'Extras'),
              _card([
                if (!_c.hasFfmpeg)
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Needs FFmpeg'),
                    subtitle: Text(
                        'Embedding thumbnails, metadata, chapters and subtitles needs FFmpeg.'),
                  ),
                SwitchListTile(
                  title: const Text('Embed thumbnail'),
                  subtitle: const Text('As cover art'),
                  value: _s.embedThumbnail,
                  onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(embedThumbnail: v)) : null,
                ),
                SwitchListTile(
                  title: const Text('Embed metadata'),
                  subtitle: const Text('Title, artist, date and description'),
                  value: _s.embedMetadata,
                  onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(embedMetadata: v)) : null,
                ),
                SwitchListTile(
                  title: const Text('Embed chapters'),
                  value: _s.embedChapters,
                  onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(embedChapters: v)) : null,
                ),
                SwitchListTile(
                  title: const Text('Subtitles'),
                  subtitle: Text(_c.hasFfmpeg
                      ? 'Added to the video when available'
                      : 'Saved next to the video when available'),
                  value: _s.subtitles,
                  onChanged: (v) => _set(_s.copyWith(subtitles: v)),
                ),
                if (_s.subtitles) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      controller: _langs,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Languages',
                        border: OutlineInputBorder(),
                        helperText: 'Comma-separated codes; en.* is every English variant',
                      ),
                      onChanged: (v) => _set(_s.copyWith(subtitleLangs: v)),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Include automatic captions'),
                    value: _s.autoSubtitles,
                    onChanged: (v) => _set(_s.copyWith(autoSubtitles: v)),
                  ),
                ],
              ]),
              _section(context, 'yt-dlp'),
              _card(_engineTiles(context)),
              _section(context, 'About'),
              _card([
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Download responsibly'),
                  subtitle: const Text(rightsNoticeText),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Licenses'),
                  subtitle: const Text('yt-dlp, FFmpeg, Python, youtubedl-android and more'),
                  onTap: () => showLicensePage(context: context, applicationName: 'Explorer'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _engineTiles(BuildContext context) {
    final last = _c.lastUpdateCheck;
    final version = _c.ytDlpVersion;
    return [
      ListTile(
        leading: const Icon(Icons.system_update_alt),
        title: Text(version == null
            ? (_c.engineState == EngineState.ready ? 'yt-dlp' : 'yt-dlp (not set up yet)')
            : 'yt-dlp $version'),
        subtitle: Text(last == null
            ? 'Never checked for updates'
            : 'Checked ${DateFormat('d MMM y, HH:mm').format(last)}'),
        trailing: _c.updating
            ? const SizedBox.square(
                dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
            : TextButton(
                onPressed: _c.isSupported ? _update : null,
                child: const Text('Update'),
              ),
      ),
      SwitchListTile(
        title: const Text('Update automatically'),
        subtitle: const Text('Check for a new stable release once a day. Sites '
            'change often; an old yt-dlp stops working.'),
        value: _s.autoUpdate,
        onChanged: (v) => _set(_s.copyWith(autoUpdate: v)),
      ),
      ListTile(
        leading: const Icon(Icons.movie_filter_outlined),
        title: Text(_c.hasFfmpeg ? 'FFmpeg available' : 'FFmpeg not found'),
        subtitle: Text(_c.backendStatus?.ffmpegNote ?? ''),
      ),
    ];
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );

  Widget _card(List<Widget> children) => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _dropdown<T>({
    required String title,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) =>
      // A Row, not a ListTile: the menu's width depends on its longest item
      // and must shrink on narrow phones.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 5,
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final e in items.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ],
        ),
      );
}
