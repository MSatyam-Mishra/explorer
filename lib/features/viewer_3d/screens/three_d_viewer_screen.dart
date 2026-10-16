import 'dart:async';
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
/// The bundled viewer (`assets/viewer3d`) and the model's folder (or, for a
/// model in a project subfolder, that folder's parent, see [_servedRootFor])
/// are served by [LocalContentServer], so external resources referenced by
/// the model (glTF `.bin` buffers, OBJ `.mtl` libraries, textures, also in
/// sibling folders like `../Textures`) load with their relative paths.
///
/// Opening is parallel: the WebView is created on the first frame while the
/// server mounts the folders, the page starts downloading the model before
/// its scripts load, and the folder index used for fuzzy texture lookups is
/// built meanwhile and only awaited right before parsing.
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
  static const _indexTimeLimit = Duration(milliseconds: 1500);

  /// Share of the index left for the parent folder's other files.
  static const _siblingMaxEntries = 1000;
  static const _siblingMaxDepth = 2;

  /// Formats whose files can name other files (buffers, materials, textures),
  /// so the page needs the folder index. Self-contained formats (glb, stl,
  /// ply, zip-based ones...) skip it.
  static const _formatsWithExternalFiles = {
    'gltf', 'obj', 'fbx', 'dae', '3ds', 'wrl', 'vrml', 'lwo', 'md2', 'usda',
    'usd',
  };

  /// The bundled viewer is mounted once per run and kept, so every viewer
  /// uses the same URLs for the three.js scripts.
  static Future<Uri>? _assetsMount;

  final LocalContentServer _server = LocalContentServer.instance;
  late final ThreeDViewerController _viewer;

  Uri? _modelMount;
  Uri? _filesMount;
  WebUri? _pageUrl;
  double _pageInset = 0;
  int? _fileSize;
  bool _started = false;

  /// Keeps the WebView's element (and the native view) when the layout
  /// around it changes; replaced only by [_reload].
  GlobalKey _webViewKey = GlobalKey(debugLabel: 'viewer3d');
  Widget? _webView;
  InAppWebViewController? _web;
  InAppWebViewController? _loadedBy;

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
    // Created on the first frame: starting the browser engine is the slowest
    // step, so it runs while the server mounts the folders.
    _webView = _buildWebView();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _prepare();
    }
  }

  @override
  void dispose() {
    _screenshotTimeout?.cancel();
    _web = null;
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
      final modelDir = Directory(p.normalize(p.absolute(file.parent.path)));
      final served = _servedRootFor(modelDir);
      final widened = !p.equals(served.path, modelDir.path);

      // Everything starts at once; only the stat and the mounts gate the
      // page. The index is served to the page when ready (it waits for it
      // only right before parsing).
      final statFuture = file.stat();
      final assetsFuture = _viewerAssets(_server);
      final modelFuture = _server.mountDirectory(served.path);
      Future<Uri>? filesFuture;
      if (_formatsWithExternalFiles.contains(_extension)) {
        final index = _indexFolder(
          modelDir,
          widened ? served : null,
        ).catchError((Object _) => const <String>[]);
        filesFuture = _server.mount(
          (path) async => path == 'files.json'
              ? Uint8List.fromList(utf8.encode(jsonEncode(await index)))
              : null,
        );
      }
      _modelMount = await modelFuture;
      _filesMount = await filesFuture;
      final assets = await assetsFuture;
      final stat = await statFuture;
      if (!mounted) {
        _unmount();
        return;
      }
      if (stat.type == FileSystemEntityType.notFound) {
        _viewer.fail('This file no longer exists.');
        return;
      }
      _fileSize = stat.size;

      final folder = widened
          ? '${Uri.encodeComponent(p.basename(modelDir.path))}/'
          : '';
      final src = _modelMount!.resolve(
        '$folder${Uri.encodeComponent(_fileName)}',
      );
      final page = assets.replace(
        path: '${assets.path}index.html',
        queryParameters: {
          'src': src.toString(),
          'ext': _extension,
          'name': _fileName,
          'size': '${_fileSize ?? 0}',
          'bg': background.id,
          'inset': topInset.toStringAsFixed(1),
          if (_filesMount != null)
            'files': _filesMount!.resolve('files.json').toString(),
        },
      );
      _pageUrl = WebUri.uri(page);
      _pageInset = topInset;
      _loadPage();
    } catch (e, st) {
      debugPrint('3D viewer: setup failed: $e\n$st');
      _unmount();
      if (!mounted) return;
      _viewer.fail(
        "Couldn't start the 3D viewer.",
        detail: '$e',
        code: 'page_load',
      );
    }
  }

  static Future<Uri> _viewerAssets(LocalContentServer server) async {
    try {
      return await (_assetsMount ??= server.mountAssets(_assetPrefix));
    } catch (_) {
      _assetsMount = null;
      rethrow;
    }
  }

  /// Points the current WebView at the viewer page once both exist.
  void _loadPage() {
    final web = _web;
    final url = _pageUrl;
    if (web == null || url == null || identical(_loadedBy, web)) return;
    if (_viewer.phase == ViewerPhase.error) return;
    _loadedBy = web;
    _viewer.initialTopInset(_pageInset);
    web.loadUrl(urlRequest: URLRequest(url: url)).catchError((Object e) {
      if (mounted) {
        _viewer.fail(
          "Couldn't load the 3D viewer.",
          detail: '$e',
          code: 'page_load',
        );
      }
    });
  }

  void _unmount() {
    final model = _modelMount;
    final files = _filesMount;
    _modelMount = null;
    _filesMount = null;
    if (model != null) _server.unmount(model);
    if (files != null) _server.unmount(files);
  }

  /// Folder served to the page: the model's parent, so references into
  /// sibling folders (`../Textures/wood.png`, common in asset packs laid out
  /// as Models/ + Textures/) load. It stays at the model's own folder when
  /// that parent is a broad location (a storage, drive or filesystem root,
  /// the home or temp folder), so a model in Downloads doesn't expose or
  /// index the rest of the user's storage. Never more than one level up.
  static Directory _servedRootFor(Directory modelDir) {
    final dir = modelDir.path;
    final parent = p.dirname(dir);
    if (parent == dir || _isBroadFolder(parent)) return modelDir;
    return Directory(parent);
  }

  static bool _isBroadFolder(String path) {
    if (p.dirname(path) == path) return true;
    bool same(String? other) =>
        other != null &&
        other.isNotEmpty &&
        p.equals(p.normalize(p.absolute(other)), path);
    if (same(Platform.environment['HOME']) ||
        same(Platform.environment['USERPROFILE']) ||
        same(Directory.systemTemp.path)) {
      return true;
    }
    // Android volumes: /storage, /storage/emulated/0, /storage/1A2B-3C4D,
    // /mnt/media_rw/1A2B-3C4D, /sdcard.
    final parts = p.split(path);
    if (parts.length < 2 || parts.first != '/') return false;
    switch (parts[1]) {
      case 'storage':
        final volumeDepth = parts.length > 2 && parts[2] == 'emulated' ? 4 : 3;
        return parts.length <= volumeDepth;
      case 'mnt':
        return parts.length <= 4;
      case 'sdcard':
        return parts.length <= 2;
    }
    return false;
  }

  /// Paths relative to the model's folder (with `/`) of files near it,
  /// breadth first: the model's folder, then (when [parent] is served) the
  /// parent's other files and folders as `../Textures/a.png`.
  static Future<List<String>> _indexFolder(
    Directory modelDir,
    Directory? parent,
  ) async {
    final out = <String>[];
    final watch = Stopwatch()..start();

    Future<void> walk(Directory root, int maxDepth, int maxEntries) async {
      final limit = out.length + maxEntries;
      final queue = <(Directory, int)>[(root, 0)];
      bool full() =>
          out.length >= limit ||
          out.length >= _indexMaxEntries ||
          watch.elapsed >= _indexTimeLimit;
      while (queue.isNotEmpty && !full()) {
        final (dir, depth) = queue.removeAt(0);
        try {
          await for (final entity in dir.list(followLinks: false)) {
            final name = p.basename(entity.path);
            if (name.startsWith('.')) continue;
            if (entity is File) {
              out.add(
                p
                    .relative(entity.path, from: modelDir.path)
                    .replaceAll(r'\', '/'),
              );
              if (full()) break;
            } else if (entity is Directory &&
                depth < maxDepth &&
                !p.equals(entity.path, modelDir.path)) {
              queue.add((entity, depth + 1));
            }
          }
        } catch (_) {
          // Unreadable folder: skip it.
        }
      }
    }

    await walk(modelDir, _indexMaxDepth, _indexMaxEntries);
    if (parent != null) {
      await walk(parent, _siblingMaxDepth, _siblingMaxEntries);
    }
    return out;
  }

  void _reload() {
    _viewer.resetForReload();
    _web = null;
    setState(() {
      _webViewKey = GlobalKey(debugLabel: 'viewer3d');
      _webView = _buildWebView();
    });
    if (_pageUrl == null) _prepare();
  }

  Widget _buildWebView() {
    // No initial URL: the page is loaded by [_loadPage] once the server is
    // ready, which is usually before the native view finishes starting.
    return InAppWebView(
      key: _webViewKey,
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
        _web = controller;
        _loadPage();
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

  /// The canvas is always the first child of the same Row, whether or not
  /// the details pane is docked: moving the WebView to another place in the
  /// tree destroys the native view and reloads the model.
  Widget _buildBody(BuildContext context, bool split) {
    final canvas = _buildCanvasArea(context);
    final showPanel = split && _showDockedPanel;
    final fold = FoldInfo.of(context);
    final hinge = fold != null && fold.isVertical ? fold.bounds : null;
    final panel = !showPanel
        ? null
        : ClearGlassPanel(
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
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: canvas),
        if (panel != null && hinge != null) ...[
          // Book posture: canvas left of the hinge, pane right of it.
          SizedBox(width: hinge.width),
          SizedBox(
            width: MediaQuery.sizeOf(context).width - hinge.right,
            child: panel,
          ),
        ] else if (panel != null)
          SizedBox(width: 320, child: panel),
      ],
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
