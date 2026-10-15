import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:explorer/core/services/local_content_server.dart';
import 'package:explorer/features/viewer_3d/models/viewer_3d_models.dart';
import 'package:explorer/features/viewer_3d/services/three_d_viewer_controller.dart';
import 'package:explorer/features/viewer_3d/widgets/model_info_panel.dart';
import 'package:explorer/features/viewer_3d/widgets/viewer_status_views.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// Offline 3D model viewer built on three.js running in a WebView.
///
/// The bundled viewer (`assets/viewer3d`) and the model's folder are served
/// by [LocalContentServer], so external resources referenced by the model
/// (glTF `.bin` buffers, OBJ `.mtl` libraries, textures) load with their
/// relative paths.
///
/// Pops with `true` when a screenshot was saved next to the model, so the
/// caller can refresh its file listing.
class ThreeDViewerScreen extends StatefulWidget {
  const ThreeDViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<ThreeDViewerScreen> createState() => _ThreeDViewerScreenState();
}

class _ThreeDViewerScreenState extends State<ThreeDViewerScreen> {
  static const _assetPrefix = 'assets/viewer3d';

  /// Width at which the info pane docks beside the canvas.
  static const _splitWidth = 840.0;

  /// Limits for indexing the model's folder (used to resolve textures whose
  /// references have the wrong case or absolute author paths).
  static const _indexMaxEntries = 4000;
  static const _indexMaxDepth = 3;

  final LocalContentServer _server = LocalContentServer.instance;
  late final ThreeDViewerController _viewer;

  Uri? _assetsMount;
  Uri? _modelMount;
  WebUri? _pageUrl;
  List<String> _folderIndex = const [];
  int? _fileSize;
  int _reloadToken = 0;
  Widget? _webView;

  bool _showDockedPanel = true;
  bool _screenshotSaved = false;
  Timer? _screenshotTimeout;

  String get _fileName => p.basename(widget.file.path);

  String get _extension {
    final ext = p.extension(widget.file.path).toLowerCase();
    return ext.startsWith('.') ? ext.substring(1) : ext;
  }

