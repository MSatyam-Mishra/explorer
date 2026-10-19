import 'dart:async';
import 'dart:io';

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/core/services/video_downloader/ytdlp_models.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';

import '../widgets/download_panel.dart';
import '../widgets/empty_state.dart';
import '../widgets/history_list.dart';
import '../widgets/queue_list.dart';
import '../widgets/rights_notice.dart';
import 'video_downloader_settings_screen.dart';

/// Downloads videos and audio from web links with yt-dlp.
///
/// [initialUrl] (e.g. a link shared from another app) is fetched right away.
/// Downloads run outside this screen, so leaving it doesn't stop them.
class VideoDownloaderScreen extends StatefulWidget {
  const VideoDownloaderScreen({super.key, this.initialUrl});

  /// A link to fill in, e.g. one shared from another app.
  final String? initialUrl;

  @override
  State<VideoDownloaderScreen> createState() => _VideoDownloaderScreenState();
}

enum _Tab { download, queue, history }

class _VideoDownloaderScreenState extends State<VideoDownloaderScreen> {
  final _controller = VideoDownloaderController.instance;
  final _panelKey = GlobalKey<DownloadPanelState>();
  _Tab _tab = _Tab.download;

  /// Wide layout: the side pane shows the queue or the history.
  _Tab _sideTab = _Tab.queue;
  StreamSubscription<HistoryEntry>? _completed;
  Future<bool>? _rightsPrompt;

  @override
  void initState() {
    super.initState();
    _completed = _controller.completed.listen(_onCompleted);
    _init();
  }

  @override
  void dispose() {
    _completed?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    await _controller.start();
    if (!mounted || !_controller.isSupported) return;
    if (!await _ensureRights()) return;
    final url = widget.initialUrl?.trim();
    if (url != null && url.isNotEmpty) {
      await _panelKey.currentState?.fetch();
    } else if (Platform.isAndroid) {
      // Unpack Python/FFmpeg now (first use) so the first fetch is quick.
      unawaited(_controller.ensureReady().catchError((Object _) {}));
    }
  }

  /// Shows the first-use notice once; false if the user declined it.
  Future<bool> _ensureRights() async {
    if (_controller.rightsAccepted) return true;
    if (!mounted) return false;
    final accepted = await (_rightsPrompt ??= showRightsNotice(context)
        .whenComplete(() => _rightsPrompt = null));
    if (accepted) await _controller.acceptRights();
    return accepted;
  }

  void _onCompleted(HistoryEntry entry) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Downloaded “${entry.title}”', maxLines: 2, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () {
          if (mounted) FileOpener.open(context, File(entry.filePath));
        },
      ),
    ));
  }

  void _onQueued(int count, bool wide) {
    if (!mounted) return;
    if (wide) {
      setState(() => _sideTab = _Tab.queue);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(count == 1 ? 'Added to the downloads' : 'Added $count downloads'),
      action: wide
          ? null
          : SnackBarAction(label: 'View', onPressed: () => setState(() => _tab = _Tab.queue)),
    ));
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoDownloaderSettingsScreen(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: 'Video downloader',
      trailing: _controller.isSupported
          ? ExplorerTopBar.iconButton(
              context: context,
              icon: Icon(Icons.settings_outlined, color: ClearGlassForeground.icon(context)),
              tooltip: 'Downloader settings',
              onPressed: _openSettings,
            )
          : null,
      body: LayoutBuilder(builder: (context, constraints) {
        final top = DockedGlossyTopBar.contentTopInset(context);
        final bottom = MediaQuery.paddingOf(context).bottom;
        if (!_controller.isSupported) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: EmptyState(
              icon: Icons.block,
              title: 'Not available on this device',
              message: _controller.unsupportedReason,
            ),
          );
        }
        final wide = constraints.maxWidth >= 840;
        final panel = DownloadPanel(
          key: _panelKey,
          controller: _controller,
          initialUrl: widget.initialUrl,
          onQueued: (n) => _onQueued(n, wide),
          onOpenSettings: _openSettings,
          ensureRights: _ensureRights,
          padding: EdgeInsets.fromLTRB(12, wide ? 12 : 4, 12, bottom),
        );
        final listPadding = EdgeInsets.fromLTRB(12, 4, 12, 24 + bottom);

        if (wide) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 11, child: panel),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 9,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: _tabs(
                          [_Tab.queue, _Tab.history],
                          _sideTab,
                          (t) => setState(() => _sideTab = t),
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _sideTab == _Tab.queue ? 0 : 1,
                          children: [
                            QueueList(controller: _controller, padding: listPadding),
                            HistoryList(controller: _controller, padding: listPadding),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.only(top: top),
          child: ReadableWidth(
            maxWidth: 760,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: _tabs(_Tab.values, _tab, (t) => setState(() => _tab = t)),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _tab.index,
                    children: [
                      panel,
                      QueueList(controller: _controller, padding: listPadding),
                      HistoryList(controller: _controller, padding: listPadding),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _tabs(List<_Tab> tabs, _Tab selected, ValueChanged<_Tab> onChanged) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final active = _controller.activeCount;
        // Labels alone on narrow phones, so three segments fit.
        final icons = MediaQuery.sizeOf(context).width >= 480;
        return SizedBox(
          width: double.infinity,
          child: SegmentedButton<_Tab>(
            showSelectedIcon: false,
            segments: [
              for (final t in tabs)
                ButtonSegment(
                  value: t,
                  label: Text(switch (t) {
                    _Tab.download => 'New',
                    _Tab.queue => active == 0 ? 'Downloads' : 'Downloads ($active)',
                    _Tab.history => 'History',
                  }),
                  icon: icons
                      ? Icon(switch (t) {
                          _Tab.download => Icons.add_link,
                          _Tab.queue => Icons.downloading,
                          _Tab.history => Icons.history,
                        })
                      : null,
                ),
            ],
            selected: {selected},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        );
      },
    );
  }
}
