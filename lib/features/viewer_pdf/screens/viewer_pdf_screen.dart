import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/services/bookmark_service.dart';
import 'package:explorer/features/viewer_office/common/viewer_ui.dart';
import 'package:explorer/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:explorer/features/viewer_pdf/screens/pdf_page_canvas_screen.dart';
import 'package:explorer/features/viewer_pdf/services/pdf_document_ops.dart';
import 'package:explorer/features/viewer_pdf/services/pdf_page_rasterizer.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_annotation_toolbar.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_dialogs.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_page_manager.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_search_bar.dart';
import 'package:explorer/features/viewer_pdf/widgets/pdf_side_panel.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
// SfPdfViewer's theme lives in syncfusion_flutter_core, which the viewer
// package depends on but doesn't re-export.
// ignore: depend_on_referenced_packages
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart'
    show PdfDocument, PdfPageRotateAngle, TextSearchOption;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// PDF viewer and editor: reading, search, outline, bookmarks, annotations,
/// form filling, drawing/stamps and page organisation.
class PdfViewerScreen extends StatefulWidget {
  final File pdfFile;

  const PdfViewerScreen({super.key, required this.pdfFile});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

enum _LoadState { loading, locked, error, ready }

enum _MenuAction {
  save,
  saveCopy,
  share,
  goToPage,
  toggleBookmark,
  pages,
  insertPdf,
  layout,
  nightMode,
  zoomIn,
  zoomOut,
  setPassword,
  removePassword,
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  static const _prefNightMode = 'pdf_viewer.night_mode';
  static const _prefSinglePage = 'pdf_viewer.single_page';
  static const _historyLimit = 10;
  static const _historyByteBudget = 160 * 1024 * 1024;

  /// "Smart invert": flips lightness but keeps hues recognisable.
  static const _nightMatrix = <double>[
    0.574, -1.430, -0.144, 0, 255, //
    -0.426, -0.430, -0.144, 0, 255, //
    -0.426, -1.430, 0.856, 0, 255, //
    0, 0, 0, 1, 0,
  ];
  static const _identityMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  final BookmarkService _bookmarkService = BookmarkService();
  final UndoHistoryController _undoController = UndoHistoryController();
  final GlobalKey _bodyKey = GlobalKey();
  final ValueNotifier<int> _currentPage = ValueNotifier(1);
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // Document state.
  late File _file = widget.pdfFile;
  _LoadState _loadState = _LoadState.loading;
  String? _errorMessage;
  Uint8List? _sourceBytes;

  /// Bytes the viewer was created from; only changes when it is reloaded.
  Uint8List? _viewerBytes;

  /// Latest known document bytes, without unsaved viewer annotations.
  Uint8List? _latestBytes;
  String? _password;
  bool _unlocking = false;
  PdfViewerController _controller = PdfViewerController();
  GlobalKey<SfPdfViewerState> _viewerKey = GlobalKey();
  int _docVersion = 0;
  int _initialPage = 1;
  bool _viewerReady = false;
  int _pageCount = 0;
  PdfDocument? _viewerDocument;
  List<PdfOutlineNode>? _outline;

  /// Annotation or form edits inside the viewer not yet in [_latestBytes].
  bool _viewerHasChanges = false;
  bool _dirty = false;
  bool _folderChanged = false;
  String? _busyLabel;
  final List<Uint8List> _history = [];
  final List<Uint8List> _redoHistory = [];

  // Page manager data.
  List<PdfPageMeta>? _pageMetas;
  PdfPageRasterizer? _rasterizer;
  bool _pageDataLoading = false;
  int _pageDataFailedVersion = -1;

  // UI state.
  List<Bookmark> _bookmarks = [];
  bool _editMode = false;
  bool _nightMode = false;
  bool _singlePage = false;
  bool? _panelOpen;
  int _panelTab = 0;
  bool _searchOpen = false;
  bool _searching = false;
  bool _matchCase = false;
  bool _wholeWords = false;
  PdfTextSearchResult? _searchResult;
  PdfAnnotationMode _annotationMode = PdfAnnotationMode.none;
  Annotation? _selectedAnnotation;
  Color _canvasColor = const Color(0xFFF44336);
  final Map<PdfAnnotationMode, Color> _markupColors = {
    PdfAnnotationMode.highlight: const Color(0xFFFFEB3B),
    PdfAnnotationMode.underline: const Color(0xFF4CAF50),
    PdfAnnotationMode.strikethrough: const Color(0xFFF44336),
    PdfAnnotationMode.squiggly: const Color(0xFFFF9800),
    PdfAnnotationMode.stickyNote: const Color(0xFFFFEB3B),
  };
  Timer? _lastReadTimer;

  bool get _busy => _busyLabel != null;
  String get _bookmarkKey => widget.pdfFile.path;
  String get _fileName => p.basename(_file.path);

  @override
  void initState() {
    super.initState();
    _undoController.addListener(_onUndoChanged);
    _configureController(_controller);
    _loadPreferences();
    _loadBookmarks();
    _open();
  }