  @override
  void initState() {
    super.initState();
    _viewer = ThreeDViewerController()
      ..onScreenshot = _onScreenshot
      ..onLoaded = _onModelLoaded;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _screenshotTimeout?.cancel();
    _unmount();
    _viewer.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  Future<void> _prepare() async {
    if (!mounted) return;
    final background = Theme.of(context).brightness == Brightness.light
        ? ViewerBackground.light
        : ViewerBackground.dark;
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    try {
      final file = widget.file;
      if (!await file.exists()) {
        if (mounted) _viewer.fail('This file no longer exists.');
        return;
      }
      _fileSize = await file.length();

      final assetsFuture = _server.mountAssets(_assetPrefix);
      final modelFuture = _server.mountDirectory(file.parent.path);
      final indexFuture = _indexFolder(file.parent);
      _assetsMount = await assetsFuture;
      _modelMount = await modelFuture;
      final index = await indexFuture;
      if (!mounted) {
        _unmount();
        return;
      }

      final src = _modelMount!.resolve(Uri.encodeComponent(_fileName));
      final page = _assetsMount!.replace(
        path: '${_assetsMount!.path}index.html',
        queryParameters: {
          'src': src.toString(),
          'ext': _extension,
          'name': _fileName,
          'size': '${_fileSize ?? 0}',
          'bg': background.id,
          'inset': topInset.toStringAsFixed(1),
        },
      );
      _viewer.initialTopInset(topInset);
      setState(() {
        _folderIndex = index;
        _pageUrl = WebUri.uri(page);
        _webView = _buildWebView();
      });
    } catch (e, st) {
      debugPrint('3D viewer: setup failed: $e\n$st');
      if (!mounted) {
        _unmount();
        return;
      }
      _viewer.fail(
        "Couldn't start the 3D viewer.",
        detail: '$e',
        code: 'page_load',
      );
    }
  }

  void _unmount() {
    final assets = _assetsMount;
    final model = _modelMount;
    _assetsMount = null;
    _modelMount = null;
    if (assets != null) _server.unmount(assets);
    if (model != null) _server.unmount(model);
  }

  /// Relative paths (with `/`) of files near the model, breadth first.
  static Future<List<String>> _indexFolder(Directory root) async {
    final out = <String>[];
    final queue = <(Directory, int)>[(root, 0)];
    final watch = Stopwatch()..start();
    while (queue.isNotEmpty &&
        out.length < _indexMaxEntries &&
        watch.elapsedMilliseconds < 1500) {
      final (dir, depth) = queue.removeAt(0);
      try {
        await for (final entity in dir.list(followLinks: false)) {
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;
          if (entity is File) {
            out.add(p.relative(entity.path, from: root.path).replaceAll(r'\', '/'));
            if (out.length >= _indexMaxEntries) break;
          } else if (entity is Directory && depth < _indexMaxDepth) {
            queue.add((entity, depth + 1));
          }
        }
      } catch (_) {
        // Unreadable folder: skip it.
      }
    }
    return out;
  }

  void _reload() {
    if (_pageUrl == null) {
      _viewer.resetForReload();
      _prepare();
      return;
    }
    _viewer.resetForReload();
    setState(() {
      _reloadToken++;
      _webView = _buildWebView();
    });
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: ValueKey('viewer3d-$_reloadToken'),
      initialUrlRequest: URLRequest(url: _pageUrl),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: 'window.__viewer3dFiles = ${jsonEncode(_folderIndex)};',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        hardwareAcceleration: true,
        supportZoom: false,
        builtInZoomControls: false,
        displayZoomControls: false,
        disableContextMenu: true,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        overScrollMode: OverScrollMode.NEVER,
        disallowOverScroll: true,
        allowsLinkPreview: false,
        isInspectable: kDebugMode,
      ),
      // Let the canvas own every touch (rotate / pinch / pan).
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: ThreeDViewerController.handlerName,
          callback: (args) {
            _viewer.handleMessage(args.isEmpty ? null : args.first);
            return null;
          },
        );
        _viewer.attach(controller);
      },
      onReceivedError: (controller, request, error) {
        if (!_isMainFrame(request)) return;
        _viewer.fail(
          "Couldn't load the 3D viewer.",
          detail: error.description,
          code: 'page_load',
        );
      },
      onReceivedHttpError: (controller, request, response) {
        if (!_isMainFrame(request)) return;
        _viewer.fail(
          "Couldn't load the 3D viewer.",
          detail: 'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}',
          code: 'page_load',
        );
      },
      onRenderProcessGone: (controller, detail) => _onRendererGone(),
      onWebContentProcessDidTerminate: (controller) => _onRendererGone(),
      onConsoleMessage: kDebugMode
          ? (controller, message) => debugPrint('3D viewer console: ${message.message}')
          : null,
    );
  }

  bool _isMainFrame(WebResourceRequest request) {
    if (request.isForMainFrame != null) return request.isForMainFrame!;
    return request.url.path.endsWith('/index.html');
  }

  void _onRendererGone() {
    _viewer.detach();
    _viewer.fail(
      'The 3D view stopped unexpectedly. The model may be too large for this '
      "device's memory.",
      code: 'render_process_gone',
    );
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onModelLoaded() {
    if (!mounted || _viewer.warnings.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _viewer.warnings.length == 1
              ? _viewer.warnings.first
              : 'Some parts of the model could not be loaded.',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        action: SnackBarAction(label: 'Details', onPressed: _showInfo),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _takeScreenshot() {
    if (!_viewer.isReady || _screenshotTimeout != null) return;
    _screenshotTimeout = Timer(const Duration(seconds: 15), () {
      _screenshotTimeout = null;
      _snack("Couldn't capture a screenshot.");
    });
    _viewer.requestScreenshot();
  }

  Future<void> _onScreenshot(String? dataUrl, String? error) async {
    _screenshotTimeout?.cancel();
    _screenshotTimeout = null;
    if (!mounted) return;
    if (dataUrl == null || !dataUrl.startsWith('data:image/png;base64,')) {
      _snack("Couldn't capture a screenshot${error == null ? '' : ': $error'}");
      return;
    }
    try {
      final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
      final target = await _screenshotTarget();
      await target.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      _screenshotSaved = true;
      _snack('Screenshot saved as ${p.basename(target.path)}');
    } catch (e) {
      if (!mounted) return;
      _snack("Couldn't save the screenshot: $e");
    }
  }

  Future<File> _screenshotTarget() async {
    final dir = widget.file.parent.path;
    final stem = p.basenameWithoutExtension(widget.file.path);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var candidate = File(p.join(dir, '${stem}_$stamp.png'));
    var n = 2;
    while (await candidate.exists()) {
      candidate = File(p.join(dir, '${stem}_${stamp}_$n.png'));
      n++;
    }
    return candidate;
  }

  Future<void> _openWithAnotherApp() async {
    try {
      final result = await OpenFilex.open(widget.file.path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        _snack(result.type == ResultType.noAppToOpen
            ? 'No other app can open this file.'
            : "Couldn't open the file: ${result.message}");
      }
    } catch (e) {
      if (mounted) _snack("Couldn't open the file: $e");
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isSplit(BuildContext context) =>
      AdaptiveSplitView.isSplit(context, minWidthForSplit: _splitWidth);

  void _showInfo() {
    if (!mounted) return;
    if (_isSplit(context)) {
      setState(() => _showDockedPanel = true);
      return;
    }
    ExplorerLiquidGlassBottomSheet.show<void>(
      context,
      maxHeightFraction: 0.72,
      child: ModelInfoPanel(
        controller: _viewer,
        fileName: _fileName,
        fileSize: _fileSize,
        scrollable: false,
        onScreenshot: () {
          Navigator.of(context).maybePop();
          _takeScreenshot();
        },
      ),
    );
  }

  void _toggleInfo() {
    if (_isSplit(context)) {
      setState(() => _showDockedPanel = !_showDockedPanel);
    } else {
      _showInfo();
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_screenshotSaved);
      },
      child: ListenableBuilder(
        listenable: _viewer,
        builder: (context, _) {
          final split = _isSplit(context);
          return ExplorerScaffold(
            title: _fileName,
            trailing: _buildActions(context, split),
            body: _buildBody(context, split),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool split) {
    final canvas = _buildCanvasArea(context);
    if (!split || !_showDockedPanel) return canvas;
    return AdaptiveSplitView(
      minWidthForSplit: _splitWidth,
      secondaryOnLeading: false,
      secondaryWidth: 320,
      divider: false,
      primary: canvas,
      secondary: ClearGlassPanel(
        borderRadius: 24,
        margin: EdgeInsets.fromLTRB(
          0,
          DockedGlossyTopBar.contentTopInset(context),
          12,
          12 + MediaQuery.paddingOf(context).bottom,
        ),
        child: ModelInfoPanel(
          controller: _viewer,
          fileName: _fileName,
          fileSize: _fileSize,
          onScreenshot: _takeScreenshot,
          onClose: () => setState(() => _showDockedPanel = false),
        ),
      ),
    );
  }

  Widget _buildCanvasArea(BuildContext context) {
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final phase = _viewer.phase;
    final webView = _webView;
    // Keeps framing right after rotation / window resizes (no-op otherwise).
    _viewer.updateTopInset(topInset);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Full-bleed canvas (it may sit behind the floating top bar).
        if (webView != null && phase != ViewerPhase.error) webView,
        if (phase == ViewerPhase.preparing || phase == ViewerPhase.loading)
          Padding(
            padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
            child: Center(
              child: ViewerProgressCard(
                label: _viewer.progressLabel,
                progress: _viewer.progress,
              ),
            ),
          ),
        if (phase == ViewerPhase.error)
          Padding(
            padding: EdgeInsets.fromLTRB(20, topInset + 8, 20, bottomInset + 20),
            child: ViewerErrorView(
              message: _viewer.errorMessage ?? 'The model could not be displayed.',
              detail: _viewer.errorDetail,
              onOpenWith: _openWithAnotherApp,
              onRetry: _viewer.canRetry ? _reload : null,
            ),
          ),
        if (phase == ViewerPhase.ready && _viewer.clips.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomInset + 16,
            child: Center(child: _AnimationBar(controller: _viewer)),
          ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, bool split) {
    final fg = ClearGlassForeground.icon(context);
    final active = Theme.of(context).colorScheme.primary;
    final ready = _viewer.isReady;
    final iconColor = ready ? fg : fg.withValues(alpha: 0.4);

    Widget toggle({
      required IconData icon,
      required String tooltip,
      required bool value,
      required ValueChanged<bool> onChanged,
    }) {
      return ExplorerTopBar.iconButton(
        context: context,
        icon: Icon(icon, color: ready && value ? active : iconColor),
        tooltip: tooltip,
        onPressed: ready ? () => onChanged(!value) : null,
      );
    }

    final reset = ExplorerTopBar.iconButton(
      context: context,
      icon: Icon(Icons.center_focus_strong_outlined, color: iconColor),
      tooltip: 'Reset view',
      onPressed: ready ? _viewer.resetView : null,
    );
    final autoRotate = toggle(
      icon: Icons.threesixty,
      tooltip: 'Auto-rotate',
      value: _viewer.autoRotate,
      onChanged: _viewer.setAutoRotate,
    );
    final info = ExplorerTopBar.iconButton(
      context: context,
      icon: Icon(
        Icons.info_outline,
        color: split && _showDockedPanel ? active : fg,
      ),
      tooltip: 'Details & controls',
      onPressed: _toggleInfo,
    );

    if (!split) {
      return ExplorerTopBar.actions(context, [
        reset,
        autoRotate,
        info,
        _MoreMenu(
          controller: _viewer,
          color: iconColor,
          enabled: ready,
          onScreenshot: _takeScreenshot,
          onOpenWith: _openWithAnotherApp,
        ),
      ]);
    }

    return ExplorerTopBar.actions(context, [
      reset,
      autoRotate,
      if (_viewer.hasMeshes)
        toggle(
          icon: Icons.change_history,
          tooltip: 'Wireframe',
          value: _viewer.wireframe,
          onChanged: _viewer.setWireframe,
        ),
      toggle(
        icon: Icons.grid_4x4,
        tooltip: 'Ground grid',
        value: _viewer.grid,
        onChanged: _viewer.setGrid,
      ),
      if (ready && _viewer.clips.isNotEmpty)
        _AnimationMenu(controller: _viewer, color: fg),
      ExplorerTopBar.iconButton(
        context: context,
        icon: Icon(Icons.photo_camera_outlined, color: iconColor),
        tooltip: 'Screenshot',
        onPressed: ready ? _takeScreenshot : null,
      ),
      info,
    ]);
  }
}

/// Overflow menu for phones: less common toggles and actions.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.controller,
    required this.color,
    required this.enabled,
    required this.onScreenshot,
    required this.onOpenWith,
  });

  final ThreeDViewerController controller;
  final Color color;
  final bool enabled;
  final VoidCallback onScreenshot;
  final VoidCallback onOpenWith;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_vert, color: color),
      onSelected: (value) {
        switch (value) {
          case 'wireframe':
            controller.setWireframe(!controller.wireframe);
          case 'grid':
            controller.setGrid(!controller.grid);
          case 'axes':
            controller.setAxes(!controller.axes);
          case 'animations':
            _showAnimationSheet(context, controller);
          case 'screenshot':
            onScreenshot();
          case 'open':
            onOpenWith();
        }
      },
      itemBuilder: (context) => [
        if (enabled && controller.hasMeshes)
          CheckedPopupMenuItem(
            value: 'wireframe',
            checked: controller.wireframe,
            child: const Text('Wireframe'),
          ),
        if (enabled)
          CheckedPopupMenuItem(
            value: 'grid',
            checked: controller.grid,
            child: const Text('Ground grid'),
          ),
        if (enabled)
          CheckedPopupMenuItem(
            value: 'axes',
            checked: controller.axes,
            child: const Text('Axes'),
          ),
        if (enabled && controller.clips.isNotEmpty)
          const PopupMenuItem(
            value: 'animations',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.animation),
              title: Text('Animations…'),
            ),
          ),
        if (enabled) const PopupMenuDivider(),
        if (enabled)
          const PopupMenuItem(
            value: 'screenshot',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.photo_camera_outlined),
              title: Text('Save screenshot'),
            ),
          ),
        const PopupMenuItem(
          value: 'open',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.open_in_new),
            title: Text('Open with another app'),
          ),
        ),
      ],
    );
  }
}

