import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../common/office_files.dart';
import '../document/doc_model.dart';
import '../document/document_loader.dart';
import '../document/docx_writer.dart';
import '../document/layout/doc_layout.dart';
import '../document/layout/doc_render_context.dart';
import '../document/rtf_writer.dart';
import '../document/widgets/doc_editor.dart';
import '../document/widgets/doc_views.dart';

Future<Uint8List> _docxInBackground(DocModel model, Uint8List? original) =>
    Isolate.run(() => writeDocx(model, original: original));

Future<Uint8List> _rtfInBackground(DocModel model) =>
    Isolate.run(() => writeRtf(model));

enum _SaveKind { overwrite, copy, asDocx }

class _Match {
  _Match(this.paragraph, this.start, this.end);
  final DocParagraph paragraph;
  final int start;
  final int end;
}

/// Viewer and editor for word-processing documents: DOCX/DOCM/DOTX/DOTM,
/// DOC/DOT/WPS, RTF and ODT/OTT/FODT.
///
/// Pops with `true` when it created a new file (e.g. "Save as .docx") so the
/// explorer can refresh.
class WordViewerScreen extends StatefulWidget {
  const WordViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<WordViewerScreen> createState() => _WordViewerScreenState();
}

class _WordViewerScreenState extends State<WordViewerScreen> {
  late File _file;

  /// Bytes [_model] was parsed from. DOCX saves rebuild from this package
  /// (the model's verbatim spans point into it), so it changes only together
  /// with the model.
  Uint8List? _originalBytes;
  DocModel? _model;

  /// [_model] holds only the first pages of a long document whose full
  /// parse is still running: view-only.
  bool _partial = false;
  DocImageCache? _images;
  String? _error;
  bool _loading = true;

  DocLayoutResult? _layout;
  double _layoutProgress = 0;
  int _layoutGen = 0;
  final DocViewController _viewController = DocViewController();

  // Derived from the model on first use, not while opening.
  Map<DocParagraph, int>? _topIndexCache;
  List<(int, DocParagraph)>? _headingList;
  Map<DocParagraph, int> get _topIndex =>
      _topIndexCache ??= _indexParagraphs(_model!);

  bool _darkPage = false;
  bool? _printLayout;

  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  List<_Match> _matches = [];
  int _matchIndex = -1;
  Map<DocParagraph, List<DocHighlight>> _highlights = const {};

  DocEditorSession? _session;
  Completer<void>? _editingDone;

  /// Format future "Save" writes in, or null when the source can't be
  /// written faithfully (DOC, ODT, WPS, text → "Save as .docx").
  String? _saveFormat;