  @override
  void dispose() {
    _lastReadTimer?.cancel();
    if (_viewerReady) {
      _bookmarkService.saveLastReadPosition(
        _bookmarkKey,
        _currentPage.value - 1,
      );
    }
    _undoController.removeListener(_onUndoChanged);
    _rasterizer?.close();
    _searchText.dispose();
    _searchFocus.dispose();
    _currentPage.dispose();
    final controller = _controller;
    final undo = _undoController;
    // The viewer detaches from these during its own dispose.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
      undo.dispose();
    });
    super.dispose();
  }

  /// setState that is safe to call from viewer callbacks, which can fire
  /// during build or while the old viewer is being disposed.
  void _post(VoidCallback change) {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(change);
      });
    } else {
      setState(change);
    }
  }

  void _onUndoChanged() => _post(() {});

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _nightMode = prefs.getBool(_prefNightMode) ?? false;
        _singlePage = prefs.getBool(_prefSinglePage) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _savePreference(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _loadBookmarks() async {
    try {
      final bookmarks = await _bookmarkService.getBookmarks(_bookmarkKey);
      if (mounted) setState(() => _bookmarks = bookmarks);
    } catch (_) {}
  }

  /// Reads the file and hands it straight to the viewer. The viewer parses
  /// the document itself; parsing it here first (to check for a password or
  /// count pages) doubled the work before anything showed. Password-protected
  /// files are detected from the viewer's load failure instead.
  Future<void> _open() async {
    if (_loadState != _LoadState.loading) {
      setState(() {
        _loadState = _LoadState.loading;
        _errorMessage = null;
      });
    }
    final initialPage = _lastReadPage();
    try {
      _sourceBytes ??= await widget.pdfFile.readAsBytes();
    } catch (e) {
      _fail('The file could not be read.', e);
      return;
    }
    final page = await initialPage;
    if (!mounted) return;
    _reloadViewer(_sourceBytes!, page: page);
  }

  Future<int> _lastReadPage() async {
    try {
      final lastRead = await _bookmarkService.getLastReadPosition(_bookmarkKey);
      // The viewer ignores a page past the end of the document.
      if (lastRead is num) return math.max(1, lastRead.toInt() + 1);
    } catch (_) {}
    return 1;
  }

  /// Asks for the password of the (encrypted) source file and shows the
  /// decrypted copy.
  Future<void> _promptPassword() async {
    final bytes = _sourceBytes;
    if (bytes == null || !mounted || _unlocking) return;
    setState(() {
      _loadState = _LoadState.loading;
      _errorMessage = null;
    });
    _unlocking = true;
    final Uint8List? unlocked;
    try {
      unlocked = await _unlock(bytes);
    } finally {
      _unlocking = false;
    }
    if (!mounted) return;
    if (unlocked == null) {
      // Only a cancelled prompt locks; a failure keeps _unlock's error.
      if (_loadState != _LoadState.error) {
        setState(() => _loadState = _LoadState.locked);
      }
      return;
    }
    final page = await _lastReadPage();
    if (mounted) _reloadViewer(unlocked, page: page);
  }

  /// Prompts for the password until it is right or the user gives up.
  /// Returns the decrypted bytes, or null when cancelled or when decrypting
  /// failed (then the screen is already in the error state).
  Future<Uint8List?> _unlock(Uint8List bytes) async {
    var wrong = false;
    while (true) {
      if (!mounted) return null;
      final password = await showPdfPasswordDialog(
        context,
        fileName: _fileName,
        wrongPassword: wrong,
      );
      if (password == null || !mounted) return null;
      try {
        final probe = await PdfDocumentOps.probe(bytes, password: password);
        if (probe.status == PdfOpenStatus.ok) {
          final plain = await PdfDocumentOps.decrypt(bytes, password);
          _password = password;
          return plain;
        }
        if (probe.status == PdfOpenStatus.invalid) {
          _fail('This file could not be opened as a PDF.', probe.message);
          return null;
        }
      } catch (e) {
        _fail('The PDF could not be decrypted.', e);
        return null;
      }
      wrong = true;
    }
  }

  void _fail(String message, [Object? error]) {
    if (!mounted) return;
    debugPrint('PdfViewerScreen: $message ${error ?? ''}');
    setState(() {
      _loadState = _LoadState.error;
      _errorMessage = message;
    });
  }

  void _configureController(PdfViewerController controller) {
    final settings = controller.annotationSettings;
    settings.highlight.color = _markupColors[PdfAnnotationMode.highlight]!;
    settings.underline.color = _markupColors[PdfAnnotationMode.underline]!;
    settings.strikethrough.color =
        _markupColors[PdfAnnotationMode.strikethrough]!;
    settings.squiggly.color = _markupColors[PdfAnnotationMode.squiggly]!;
    settings.stickyNote.color = _markupColors[PdfAnnotationMode.stickyNote]!;
    settings.isLocked = !_editMode;
    controller.annotationMode = _editMode
        ? _annotationMode
        : PdfAnnotationMode.none;
  }

  // ---------------------------------------------------------------------------
  // Viewer callbacks
  // ---------------------------------------------------------------------------

  void _onDocumentLoaded(PdfDocumentLoadedDetails details) {
    _post(() {
      _viewerDocument = details.document;
      _viewerReady = true;
      _pageCount = _controller.pageCount;
      if (_controller.pageNumber > 0) {
        _currentPage.value = _controller.pageNumber;
      }
    });
    _sweepTempFilesOnce();
  }

  /// The outline is read the first time the side panel is built rather than
  /// when the document loads; walking a long outline is UI-thread work.
  List<PdfOutlineNode>? get _outlineIfLoaded {
    final document = _viewerDocument;
    if (document == null) return null;
    return _outline ??= PdfOutlineNode.read(document);
  }

  void _onDocumentLoadFailed(PdfDocumentLoadFailedDetails details) {
    // 'Empty Password Error' / 'Invalid Password Error': the source file is
    // encrypted (the viewer is never given a password).
    if (details.error.endsWith('Password Error') &&
        identical(_viewerBytes, _sourceBytes)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptPassword());
      return;
    }
    _post(() {
      _loadState = _LoadState.error;
      _errorMessage = details.description.isNotEmpty
          ? details.description
          : 'This PDF could not be displayed.';
    });
  }

  void _onPageChanged(PdfPageChangedDetails details) {
    final page = details.newPageNumber;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _currentPage.value = page;
      });
    } else {
      _currentPage.value = page;
    }
    _lastReadTimer?.cancel();
    _lastReadTimer = Timer(const Duration(milliseconds: 600), () {
      _bookmarkService.saveLastReadPosition(
        _bookmarkKey,
        details.newPageNumber - 1,
      );
    });
  }

  void _markViewerChange([Object? _]) {
    _viewerHasChanges = true;
    _redoHistory.clear();
    if (!_dirty) _post(() => _dirty = true);
  }

  // ---------------------------------------------------------------------------
  // Document bytes, history and reloads
  // ---------------------------------------------------------------------------

  /// Current document including annotation/form edits made in the viewer.
  Future<Uint8List> _currentBytes() async {
    if (_viewerReady && _viewerHasChanges) {
      final saved = Uint8List.fromList(await _controller.saveDocument());
      _latestBytes = saved;
      _viewerHasChanges = false;
      return saved;
    }
    return _latestBytes!;
  }

  void _pushHistory(List<Uint8List> stack, Uint8List bytes) {
    stack.add(bytes);
    var total = stack.fold<int>(0, (sum, b) => sum + b.length);
    while (stack.length > _historyLimit ||
        (stack.length > 1 && total > _historyByteBudget)) {
      total -= stack.removeAt(0).length;
    }
  }

  /// Shows [bytes] in a fresh viewer, keeping the reading position.
  void _reloadViewer(Uint8List bytes, {int? page}) {
    final oldController = _controller;
    final oldRasterizer = _rasterizer;
    final controller = PdfViewerController();
    _configureController(controller);
    setState(() {
      _loadState = _LoadState.ready;
      _errorMessage = null;
      _viewerBytes = bytes;
      _latestBytes = bytes;
      _viewerHasChanges = false;
      _docVersion++;
      _viewerKey = GlobalKey();
      _controller = controller;
      _initialPage = math.max(1, page ?? _currentPage.value);
      _currentPage.value = _initialPage;
      _viewerReady = false;
      _viewerDocument = null;
      _outline = null;
      _selectedAnnotation = null;
      _searchResult = null;
      _searching = false;
      _pageMetas = null;
      _rasterizer = null;
    });
    oldRasterizer?.close();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => oldController.dispose(),
    );
  }

  /// Runs a structural edit on the current bytes and reloads the viewer.
  Future<bool> _runDocumentEdit(
    String label,
    Future<Uint8List> Function(Uint8List current) edit, {
    int? targetPage,
  }) async {
    if (_busy || _latestBytes == null) return false;
    _setBusy(label);
    try {
      final current = await _currentBytes();
      final next = await edit(current);
      if (!mounted) return false;
      _pushHistory(_history, current);
      _redoHistory.clear();
      _dirty = true;
      _reloadViewer(next, page: targetPage);
      return true;
    } catch (e) {
      _showError('$label failed', e);
      return false;
    } finally {
      _setBusy(null);
    }
  }

  void _setBusy(String? label) {
    if (mounted) setState(() => _busyLabel = label);
  }

  bool get _canUndo => _undoController.value.canUndo || _history.isNotEmpty;
  bool get _canRedo => _undoController.value.canRedo || _redoHistory.isNotEmpty;

  Future<void> _undo() async {
    if (_busy) return;
    if (_undoController.value.canUndo) {
      _undoController.undo();
      _viewerHasChanges = true;
      setState(() => _dirty = true);
      return;
    }
    if (_history.isEmpty) return;
    _setBusy('Undoing…');
    try {
      final current = await _currentBytes();
      _pushHistory(_redoHistory, current);
      final previous = _history.removeLast();
      if (!mounted) return;
      _dirty = true;
      _reloadViewer(previous);
    } catch (e) {
      _showError('Undo failed', e);
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _redo() async {
    if (_busy) return;
    if (_undoController.value.canRedo) {
      _undoController.redo();
      _viewerHasChanges = true;
      setState(() => _dirty = true);
      return;
    }
    if (_redoHistory.isEmpty) return;
    _setBusy('Redoing…');
    try {
      final current = await _currentBytes();
      _pushHistory(_history, current);
      final next = _redoHistory.removeLast();
      if (!mounted) return;
      _dirty = true;
      _reloadViewer(next);
    } catch (e) {
      _showError('Redo failed', e);
    } finally {
      _setBusy(null);
    }
  }

  // ---------------------------------------------------------------------------
  // Saving and sharing
  // ---------------------------------------------------------------------------

  Future<Uint8List> _bytesForDisk() async {
    final bytes = await _currentBytes();
    final password = _password;
    if (password == null || password.isEmpty) return bytes;
    return PdfDocumentOps.encrypt(bytes, password);
  }

  Future<bool> _save({required bool asCopy}) async {
    if (_busy || _latestBytes == null) return false;
    // A PDF-compatible file of another type (e.g. an Illustrator .ai opened
    // as PDF) would lose its own data if overwritten with a plain PDF.
    asCopy = asCopy || p.extension(_file.path).toLowerCase() != '.pdf';
    _setBusy(asCopy ? 'Saving a copy…' : 'Saving…');
    try {
      final out = await _bytesForDisk();
      final target = asCopy
          ? File(
              await _uniquePath(
                _file.parent.path,
                '${p.basenameWithoutExtension(_file.path)}_edited',
                '.pdf',
              ),
            )
          : _file;
      await _writeSafely(target, out);
      if (!mounted) return true;
      setState(() {
        _file = target;
        _dirty = false;
        _folderChanged = true;
      });
      _showMessage(asCopy ? 'Saved as ${p.basename(target.path)}' : 'Saved');
      return true;
    } on FileSystemException catch (e) {
      _showError(
        asCopy ? 'Could not save a copy' : 'Could not save this file',
        e.osError?.message ?? e.message,
        asCopy
            ? null
            : SnackBarAction(
                label: 'Save copy',
                onPressed: () => _save(asCopy: true),
              ),
      );
      return false;
    } catch (e) {
      _showError('Saving failed', e);
      return false;
    } finally {
      _setBusy(null);
    }
  }

  /// Writes [bytes] to [target] through a temporary file in the same folder
  /// that then replaces it, so a failed or interrupted write (full disk,
  /// removed card, app killed) never leaves the original truncated.
  static Future<void> _writeSafely(File target, Uint8List bytes) async {
    var path = target.path;
    try {
      // Replace the real file, not a symbolic link pointing at it.
      path = await target.resolveSymbolicLinks();
    } catch (_) {
      // A new file (save as copy) has nothing to resolve yet.
    }
    final temp = File(
      p.join(
        p.dirname(path),
        '.${p.basename(path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    // iPad shows the share sheet as a popover that needs an anchor: the
    // top bar's trailing corner, where the menu was opened.
    final size = MediaQuery.sizeOf(context);
    final origin = Rect.fromLTWH(
      math.max(0, size.width - 64),
      MediaQuery.paddingOf(context).top + 12,
      48,
      48,
    );
    Directory? shareDir;
    try {
      String path = _file.path;
      if (_dirty) {
        _setBusy('Preparing to share…');
        final out = await _bytesForDisk();
        // One fixed folder, emptied first: at most one shared copy is kept.
        shareDir = Directory(p.join(Directory.systemTemp.path, _shareDirName));
        await _deleteQuietly(shareDir);
        await shareDir.create(recursive: true);
        path = p.join(shareDir.path, _fileName);
        await File(path).writeAsBytes(out, flush: true);
        _setBusy(null);
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
      );
      // On Android share_plus copies the file into its own cache before
      // returning; elsewhere the target app may still be reading ours.
      if (shareDir != null && Platform.isAndroid) {
        await _deleteQuietly(shareDir);
      }
    } catch (e) {
      _setBusy(null);
      _showError('Sharing failed', e);
    }
  }

  static const _shareDirName = 'pdf_share';
  static bool _tempSwept = false;

  /// Once per run, removes temp copies left behind when the app was killed
  /// (shares of edited documents, page renderer copies).
  static void _sweepTempFilesOnce() {
    if (_tempSwept) return;
    _tempSwept = true;
    unawaited(() async {
      try {
        // The age check spares another running instance's files (desktop).
        final cutoff = DateTime.now().subtract(const Duration(hours: 1));
        await for (final entity in Directory.systemTemp.list()) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          final ours = name.startsWith('pdf_share') ||
              name.startsWith('pdf_pages_');
          if (ours && (await entity.stat()).modified.isBefore(cutoff)) {
            await _deleteQuietly(entity);
          }
        }
      } catch (_) {
        // Best effort.
      }
    }());
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<String> _uniquePath(String dir, String base, String ext) async {
    var candidate = p.join(dir, '$base$ext');
    var n = 2;
    while (await File(candidate).exists() ||
        await Directory(candidate).exists()) {
      candidate = p.join(dir, '$base ($n)$ext');
      n++;
    }
    return candidate;
  }

  Future<void> _handleBack() async {
    if (_busy) return;
    if (_dirty) {
      final choice = await showUnsavedPdfDialog(context);
      if (choice == null || !mounted) return;
      switch (choice) {
        case UnsavedChoice.save:
          if (!await _save(asCopy: false)) return;
        case UnsavedChoice.saveCopy:
          if (!await _save(asCopy: true)) return;
        case UnsavedChoice.discard:
          break;
      }
    }
    if (mounted) Navigator.of(context).pop(_folderChanged ? true : null);
  }

  // ---------------------------------------------------------------------------
  // Page editing
  // ---------------------------------------------------------------------------

  Future<void> _ensurePageData() async {
    if (_pageDataLoading || _latestBytes == null) return;
    if (_pageMetas != null &&
        (_rasterizer != null || _pageDataFailedVersion == _docVersion)) {
      return;
    }
    _pageDataLoading = true;
    final version = _docVersion;
    final bytes = _viewerBytes!;
    try {
      final metas = _pageMetas ?? await PdfDocumentOps.pageMetas(bytes);
      var rasterizer = _rasterizer;
      if (rasterizer == null && _pageDataFailedVersion != version) {
        try {
          rasterizer = await PdfPageRasterizer.open(bytes);
        } catch (_) {
          // Thumbnails are optional; the page list still works without.
          _pageDataFailedVersion = version;
        }
      }
      if (!mounted || version != _docVersion) {
        if (rasterizer != _rasterizer) await rasterizer?.close();
        return;
      }
      setState(() {
        _pageMetas = metas;
        _rasterizer = rasterizer;
      });
    } catch (e) {
      _pageDataFailedVersion = version;
      _showError('Could not read the pages', e);
    } finally {
      _pageDataLoading = false;
      if (mounted && version != _docVersion) _ensurePageData();
    }
  }

  Future<void> _applyPagePlan(List<PagePlanEntry> plan) async {
    final page = _currentPage.value - 1;
    final newIndex = plan.indexWhere((e) => e.sourceIndex == page);
    final ok = await _runDocumentEdit(
      'Updating pages',
      (bytes) => PdfDocumentOps.applyPagePlan(bytes, plan),
      targetPage: newIndex >= 0
          ? newIndex + 1
          : math.min(page + 1, plan.length),
    );
    if (ok) _showMessage('Pages updated');
  }

  Future<void> _extractPages(Set<int> pages) async {
    if (_busy) return;
    _setBusy('Extracting pages…');
    try {
      final current = await _currentBytes();
      var out = await PdfDocumentOps.extractPages(current, pages);
      final password = _password;
      if (password != null && password.isNotEmpty) {
        out = await PdfDocumentOps.encrypt(out, password);
      }
      final path = await _uniquePath(
        _file.parent.path,
        '${p.basenameWithoutExtension(_file.path)}_pages',
        '.pdf',
      );
      await _writeSafely(File(path), out);
      _folderChanged = true;
      _showMessage(
        'Saved ${pages.length} page${pages.length == 1 ? '' : 's'} to '
        '${p.basename(path)}',
      );
    } catch (e) {
      _showError('Extracting pages failed', e);
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _insertPdf() async {
    if (_busy) return;
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
    } catch (e) {
      _showError('Could not open the file picker', e);
      return;
    }
    final picked = result?.files.singleOrNull;
    if (picked == null || !mounted) return;

    Uint8List other;
    try {
      other = picked.bytes ?? await File(picked.path!).readAsBytes();
    } catch (e) {
      _showError('Could not read ${picked.name}', e);
      return;
    }

    String? otherPassword;
    var probe = await PdfDocumentOps.probe(other);
    var wrong = false;
    while (probe.status == PdfOpenStatus.needsPassword) {
      if (!mounted) return;
      otherPassword = await showPdfPasswordDialog(
        context,
        fileName: picked.name,
        wrongPassword: wrong,
      );
      if (otherPassword == null) return;
      probe = await PdfDocumentOps.probe(other, password: otherPassword);
      wrong = true;
    }
    if (!mounted) return;
    if (probe.status != PdfOpenStatus.ok) {
      _showError('${picked.name} is not a readable PDF', probe.message);
      return;
    }

    final current = _currentPage.value;
    final position = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          'Insert ${probe.pageCount} page'
          '${probe.pageCount == 1 ? '' : 's'}',
        ),
        contentPadding: const EdgeInsets.fromLTRB(4, 12, 4, 16),
        children: [
          ViewerListTile(
            leading: const Icon(LucideIcons.betweenHorizontalStart),
            title: 'After page $current',
            onTap: () => Navigator.pop(context, current),
          ),
          ViewerListTile(
            leading: const Icon(LucideIcons.arrowDownToLine),
            title: 'At the end',
            onTap: () => Navigator.pop(context, _pageCount),
          ),
          ViewerListTile(
            leading: const Icon(LucideIcons.arrowUpToLine),
            title: 'At the beginning',
            onTap: () => Navigator.pop(context, 0),
          ),
        ],
      ),
    );
    if (position == null || !mounted) return;
    final ok = await _runDocumentEdit(
      'Inserting PDF',
      (bytes) => PdfDocumentOps.insertPdf(
        bytes,
        other,
        otherPassword: otherPassword,
        index: position,
      ),
      targetPage: position + 1,
    );
    if (ok) _showMessage('Inserted ${picked.name}');
  }

  PdfPageMeta? _metaForPage(int pageIndex) {
    final document = _viewerDocument;
    if (document == null || pageIndex < 0) return null;
    try {
      if (pageIndex >= document.pages.count) return null;
      final page = document.pages[pageIndex];
      final rotation = switch (page.rotation) {
        PdfPageRotateAngle.rotateAngle90 => 90,
        PdfPageRotateAngle.rotateAngle180 => 180,
        PdfPageRotateAngle.rotateAngle270 => 270,
        _ => 0,
      };
      return PdfPageMeta(
        width: page.size.width,
        height: page.size.height,
        rotation: rotation,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openCanvas(PageCanvasTool tool, PageCanvasStart start) async {
    if (_busy || !_viewerReady) return;
    final pageIndex = _currentPage.value - 1;
    final meta = _metaForPage(pageIndex);
    if (meta == null) return;
    _setBusy('Preparing page…');
    Uint8List bytes;
    try {
      bytes = await _currentBytes();
    } catch (e) {
      _showError('Could not prepare the page', e);
      return;
    } finally {
      _setBusy(null);
    }
    if (!mounted) return;
    // The canvas stays open until the marks are burned in, so a failure
    // (e.g. an unreadable image) doesn't throw away the whole session.
    await Navigator.push<List<PageMark>>(
      context,
      MaterialPageRoute(
        builder: (_) => PdfPageCanvasScreen(
          documentBytes: bytes,
          pageNumber: pageIndex + 1,
          meta: meta,
          initialTool: tool,
          start: start,
          initialColor: _canvasColor,
          onApply: (marks) => _runDocumentEdit(
            'Adding to page',
            (current) => PdfDocumentOps.drawOnPage(current, pageIndex, marks),
            targetPage: pageIndex + 1,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Annotation tools
  // ---------------------------------------------------------------------------

  void _setEditMode(bool on) {
    final selected = _selectedAnnotation;
    if (!on && selected != null) _controller.deselectAnnotation(selected);
    setState(() {
      _editMode = on;
      if (!on) {
        _annotationMode = PdfAnnotationMode.none;
        _selectedAnnotation = null;
      }
      _configureController(_controller);
    });
  }

  void _setAnnotationMode(PdfAnnotationMode mode) {
    final selected = _selectedAnnotation;
    if (selected != null) _controller.deselectAnnotation(selected);
    setState(() {
      _annotationMode = mode;
      _selectedAnnotation = null;
      _controller.annotationMode = mode;
    });
  }

  Color get _toolbarColor {
    final selected = _selectedAnnotation;
    if (selected != null) return selected.color;
    return _markupColors[_annotationMode] ?? _canvasColor;
  }

  Future<void> _pickColor() async {
    final color = await showPdfColorPicker(context, _toolbarColor);
    if (color == null || !mounted) return;
    final selected = _selectedAnnotation;
    if (selected != null) {
      // Goes through the viewer's undo history and onAnnotationEdited.
      selected.color = color;
      setState(() {});
      return;
    }
    setState(() {
      if (_markupColors.containsKey(_annotationMode)) {
        _markupColors[_annotationMode] = color;
        _configureController(_controller);
      } else {
        _canvasColor = color;
      }
    });
  }

  void _deleteSelectedAnnotation() {
    final selected = _selectedAnnotation;
    if (selected == null) return;
    _controller.removeAnnotation(selected);
    setState(() => _selectedAnnotation = null);
  }

  Future<void> _editSelectedNote() async {
    final note = _selectedAnnotation;
    if (note is! StickyNoteAnnotation) return;
    final text = await showPdfTextInputDialog(
      context,
      title: 'Edit note',
      initialText: note.text,
      confirmLabel: 'Save',
      multiline: true,
    );
    if (text == null || !mounted) return;
    note.text = text;
    _markViewerChange();
  }

  // ---------------------------------------------------------------------------
  // Navigation, search, bookmarks
  // ---------------------------------------------------------------------------

  ScaffoldState? get _scaffold {
    final context = _bodyKey.currentContext;
    return context == null ? null : Scaffold.maybeOf(context);
  }

  void _closeDrawerIfOpen() {
    final scaffold = _scaffold;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  void _goToPageIndex(int index) {
    if (!_viewerReady) return;
    _controller.jumpToPage((index + 1).clamp(1, math.max(1, _pageCount)));
    _closeDrawerIfOpen();
  }

  void _openOutlineNode(PdfOutlineNode node) {
    if (!_viewerReady) return;
    try {
      final bookmark = node.bookmark;
      final hasTarget =
          bookmark.destination != null ||
          bookmark.namedDestination?.destination != null;
      if (hasTarget) {
        _controller.jumpToBookmark(bookmark);
        _closeDrawerIfOpen();
        return;
      }
    } catch (_) {
      // Fall through to the message below.
    }
    _showMessage('This outline entry has no page to go to');
  }

  Future<void> _showGoToPage() async {
    if (!_viewerReady) return;
    final page = await showGoToPageDialog(
      context,
      pageCount: _pageCount,
      currentPage: _currentPage.value,
    );
    if (page != null && mounted) _controller.jumpToPage(page);
  }

  Bookmark? get _bookmarkOnCurrentPage {
    final index = _currentPage.value - 1;
    for (final bookmark in _bookmarks) {
      final position = bookmark.position;
      if (position is num && position.toInt() == index) return bookmark;
    }
    return null;
  }

  Future<void> _toggleBookmark() async {
    final existing = _bookmarkOnCurrentPage;
    if (existing != null) {
      await _removeBookmark(existing);
      return;
    }
    final page = _currentPage.value;
    try {
      await _bookmarkService.addBookmark(_bookmarkKey, page - 1, 'Page $page');
      await _loadBookmarks();
      _showMessage('Bookmarked page $page');
    } catch (e) {
      _showError('Could not add the bookmark', e);
    }
  }

  Future<void> _removeBookmark(Bookmark bookmark) async {
    try {
      await _bookmarkService.removeBookmark(_bookmarkKey, bookmark.id);
      await _loadBookmarks();
    } catch (e) {
      _showError('Could not remove the bookmark', e);
    }
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchResult?.clear();
    setState(() {
      _searchOpen = false;
      _searchResult = null;
      _searching = false;
    });
  }

  void _submitSearch(String text) {
    final query = text.trim();
    _searchResult?.clear();
    if (query.isEmpty || !_viewerReady) {
      setState(() {
        _searchResult = null;
        _searching = false;
      });
      return;
    }
    final option = _matchCase && _wholeWords
        ? TextSearchOption.both
        : _matchCase
        ? TextSearchOption.caseSensitive
        : _wholeWords
        ? TextSearchOption.wholeWords
        : null;
    final result = _controller.searchText(query, searchOption: option);
    setState(() {
      _searchResult = result;
      _searching = true;
    });
  }

  void _openPanel(int tab) {
    setState(() => _panelTab = tab);
    if (AdaptiveSplitView.isSplit(context)) {
      setState(() => _panelOpen = true);
    } else {
      _scaffold?.openDrawer();
    }
  }

  void _togglePanel() {
    if (AdaptiveSplitView.isSplit(context)) {
      setState(() => _panelOpen = !(_panelOpen ?? true));
    } else {
      _scaffold?.openDrawer();
    }
  }

  // ---------------------------------------------------------------------------
  // Menu
  // ---------------------------------------------------------------------------

  Future<void> _onMenu(_MenuAction action) async {
    switch (action) {
      case _MenuAction.save:
        await _save(asCopy: false);
      case _MenuAction.saveCopy:
        await _save(asCopy: true);
      case _MenuAction.share:
        await _share();
      case _MenuAction.goToPage:
        await _showGoToPage();
      case _MenuAction.toggleBookmark:
        await _toggleBookmark();
      case _MenuAction.pages:
        _openPanel(2);
      case _MenuAction.insertPdf:
        await _insertPdf();
      case _MenuAction.layout:
        setState(() => _singlePage = !_singlePage);
        _savePreference(_prefSinglePage, _singlePage);
      case _MenuAction.nightMode:
        setState(() => _nightMode = !_nightMode);
        _savePreference(_prefNightMode, _nightMode);
      case _MenuAction.zoomIn:
        _controller.zoomLevel = math.min(5, _controller.zoomLevel + 0.5);
      case _MenuAction.zoomOut:
        _controller.zoomLevel = math.max(1, _controller.zoomLevel - 0.5);
      case _MenuAction.setPassword:
        final password = await showSetPdfPasswordDialog(context);
        if (password == null || !mounted) return;
        setState(() {
          _password = password;
          _dirty = true;
        });
        _showMessage('The password will be applied when you save');
      case _MenuAction.removePassword:
        final confirmed = await showPdfConfirmDialog(
          context,
          title: 'Remove password?',
          message: 'The saved file will open without a password.',
          confirmLabel: 'Remove',
        );
        if (!confirmed || !mounted) return;
        setState(() {
          _password = null;
          _dirty = true;
        });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String message, [Object? error, SnackBarAction? action]) {
    if (!mounted) return;
    debugPrint('PdfViewerScreen: $message ${error ?? ''}');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final split = AdaptiveSplitView.isSplit(context);
    final width = MediaQuery.sizeOf(context).width;
    final ready = _loadState == _LoadState.ready;

    return PopScope(
      canPop: !_dirty && !_busy && !_folderChanged,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_dirty) _save(asCopy: false);
          },
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
            if (_dirty) _save(asCopy: false);
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_searchOpen) _closeSearch();
          },
        },
        child: Focus(
          autofocus: true,
          child: ExplorerScaffold(
            title: _dirty ? '$_fileName •' : _fileName,
            drawer: ready && !split
                ? AppSidebar(
                    width: math.min(380, width * 0.9),
                    child: _buildSidePanel(docked: false),
                  )
                : null,
            trailing: ready ? _buildTopActions(context, split) : null,
            body: KeyedSubtree(
              key: _bodyKey,
              child: _buildBody(context, split),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopActions(BuildContext context, bool split) {
    final hasPassword = _password != null && _password!.isNotEmpty;
    final bookmarked = _bookmarkOnCurrentPage != null;
    final panelShown = split && (_panelOpen ?? true);
    return ViewerActions(
      children: [
        ViewerAction(
          icon: LucideIcons.search,
          tooltip: 'Search',
          selected: _searchOpen,
          onPressed: _viewerReady
              ? () => _searchOpen ? _closeSearch() : _openSearch()
              : null,
        ),
        ViewerAction(
          icon: split
              ? (panelShown ? LucideIcons.panelLeftClose : LucideIcons.panelLeft)
              : LucideIcons.listTree,
          tooltip: 'Outline, bookmarks and pages',
          onPressed: _togglePanel,
        ),
        ViewerAction(
          icon: _editMode ? LucideIcons.check : LucideIcons.penLine,
          tooltip: _editMode ? 'Done editing' : 'Edit and annotate',
          selected: _editMode,
          onPressed: _viewerReady ? () => _setEditMode(!_editMode) : null,
        ),
        ViewerMenuButton<_MenuAction>(
          enabled: !_busy,
          badge: _dirty,
          onSelected: _onMenu,
          itemBuilder: (context) => [
            viewerMenuItem(
              value: _MenuAction.save,
              icon: LucideIcons.save,
              label: 'Save',
              hint: 'Ctrl+S',
              enabled: _dirty,
            ),
            viewerMenuItem(
              value: _MenuAction.saveCopy,
              icon: LucideIcons.copy,
              label: 'Save as copy',
            ),
            viewerMenuItem(
              value: _MenuAction.share,
              icon: LucideIcons.share2,
              label: 'Share',
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: _MenuAction.goToPage,
              icon: LucideIcons.fileSearch,
              label: 'Go to page…',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.toggleBookmark,
              icon: bookmarked
                  ? LucideIcons.bookmarkMinus
                  : LucideIcons.bookmarkPlus,
              label: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.pages,
              icon: LucideIcons.layers,
              label: 'Organise pages',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.insertPdf,
              icon: LucideIcons.filePlus,
              label: 'Insert PDF…',
              enabled: _viewerReady,
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: _MenuAction.layout,
              icon: LucideIcons.galleryVertical,
              label: 'Continuous scroll',
              checked: !_singlePage,
            ),
            viewerMenuItem(
              value: _MenuAction.nightMode,
              icon: LucideIcons.moon,
              label: 'Night mode',
              checked: _nightMode,
            ),
            viewerMenuItem(
              value: _MenuAction.zoomIn,
              icon: LucideIcons.zoomIn,
              label: 'Zoom in',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.zoomOut,
              icon: LucideIcons.zoomOut,
              label: 'Zoom out',
              enabled: _viewerReady,
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: _MenuAction.setPassword,
              icon: LucideIcons.lock,
              label: hasPassword ? 'Change password…' : 'Set password…',
            ),
            if (hasPassword)
              viewerMenuItem(
                value: _MenuAction.removePassword,
                icon: LucideIcons.lockOpen,
                label: 'Remove password',
                destructive: true,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, bool split) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    switch (_loadState) {
      case _LoadState.loading:
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: const _PageSkeleton(),
        );
      case _LoadState.locked:
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: ViewerMessage(
            icon: LucideIcons.lock,
            title: 'This PDF is password protected',
            message: 'Enter its password to open it.',
            actions: [
              FilledButton.icon(
                onPressed: _promptPassword,
                icon: const Icon(LucideIcons.keyRound, size: 16),
                label: const Text('Enter password'),
              ),
            ],
          ),
        );
      case _LoadState.error:
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: ViewerMessage(
            icon: LucideIcons.fileX,
            destructive: true,
            title: "Couldn't open this PDF",
            message: _errorMessage ?? 'This PDF could not be opened.',
            actions: [
              FilledButton.icon(
                onPressed: () {
                  _sourceBytes = null;
                  _open();
                },
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('Try again'),
              ),
            ],
          ),
        );
      case _LoadState.ready:
        break;
    }

    final viewerArea = _buildViewerArea(context);
    final showPane = split && (_panelOpen ?? true);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: showPane
          ? AdaptiveSplitView(
              secondaryWidth: 340,
              primary: viewerArea,
              secondary: _buildSidePanel(docked: true),
            )
          : viewerArea,
    );
  }

  Widget _buildSidePanel({required bool docked}) {
    final panel = ValueListenableBuilder<int>(
      valueListenable: _currentPage,
      builder: (context, page, _) => _buildSidePanelContent(docked, page),
    );
    if (!docked) return panel;
    return ColoredBox(color: context.colors.background, child: panel);
  }

  Widget _buildSidePanelContent(bool docked, int currentPage) {
    return PdfSidePanel(
      tabIndex: _panelTab,
      onTabChanged: (tab) => _post(() => _panelTab = tab),
      outline: _outlineIfLoaded,
      onOutlineSelected: _openOutlineNode,
      bookmarks: _bookmarks,
      currentPage: currentPage,
      onBookmarkSelected: _goToPageIndex,
      onBookmarkRemoved: _removeBookmark,
      onAddBookmark: _viewerReady ? _toggleBookmark : null,
      onClose: docked ? () => setState(() => _panelOpen = false) : null,
      pages: PdfPageManager(
        metas: _pageMetas,
        rasterizer: _rasterizer,
        currentPage: _currentPage,
        busy: _busy || !_viewerReady,
        onOpenPage: _goToPageIndex,
        onApply: _applyPagePlan,
        onExtract: _extractPages,
        onInsertPdf: _insertPdf,
        onNeedData: _ensurePageData,
      ),
    );
  }

  /// Colours for SfPdfViewer's own chrome (scroll head, page dialog, link
  /// dialog) from the app tokens, so it reads well in light and dark mode.
  SfPdfViewerThemeData _viewerTheme(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    // Night mode inverts the whole viewer, surround included: give it the
    // colour that inverts to a dark surround.
    final surround = _nightMode
        ? _invert(context.isDarkMode ? colors.muted : const Color(0xFF27272A))
        : ViewerSurface.canvas(context);
    final title = text.titleLarge?.copyWith(fontSize: 18);
    final body = text.bodyMedium?.copyWith(color: colors.foreground);
    final muted = text.bodyMedium?.copyWith(color: colors.mutedForeground);
    final action = text.labelLarge?.copyWith(color: colors.foreground);
    final primary = text.labelLarge?.copyWith(color: colors.primary);
    return SfPdfViewerThemeData(
      backgroundColor: surround,
      progressBarColor: colors.primary,
      scrollHeadStyle: PdfScrollHeadStyle(
        backgroundColor: colors.popover,
        pageNumberTextStyle: text.labelMedium?.copyWith(
          color: colors.popoverForeground,
        ),
      ),
      scrollStatusStyle: PdfScrollStatusStyle(
        backgroundColor: colors.foreground,
        pageInfoTextStyle: text.labelMedium?.copyWith(color: colors.background),
      ),
      paginationDialogStyle: PdfPaginationDialogStyle(
        backgroundColor: colors.background,
        headerTextStyle: title,
        inputFieldTextStyle: body,
        hintTextStyle: muted,
        pageInfoTextStyle: muted,
        validationTextStyle: text.bodySmall?.copyWith(color: colors.destructive),
        okTextStyle: primary,
        cancelTextStyle: action,
      ),
      hyperlinkDialogStyle: PdfHyperlinkDialogStyle(
        backgroundColor: colors.background,
        headerTextStyle: title,
        contentTextStyle: muted,
        openTextStyle: primary,
        cancelTextStyle: action,
        closeIconColor: colors.mutedForeground,
      ),
      passwordDialogStyle: PdfPasswordDialogStyle(
        backgroundColor: colors.background,
        headerTextStyle: title,
        contentTextStyle: muted,
        inputFieldTextStyle: body,
        inputFieldHintTextStyle: muted,
        inputFieldLabelTextStyle: muted,
        errorTextStyle: text.bodySmall?.copyWith(color: colors.destructive),
        openTextStyle: primary,
        cancelTextStyle: action,
        closeIconColor: colors.mutedForeground,
        visibleIconColor: colors.mutedForeground,
      ),
    );
  }

  /// [color] through the night-mode matrix (which is its own inverse).
  static Color _invert(Color color) {
    final r = color.r * 255, g = color.g * 255, b = color.b * 255;
    double channel(int row) {
      final m = _nightMatrix;
      final i = row * 5;
      return (m[i] * r + m[i + 1] * g + m[i + 2] * b + m[i + 4]).clamp(0, 255);
    }

    return Color.fromARGB(
      255,
      channel(0).round(),
      channel(1).round(),
      channel(2).round(),
    );
  }

  Widget _buildViewer() {
    return SfPdfViewer.memory(
      _viewerBytes!,
      key: _viewerKey,
      controller: _controller,
      undoController: _undoController,
      initialPageNumber: _initialPage,
      pageLayoutMode: _singlePage
          ? PdfPageLayoutMode.single
          : PdfPageLayoutMode.continuous,
      maxZoomLevel: 5,
      enableDoubleTapZooming: true,
      enableTextSelection: true,
      canShowPasswordDialog: false,
      canShowScrollHead: true,
      canShowScrollStatus: true,
      canShowPaginationDialog: true,
      canShowHyperlinkDialog: true,
      enableHyperlinkNavigation: true,
      enableDocumentLinkAnnotation: true,
      onDocumentLoaded: _onDocumentLoaded,
      onDocumentLoadFailed: _onDocumentLoadFailed,
      onPageChanged: _onPageChanged,
      onAnnotationAdded: _markViewerChange,
      onAnnotationRemoved: _markViewerChange,
      onAnnotationEdited: _markViewerChange,
      onAnnotationSelected: (annotation) =>
          _post(() => _selectedAnnotation = annotation),
      onAnnotationDeselected: (annotation) => _post(() {
        if (identical(_selectedAnnotation, annotation)) {
          _selectedAnnotation = null;
        }
      }),
      onFormFieldValueChanged: _markViewerChange,
    );
  }

  Widget _buildViewerArea(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = media.padding.bottom;
    final hasHint =
        PdfAnnotationToolbar.hintFor(_annotationMode, _selectedAnnotation) !=
        null;
    final toolbarSpace = !_editMode ? 0.0 : (hasHint ? 100.0 : 60.0);

    return Padding(
      padding: EdgeInsets.only(
        left: media.padding.left,
        right: media.padding.right,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(
                _nightMode ? _nightMatrix : _identityMatrix,
              ),
              child: SfPdfViewerTheme(
                data: _viewerTheme(context),
                child: _buildViewer(),
              ),
            ),
          ),
          // Until the first document is shown (the viewer has its own
          // progress bar; later reloads keep the old pages' layout).
          if (!_viewerReady && _pageCount == 0)
            const Positioned.fill(
              child: IgnorePointer(child: _PageSkeleton(showProgress: false)),
            ),
          if (_searchOpen)
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: PdfSearchBar(
                    controller: _searchText,
                    focusNode: _searchFocus,
                    result: _searchResult,
                    searching: _searching,
                    matchCase: _matchCase,
                    wholeWords: _wholeWords,
                    onSubmitted: _submitSearch,
                    onOptionsChanged: ({matchCase, wholeWords}) {
                      setState(() {
                        _matchCase = matchCase ?? _matchCase;
                        _wholeWords = wholeWords ?? _wholeWords;
                      });
                      if (_searchResult != null) {
                        _submitSearch(_searchText.text);
                      }
                    },
                    onClose: _closeSearch,
                  ),
                ),
              ),
            ),
          if (_viewerReady)
            Positioned(
              left: 12,
              bottom: bottom + 12 + toolbarSpace,
              child: ValueListenableBuilder<int>(
                valueListenable: _currentPage,
                builder: (context, page, _) => ViewerPill(
                  text: '$page / $_pageCount',
                  semanticsLabel:
                      'Page $page of $_pageCount. Tap to go to a page',
                  onTap: _showGoToPage,
                ),
              ),
            ),
          if (_editMode)
            Positioned(
              left: 8,
              right: 8,
              bottom: bottom + 8,
              child: Center(
                child: PdfAnnotationToolbar(
                  mode: _annotationMode,
                  onModeChanged: _setAnnotationMode,
                  color: _toolbarColor,
                  onPickColor: _pickColor,
                  onDraw: () =>
                      _openCanvas(PageCanvasTool.pen, PageCanvasStart.none),
                  onText: () =>
                      _openCanvas(PageCanvasTool.text, PageCanvasStart.none),
                  onImage: () =>
                      _openCanvas(PageCanvasTool.select, PageCanvasStart.image),
                  onSignature: () => _openCanvas(
                    PageCanvasTool.select,
                    PageCanvasStart.signature,
                  ),
                  canUndo: _canUndo,
                  canRedo: _canRedo,
                  onUndo: _undo,
                  onRedo: _redo,
                  selected: _selectedAnnotation,
                  onDeleteSelected: _deleteSelectedAnnotation,
                  onEditNote: _editSelectedNote,
                  enabled: !_busy && _viewerReady,
                ),
              ),
            ),
          if (_busy)
            Positioned.fill(child: ViewerBusyOverlay(label: _busyLabel!)),
        ],
      ),
    );
  }
}

/// Page-shaped placeholder shown from the first frame until the document is
/// on screen.
class _PageSkeleton extends StatelessWidget {
  const _PageSkeleton({this.showProgress = true});

  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: ViewerSurface.canvas(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(0.0, math.min(constraints.maxWidth - 24, 760.0));
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  top: 12,
                  left: (constraints.maxWidth - width) / 2,
                  width: width,
                  height: width * math.sqrt2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.background,
                      border: Border.all(color: colors.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                if (showProgress)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