void _showAnimationSheet(BuildContext context, ThreeDViewerController controller) {
  ExplorerLiquidGlassBottomSheet.show<void>(
    context,
    maxHeightFraction: 0.5,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final fg = ClearGlassForeground.icon(context);
        final primary = Theme.of(context).colorScheme.primary;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Animations', style: ClearGlassForeground.title(context)),
            const SizedBox(height: 8),
            for (final entry in _clipEntries(controller))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  controller.animationIndex == entry.$1 && controller.animationPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_outline,
                  color: controller.animationIndex == entry.$1 ? primary : fg,
                ),
                title: Text(entry.$2, style: TextStyle(color: fg)),
                onTap: () => controller.animationIndex == entry.$1
                    ? controller.toggleAnimation()
                    : controller.playAnimation(entry.$1),
              ),
            if (controller.animationIndex != -2)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.stopAnimation,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// (index, label) pairs for the clip pickers; -1 plays all clips together.
List<(int, String)> _clipEntries(ThreeDViewerController controller) => [
      for (final clip in controller.clips)
        (clip.index, '${clip.name}  ·  ${clip.duration.toStringAsFixed(1)} s'),
      if (controller.clips.length > 1) (-1, 'Play all together'),
    ];

/// Top-bar animation picker (wide screens).
class _AnimationMenu extends StatelessWidget {
  const _AnimationMenu({required this.controller, required this.color});