  /// False when the file holds content its writer can't reproduce (an RTF
  /// with headers, footers, notes, lists or fields): edits then go to a
  /// copy instead of replacing it.
  bool _overwriteAllowed = true;
  Uint8List? _lastSaved;
  bool _createdNewFile = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _file = widget.file;
    _load();
  }

  @override
  void dispose() {
    _editingDone?.complete();
    _editingDone = null;
    _session?.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  String get _ext =>
      p.extension(_file.path).toLowerCase().replaceFirst('.', '');

  // ---------------------------------------------------------------------------
  // Loading & layout

  Future<void> _load() async {
    try {
      final bytes = await _file.readAsBytes();
      // Long documents arrive in two steps: the first pages (shown at once)
      // and then the whole model.
      final model = await parseDocumentInBackground(
        bytes,
        _ext,
        onPreview: (preview) {
          if (!mounted || _model != null) return;
          _partial = true;
          _setModel(preview);
        },
      );
      if (!mounted) return;
      _originalBytes = bytes;
      _partial = false;
      _saveFormat = _overwriteFormatFor(model.format, _ext);
      _overwriteAllowed = !model.warnings.contains(DocModel.warnUnwritable);
      _setModel(model, keepLayout: true);
      final note = model.warnings.contains('plainText')
          ? 'Showing the text only — formatting in this file isn\'t supported.'
          : model.warnings.contains(DocModel.warnEncoding)
          ? 'Some text uses an encoding that can\'t be shown here (shown as �).'
          : null;
      if (note != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(note)));
      }
    } on DocumentEncryptedException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'This document is password-protected. Open it in Word or another '
            'app that can decrypt it.';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'This file couldn\'t be read as a document.\n${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong while opening this document.';
      });
    }
  }

  static String? _overwriteFormatFor(String format, String ext) {
    const docxExts = {'docx', 'docm', 'dotx', 'dotm', 'doc', 'dot'};
    if (format == 'docx' && docxExts.contains(ext)) return 'docx';
    if (format == 'rtf' && (ext == 'rtf' || ext == 'doc')) return 'rtf';
    return null;
  }

  /// Shows [model]. With [keepLayout] the current pages stay up until the
  /// new layout's first page is ready (the full model replacing its
  /// preview lays out the same first pages).
  void _setModel(DocModel model, {bool keepLayout = false}) {
    setState(() {
      _model = model;
      _images = DocImageCache(model);
      _loading = false;
      _error = null;
      if (!keepLayout) _layout = null;
      _layoutProgress = 0;
      _topIndexCache = null;
      _headingList = null;
      _matches = [];
      _matchIndex = -1;
      _highlights = const {};
    });
    if (_searchOpen && _searchCtrl.text.isNotEmpty) {
      _runSearch(_searchCtrl.text);
    }
    _relayout();
  }

  /// Headings for the outline, collected after the first frame so opening
  /// doesn't wait for them (empty until then).
  List<(int, DocParagraph)> _headings() {
    final cached = _headingList;
    if (cached != null) return cached;
    final model = _model;
    if (model == null || _partial) return const [];
    _headingList = const [];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_model, model)) return;
      final out = <(int, DocParagraph)>[];
      for (var i = 0; i < model.blocks.length; i++) {
        final b = model.blocks[i];
        if (b is DocParagraph &&
            b.headingLevel != null &&
            b.plainText.trim().isNotEmpty) {
          out.add((i, b));
        }
      }
      if (out.isEmpty) return;
      setState(() => _headingList = out);
    });
    return const [];
  }

  static Map<DocParagraph, int> _indexParagraphs(DocModel m) {
    final out = <DocParagraph, int>{};
    for (var i = 0; i < m.blocks.length; i++) {
      final b = m.blocks[i];
      if (b is DocParagraph) {
        out[b] = i;
      } else {
        for (final p in DocModel.paragraphsIn([b])) {
          out[p] = i;
        }
      }
    }
    return out;
  }

  DocRenderContext _ctx() => DocRenderContext(
    model: _model!,
    images: _images!,
    darkPage: _darkPage,
    highlights: _highlights,
    onLink: _openLink,
  );

  /// Paginates the model a slice at a time between frames, showing the
  /// first page as soon as it's done and further pages as they're ready.
  Future<void> _relayout() async {
    final model = _model;
    if (model == null) return;
    final gen = ++_layoutGen;
    final pager = DocPaginator(
      model,
      DocRenderContext(model: model, images: _images!),
    );
    var shown = -1;
    final sinceShown = Stopwatch()..start();
    while (true) {
      final done = pager.step(Duration(milliseconds: shown < 0 ? 8 : 12));
      if (!mounted || gen != _layoutGen) return;
      final pages = pager.result.pages.length;
      if (done ||
          (pages > 0 &&
              pages != shown &&
              (shown < 0 || sinceShown.elapsedMilliseconds > 300))) {
        shown = pages;
        sinceShown.reset();
        // A preview's pages are only the start of the document.
        if (done && _partial) pager.result.complete = false;
        setState(() {
          _layout = pager.result;
          _layoutProgress = pager.progress;
        });
      }
      if (done) return;
      // Let a frame (scrolling, the first pages) through between slices.
      await Future<void>.delayed(Duration.zero);
      // Pause while the editor is up so typing stays smooth.
      while (_editingDone != null) {
        await _editingDone!.future;
      }
      if (!mounted || gen != _layoutGen) return;
    }
  }

  void _openLink(String url) => showLinkSheet(context, url);

  // ---------------------------------------------------------------------------
  // Search

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      _searchFocus.requestFocus();
    } else {
      _searchCtrl.clear();
      _setMatches([], -1);
    }
  }

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _runSearch(q),
    );
  }

  void _runSearch(String query) {
    final model = _model;
    if (model == null) return;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      _setMatches([], -1);
      return;
    }
    final out = <_Match>[];
    for (final para in model.allParagraphs()) {
      final text = para.plainText.toLowerCase();
      var i = text.indexOf(q);
      while (i >= 0) {
        out.add(_Match(para, i, i + q.length));
        if (out.length >= 5000) break;
        i = text.indexOf(q, i + q.length);
      }
      if (out.length >= 5000) break;
    }
    _setMatches(out, out.isEmpty ? -1 : 0);
    _revealMatch();
  }

  void _setMatches(List<_Match> matches, int index) {
    final hl = <DocParagraph, List<DocHighlight>>{};
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      (hl[m.paragraph] ??= []).add(
        DocHighlight(m.start, m.end, current: i == index),
      );
    }
    setState(() {
      _matches = matches;
      _matchIndex = index;
      _highlights = hl;
    });
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    final n = (_matchIndex + delta) % _matches.length;
    _setMatches(_matches, n < 0 ? n + _matches.length : n);
    _revealMatch();
  }

  void _revealMatch() {
    if (_matchIndex < 0 || _matchIndex >= _matches.length) return;
    final m = _matches[_matchIndex];
    final top = _topIndex[m.paragraph];
    if (top == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewController.reveal(top, paragraph: m.paragraph, offset: m.start);
    });
  }

  // ---------------------------------------------------------------------------
  // Editing

  bool get _dirty => _session?.dirty ?? false;

  /// What "Save" means here: replace the file, or — when that would lose
  /// content or the format can't be written — a copy or a new .docx.
  _SaveKind get _primarySave => _saveFormat == null
      ? _SaveKind.asDocx
      : (_overwriteAllowed ? _SaveKind.overwrite : _SaveKind.copy);

  String get _primarySaveLabel => switch (_primarySave) {
    _SaveKind.overwrite => 'Save',
    _SaveKind.copy => 'Save as copy',
    _SaveKind.asDocx => 'Save as .docx',
  };

  void _startEditing() {
    final model = _model;
    if (model == null || _partial) return;
    final session = DocEditorSession(model)..onDirty = () => setState(() {});
    _lastSaved = null;
    _editingDone = Completer<void>();
    setState(() {
      _session = session;
      _searchOpen = false;
    });
    final notes = <String>[
      if (session.hasPreservedObjects)
        'Tables, pictures and other objects are kept but can\'t be edited here.',
      if (_saveFormat == null) 'Your edits will be saved as a new .docx file.',
      if (_saveFormat != null && !_overwriteAllowed)
        'This file has headers, footers, notes, lists or fields this editor '
            'can\'t keep, so your edits will be saved as a copy.',
    ];
    if (notes.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(notes.join(' ')),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _finishEditing() async {
    final session = _session;
    if (session == null) return;
    if (session.dirty) {
      final choice = await askUnsavedChanges(
        context,
        saveLabel: _primarySaveLabel,
      );
      if (!mounted || choice == UnsavedChoice.cancel) return;
      if (choice == UnsavedChoice.save) {
        await _save(_primarySave);
        if (!mounted || session.dirty) return;
      }
    }
    final saved = _lastSaved;
    final savedFormat = _saveFormat;
    final changed = session.changed;
    final edited = changed && saved != null ? session.snapshot() : null;
    session.dispose();
    setState(() => _session = null);
    _editingDone?.complete();
    _editingDone = null;
    if (edited != null && savedFormat != null) {
      // Show exactly what is on disk now; later DOCX saves build on it.
      DocModel model;
      try {
        model = await parseDocumentInBackground(saved!, savedFormat);
        _originalBytes = saved;
      } catch (_) {
        // Keep the edits on screen; saves keep building on the bytes the
        // session started from, which [edited] still refers to.
        model = edited;
      }
      if (!mounted) return;
      _overwriteAllowed = !model.warnings.contains(DocModel.warnUnwritable);
      _setModel(model);
    }
  }

  Future<void> _save(_SaveKind kind) async {
    final session = _session;
    if (session == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final revision = session.revision;
      final edited = session.snapshot();
      final format = kind == _SaveKind.asDocx
          ? 'docx'
          : (_saveFormat ?? 'docx');
      final Uint8List out;
      if (format == 'rtf') {
        out = await _rtfInBackground(edited);
      } else {
        // The session's model was parsed from _originalBytes; it stays the
        // base for every save until the session ends.
        out = await _docxInBackground(
          edited,
          edited.docx != null ? _originalBytes : null,
        );
      }
      final File target;
      switch (kind) {
        case _SaveKind.overwrite:
          target = _file;
        case _SaveKind.copy:
          target = await uniqueSibling(_file, _ext, suffix: ' copy');
        case _SaveKind.asDocx:
          target = await uniqueSibling(_file, 'docx');
      }
      await writeFileSafely(target, out);
      if (!mounted) return;
      // Edits typed while saving aren't in [out].
      if (session.revision == revision) session.dirty = false;
      if (target.path != _file.path) _createdNewFile = true;
      if (kind == _SaveKind.asDocx) {
        // Continue working on the new .docx.
        _file = target;
        _saveFormat = 'docx';
        _overwriteAllowed = true;
      }
      if (kind != _SaveKind.copy) _lastSaved = out;
      setState(() {});
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${p.basename(target.path)}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onPop() async {
    if (_dirty) {
      final choice = await askUnsavedChanges(
        context,
        saveLabel: _primarySaveLabel,
      );
      if (!mounted || choice == UnsavedChoice.cancel) return;
      if (choice == UnsavedChoice.save) {
        await _save(_primarySave);
        if (!mounted || _dirty) return;
      }
    }
    if (mounted) Navigator.of(context).pop(_createdNewFile);
  }

  // ---------------------------------------------------------------------------
  // Menu actions

  final GlobalKey _moreKey = GlobalKey();

  /// Shares the file. iPad needs an anchor for the share popover: the More
  /// button the action came from, else the top-right corner.
  Future<void> _share() async {
    Rect origin;
    final box = _moreKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    } else {
      final size = MediaQuery.sizeOf(context);
      origin = Rect.fromLTWH(
        size.width - 56,
        MediaQuery.paddingOf(context).top,
        48,
        48,
      );
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(_file.path)], sharePositionOrigin: origin),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t share: $e')));
    }
  }

  Future<void> _convertToDocx() async {
    final model = _model;
    if (model == null || _partial) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final out = await _docxInBackground(
        model,
        model.docx != null ? _originalBytes : null,
      );
      final target = await uniqueSibling(_file, 'docx');
      await writeFileSafely(target, out);
      // Rebuild so PopScope routes Back through _onPop, which pops `true`
      // and makes the explorer list the new file.
      if (mounted) setState(() => _createdNewFile = true);
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${p.basename(target.path)}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t convert: $e')));
    }
  }

  void _showInfo() {
    final model = _model;
    if (model == null) return;
    final stats = DocStats.of(model);
    final size = _originalBytes?.length ?? 0;
    final pg = model.page;
    final pages = _layout?.complete == true ? _layout!.pages.length : null;
    String cm(double pt) => (pt / 72 * 2.54).toStringAsFixed(1);
    final rows = <(String, String)>[
      ('Name', p.basename(_file.path)),
      ('Format', _formatLabel(model.format)),
      ('Size', formatBytes(size)),
      if (pages != null) ('Pages', '$pages'),
      ('Words', '${stats.words}'),
      ('Characters', '${stats.characters}'),
      ('Characters (no spaces)', '${stats.charactersNoSpaces}'),
      ('Paragraphs', '${stats.paragraphs}'),
      if (stats.tables > 0) ('Tables', '${stats.tables}'),
      if (stats.images > 0) ('Pictures', '${stats.images}'),
      ('Page size', '${cm(pg.width)} × ${cm(pg.height)} cm'),
    ];
    ExplorerLiquidGlassBottomSheet.show<void>(
      context,
      maxHeightFraction: 0.6,
      child: Builder(
        builder: (context) {
          final fg = ClearGlassForeground.primaryText(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Document info',
                style: ClearGlassForeground.title(
                  context,
                ).copyWith(fontSize: 18),
              ),
              const SizedBox(height: 12),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 160,
                        child: Text(
                          r.$1,
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.7),
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          r.$2,
                          style: TextStyle(
                            color: fg,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _formatLabel(String f) => switch (f) {
    'docx' => 'Word document (.docx)',
    'doc' => 'Word 97–2003 document (.doc)',
    'rtf' => 'Rich Text Format (.rtf)',
    'odt' => 'OpenDocument Text (.odt)',
    'wps' => 'Works / WPS document',
    _ => 'Plain text',
  };

  void _showOutlineSheet() {
    final headings = _headings();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scroll) => _OutlineList(
          headings: headings,
          controller: scroll,
          onTap: (i, para) {
            Navigator.pop(sheet);
            _viewController.reveal(i, paragraph: para);
          },
        ),
      ),
    );
  }

  Future<void> _onMenu(String action) async {
    final model = _model;
    switch (action) {
      case 'info':
        _showInfo();
      case 'outline':
        _showOutlineSheet();
      case 'layout':
        setState(() => _printLayout = !(_printLayout ?? true));
      case 'dark':
        setState(() => _darkPage = !_darkPage);
      case 'copy':
        if (model == null) return;
        await Clipboard.setData(ClipboardData(text: model.plainText()));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Text copied')));
        }
      case 'share':
        await _share();
      case 'convert':
        await _convertToDocx();
      case 'open':
        await OpenFilex.open(_file.path);
    }
  }

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    final editing = _session != null;
    final compact = WindowSize.of(context).isCompact;
    _printLayout ??= true;
    return PopScope(
      canPop: !_dirty && !_createdNewFile,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPop();
      },
      child: ExplorerScaffold(
        title: p.basename(_file.path) + (_dirty ? ' •' : ''),
        trailing: editing
            ? _editActions(context)
            : _viewActions(context, compact),
        body: _body(context),
      ),
    );
  }

  Widget _viewActions(BuildContext context, bool compact) {
    final color = ClearGlassForeground.icon(context);
    final model = _model;
    // Not while only the first pages of a long document are in.
    final ready = model != null && _error == null && !_partial;
    final split = AdaptiveSplitView.isSplit(context);
    return ExplorerTopBar.actions(context, [
      if (ready)
        ExplorerTopBar.iconButton(
          context: context,
          icon: Icon(
            _searchOpen ? Icons.search_off : Icons.search,
            color: color,
          ),
          tooltip: 'Find',
          onPressed: _toggleSearch,
        ),
      if (ready)
        ExplorerTopBar.iconButton(
          context: context,
          icon: Icon(Icons.edit_outlined, color: color),
          tooltip: 'Edit',
          onPressed: _startEditing,
        ),
      if (ready)
        PopupMenuButton<String>(
          key: _moreKey,
          tooltip: 'More',
          icon: Icon(Icons.more_vert, color: color),
          onSelected: _onMenu,
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'info',
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Document info'),
              ),
            ),
            if (!split && _headings().isNotEmpty)
              const PopupMenuItem(
                value: 'outline',
                child: ListTile(
                  leading: Icon(Icons.toc),
                  title: Text('Outline'),
                ),
              ),
            CheckedPopupMenuItem(
              value: 'layout',
              checked: _printLayout ?? true,
              child: const Text('Print layout'),
            ),
            CheckedPopupMenuItem(
              value: 'dark',
              checked: _darkPage,
              child: const Text('Dark page'),
            ),
            const PopupMenuItem(
              value: 'copy',
              child: ListTile(
                leading: Icon(Icons.copy_all_outlined),
                title: Text('Copy text'),
              ),
            ),
            const PopupMenuItem(
              value: 'share',
              child: ListTile(
                leading: Icon(Icons.share_outlined),
                title: Text('Share'),
              ),
            ),
            if (model.format != 'docx')
              const PopupMenuItem(
                value: 'convert',
                child: ListTile(
                  leading: Icon(Icons.save_as_outlined),
                  title: Text('Save as .docx'),
                ),
              ),
            const PopupMenuItem(
              value: 'open',
              child: ListTile(
                leading: Icon(Icons.open_in_new),
                title: Text('Open with…'),
              ),
            ),
          ],
        ),
    ]);
  }

  Widget _editActions(BuildContext context) {
    final color = ClearGlassForeground.icon(context);
    final options = <(_SaveKind, String)>[
      if (_saveFormat != null && _overwriteAllowed)
        (_SaveKind.overwrite, 'Save'),
      if (_saveFormat != null) (_SaveKind.copy, 'Save as copy'),
      if (_saveFormat != 'docx') (_SaveKind.asDocx, 'Save as .docx'),
    ];
    final saveIcon = _saving
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(Icons.save_outlined, color: color);
    return ExplorerTopBar.actions(context, [
      if (options.length == 1)
        ExplorerTopBar.iconButton(
          context: context,
          icon: saveIcon,
          tooltip: options.first.$2,
          onPressed: _saving ? null : () => _save(options.first.$1),
        )
      else
        PopupMenuButton<_SaveKind>(
          tooltip: 'Save',
          enabled: !_saving,
          icon: saveIcon,
          onSelected: _save,
          itemBuilder: (context) => [
            for (final o in options)
              PopupMenuItem(value: o.$1, child: Text(o.$2)),
          ],
        ),
      ExplorerTopBar.iconButton(
        context: context,
        icon: Icon(Icons.check, color: color),
        tooltip: 'Done',
        onPressed: _saving ? null : _finishEditing,
      ),
    ]);
  }

  Widget _body(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    if (_loading) {
      // First frame: a page outline right away while the file is parsed.
      return _PageSkeleton(topPadding: top, darkPage: _darkPage);
    }
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: _ErrorView(
          message: _error!,
          onOpenWith: () => OpenFilex.open(_file.path),
        ),
      );
    }
    final session = _session;
    if (session != null) {
      return DocEditorView(
        session: session,
        images: _images!,
        topPadding: top,
        onLink: _openLink,
      );
    }

    final ctx = _ctx();
    final searchHeight = _searchOpen ? 60.0 : 0.0;
    Widget view;
    if (_printLayout ?? true) {
      final layout = _layout;
      view = layout == null || layout.pages.isEmpty
          ? _PageSkeleton(
              topPadding: top + searchHeight,
              page: _model!.page,
              progress: _layoutProgress,
              darkPage: _darkPage,
            )
          : DocPagesView(
              result: layout,
              ctx: ctx,
              controller: _viewController,
              topPadding: top + searchHeight,
            );
    } else {
      view = DocReflowView(
        model: _model!,
        ctx: ctx,
        controller: _viewController,
        topPadding: top + searchHeight,
      );
    }

    final content = Stack(
      children: [
        Positioned.fill(child: view),
        if (_searchOpen)
          Positioned(
            top: top,
            left: 8,
            right: 8,
            child: _SearchBar(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _step(1),
              count: _matches.length,
              index: _matchIndex,
              onPrev: () => _step(-1),
              onNext: () => _step(1),
              onClose: _toggleSearch,
            ),
          ),
      ],
    );

    final headings = _headings();
    if (headings.isEmpty || !AdaptiveSplitView.isSplit(context)) return content;
    return AdaptiveSplitView(
      secondaryWidth: 280,
      primary: content,
      secondary: Padding(
        padding: EdgeInsets.only(top: top),
        child: _OutlineList(
          headings: headings,
          onTap: (i, para) => _viewController.reveal(i, paragraph: para),
        ),
      ),
    );
  }
}