  final ThreeDViewerController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Animations',
      icon: Icon(Icons.animation, color: color),
      onSelected: (value) {
        if (value == -3) {
          controller.stopAnimation();
        } else {
          controller.playAnimation(value);
        }
      },
      itemBuilder: (context) => [
        for (final entry in _clipEntries(controller))
          CheckedPopupMenuItem(
            value: entry.$1,
            checked: controller.animationIndex == entry.$1,
            child: Text(entry.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        if (controller.animationIndex != -2) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: -3, child: Text('Stop')),
        ],
      ],
    );
  }
}

/// Floating play/pause pill with the current clip name.
class _AnimationBar extends StatelessWidget {
  const _AnimationBar({required this.controller});

  final ThreeDViewerController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clips = controller.clips;
    final index = controller.animationIndex;
    final name = index == -1
        ? 'All animations'
        : index >= 0 && index < clips.length
            ? clips[index].name
            : 'Animations';
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
      elevation: 4,
      shadowColor: Colors.black38,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: controller.animationPlaying ? 'Pause' : 'Play',
              icon: Icon(
                controller.animationPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: scheme.primary,
              ),
              onPressed: controller.toggleAnimation,
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: PopupMenuButton<int>(
                tooltip: 'Choose animation',
                onSelected: controller.playAnimation,
                itemBuilder: (context) => [
                  for (final entry in _clipEntries(controller))
                    CheckedPopupMenuItem(
                      value: entry.$1,
                      checked: controller.animationIndex == entry.$1,
                      child: Text(entry.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(Icons.arrow_drop_down, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