/// Shown from the very first frame until the first page is laid out: an
/// empty page of the document's size with placeholder text lines, placed
/// like the first page of [DocPagesView], so opening never starts on a bare
/// spinner.
class _PageSkeleton extends StatelessWidget {
  const _PageSkeleton({
    required this.topPadding,
    this.page = DocPageSetup.letter,
    this.progress = 0,
    this.darkPage = false,
  });

  final double topPadding;
  final DocPageSetup page;
  final double progress;
  final bool darkPage;

  // Line widths of a few paragraphs (fractions of the text width; 0 = gap).
  static const _pattern = [
    0.55, 0, 1.0, 1.0, 1.0, 0.7, 0, 1.0, 1.0, 0.85, 0, //
    1.0, 1.0, 1.0, 1.0, 0.4, 0, 0.45, 0, 1.0, 1.0, 0.9,
  ];

  @override
  Widget build(BuildContext context) {
    final shadow = Theme.of(context).brightness == Brightness.dark
        ? const Color(0x66000000)
        : const Color(0x33000000);
    final paper = darkPage ? const Color(0xFF1F1F22) : Colors.white;
    final ink = darkPage ? const Color(0x1FFFFFFF) : const Color(0x12000000);
    return LayoutBuilder(
      builder: (context, c) {
        final readable = math.min(c.maxWidth - 24, 900.0);
        final scale = math.max(0.05, readable / page.width);
        final w = page.width * scale;
        final h = page.height * scale;
        final lineGap = 11 * 1.9 * scale;
        final bottom = h - page.marginBottom * scale;
        final bars = <Widget>[];
        var y = page.marginTop * scale;
        for (var i = 0; y + lineGap < bottom; i++) {
          final f = _pattern[i % _pattern.length];
          if (f > 0) {
            bars.add(
              Positioned(
                left: page.marginLeft * scale,
                top: y,
                width: page.contentWidth * scale * f,
                height: lineGap * 0.45,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            );
          }
          y += lineGap;
        }
        return Stack(
          children: [
            Positioned(
              top: topPadding + 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: paper,
                    boxShadow: [
                      BoxShadow(
                        color: shadow,
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Stack(children: bars),
                ),
              ),
            ),
            Positioned(
              top: topPadding,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                value: progress > 0 ? progress : null,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onOpenWith});
  final String message;
  final VoidCallback onOpenWith;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onOpenWith,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open with another app'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.count,
    required this.index,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final int count;
  final int index;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Find in document',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  count == 0 ? '0/0' : '${index + 1}/$count',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            IconButton(
              tooltip: 'Previous',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: count == 0 ? null : onPrev,
            ),
            IconButton(
              tooltip: 'Next',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: count == 0 ? null : onNext,
            ),
            IconButton(
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _OutlineList extends StatelessWidget {
  const _OutlineList({
    required this.headings,
    required this.onTap,
    this.controller,
  });
  final List<(int, DocParagraph)> headings;
  final void Function(int index, DocParagraph paragraph) onTap;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(type: MaterialType.transparency, child: _list(theme));
  }

  Widget _list(ThemeData theme) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: headings.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Outline', style: theme.textTheme.titleSmall),
          );
        }
        final (index, para) = headings[i - 1];
        final level = para.headingLevel ?? 1;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(
            left: 16.0 + (level - 1) * 14,
            right: 12,
          ),
          title: Text(
            para.plainText.replaceAll('\uFFFC', '').trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: level == 1
                ? theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  )
                : theme.textTheme.bodyMedium,
          ),
          onTap: () => onTap(index, para),
        );
      },
    );
  }
}
