import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

Future<DocModel> _parseInBackground(Uint8List bytes, String ext) =>
    Isolate.run(() => parseAnyDocument(bytes, ext));

Future<Uint8List> _docxInBackground(DocModel model, Uint8List? original) =>
    Isolate.run(() => writeDocx(model, original: original));

Future<Uint8List> _rtfInBackground(DocModel model) => Isolate.run(() => writeRtf(model));

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

  /// Bytes of the document as opened; DOCX saves rebuild from this package.
  Uint8List? _originalBytes;
  DocModel? _model;
  DocImageCache? _images;
  String? _error;
  bool _loading = true;

  DocLayoutResult? _layout;
  double _layoutProgress = 0;
  int _layoutGen = 0;
  final DocViewController _viewController = DocViewController();
  Map<DocParagraph, int> _topIndex = {};

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

  /// Format future "Save" writes in, or null when the source can't be
  /// written faithfully (DOC, ODT, WPS, text → "Save as .docx").
  String? _saveFormat;
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
    _session?.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  String get _ext => p.extension(_file.path).toLowerCase().replaceFirst('.', '');

  // ---------------------------------------------------------------------------
  // Loading & layout

  Future<void> _load() async {
    try {
      final bytes = await _file.readAsBytes();
      final model = await _parseInBackground(bytes, _ext);
      if (!mounted) return;
      _originalBytes = bytes;
      _saveFormat = _overwriteFormatFor(model.format, _ext);
      _setModel(model);
      if (model.warnings.contains('plainText') && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Showing the text only — formatting in this file isn\'t supported.'),
        ));
      }
    } on DocumentEncryptedException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'This document is password-protected. Open it in Word or another '
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

  void _setModel(DocModel model) {
    setState(() {
      _model = model;
      _images = DocImageCache(model);
      _loading = false;
      _error = null;
      _layout = null;
      _layoutProgress = 0;
      _topIndex = _indexParagraphs(model);
      _matches = [];
      _matchIndex = -1;
      _highlights = const {};
    });
    if (_searchOpen && _searchCtrl.text.isNotEmpty) _runSearch(_searchCtrl.text);
    _relayout();
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

  Future<void> _relayout() async {
    final model = _model;
    if (model == null) return;
    final gen = ++_layoutGen;
    final result = await layoutDocument(
      model,
      DocRenderContext(model: model, images: _images!),
      onProgress: (v) {
        if (mounted && gen == _layoutGen) setState(() => _layoutProgress = v);
      },
      cancelled: () => !mounted || gen != _layoutGen,
    );
    if (!mounted || gen != _layoutGen) return;
    setState(() => _layout = result);
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
    _searchDebounce = Timer(const Duration(milliseconds: 250), () => _runSearch(q));
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
      (hl[m.paragraph] ??= []).add(DocHighlight(m.start, m.end, current: i == index));
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

  void _startEditing() {
    final model = _model;
    if (model == null) return;
    final session = DocEditorSession(model)..onDirty = () => setState(() {});
    setState(() {
      _session = session;
      _searchOpen = false;
    });
    final notes = <String>[
      if (session.hasPreservedObjects)
        'Tables, pictures and other objects are kept but can\'t be edited here.',
      if (_saveFormat == null) 'Your edits will be saved as a new .docx file.',
    ];
    if (notes.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(notes.join(' ')),
        duration: const Duration(seconds: 5),
      ));
    }
  }

  Future<void> _finishEditing() async {
    final session = _session;
    if (session == null) return;
    if (session.dirty) {
      final choice = await askUnsavedChanges(context,
          saveLabel: _saveFormat == null ? 'Save as .docx' : 'Save');
      if (!mounted || choice == UnsavedChoice.cancel) return;
      if (choice == UnsavedChoice.save) {
        await _save(_saveFormat == null ? _SaveKind.asDocx : _SaveKind.overwrite);
        if (!mounted || session.dirty) return;
      }
    }
    final saved = _lastSaved;
    final savedFormat = _saveFormat;
    final changed = session.changed;
    session.dispose();
    setState(() => _session = null);
    if (changed && saved != null && savedFormat != null) {
      // Show exactly what is on disk now.
      try {
        final model = await _parseInBackground(saved, savedFormat);
        if (mounted) _setModel(model);
      } catch (_) {}
    }
  }

  Future<void> _save(_SaveKind kind) async {
    final session = _session;
    if (session == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final edited = session.snapshot();
      final format = kind == _SaveKind.asDocx ? 'docx' : (_saveFormat ?? 'docx');
      final Uint8List out;
      if (format == 'rtf') {
        out = await _rtfInBackground(edited);
      } else {
        out = await _docxInBackground(edited, edited.docx != null ? _originalBytes : null);
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
      session.dirty = false;
      if (target.path != _file.path) _createdNewFile = true;
      if (kind == _SaveKind.asDocx) {
        // Continue working on the new .docx.
        _file = target;
        _saveFormat = 'docx';
      }
      if (kind != _SaveKind.copy) _lastSaved = out;
      setState(() {});
      messenger.showSnackBar(SnackBar(content: Text('Saved ${p.basename(target.path)}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onPop() async {
    if (_dirty) {
      final choice = await askUnsavedChanges(context,
          saveLabel: _saveFormat == null ? 'Save as .docx' : 'Save');
      if (!mounted || choice == UnsavedChoice.cancel) return;
      if (choice == UnsavedChoice.save) {
        await _save(_saveFormat == null ? _SaveKind.asDocx : _SaveKind.overwrite);
        if (!mounted || _dirty) return;
      }
    }
    if (mounted) Navigator.of(context).pop(_createdNewFile);
  }

  // ---------------------------------------------------------------------------
  // Menu actions

  Future<void> _convertToDocx() async {
    final model = _model;
    if (model == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final out = await _docxInBackground(model, model.docx != null ? _originalBytes : null);
      final target = await uniqueSibling(_file, 'docx');
      await writeFileSafely(target, out);
      _createdNewFile = true;
      messenger.showSnackBar(SnackBar(content: Text('Saved ${p.basename(target.path)}')));
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
    final pages = _layout?.pages.length;
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
      child: Builder(builder: (context) {
        final fg = ClearGlassForeground.primaryText(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Document info',
                style: ClearGlassForeground.title(context).copyWith(fontSize: 18)),
            const SizedBox(height: 12),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 160,
                      child: Text(r.$1,
                          style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 14)),
                    ),
                    Expanded(
                      child: Text(r.$2,
                          style: TextStyle(
                              color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
          ],
        );
      }),
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

  List<(int, DocParagraph)> _headings() {
    final model = _model;
    if (model == null) return const [];
    final out = <(int, DocParagraph)>[];
    for (var i = 0; i < model.blocks.length; i++) {
      final b = model.blocks[i];
      if (b is DocParagraph && b.headingLevel != null && b.plainText.trim().isNotEmpty) {
        out.add((i, b));
      }
    }
    return out;
  }

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
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Text copied')));
        }
      case 'share':
        await SharePlus.instance.share(ShareParams(files: [XFile(_file.path)]));
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
        trailing: editing ? _editActions(context) : _viewActions(context, compact),
        body: _body(context),
      ),
    );
  }

  Widget _viewActions(BuildContext context, bool compact) {
    final color = ClearGlassForeground.icon(context);
    final model = _model;
    final ready = model != null && _error == null;
    final split = AdaptiveSplitView.isSplit(context);
    return ExplorerTopBar.actions(context, [
      if (ready)
        ExplorerTopBar.iconButton(
          context: context,
          icon: Icon(_searchOpen ? Icons.search_off : Icons.search, color: color),
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
          tooltip: 'More',
          icon: Icon(Icons.more_vert, color: color),
          onSelected: _onMenu,
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'info', child: ListTile(leading: Icon(Icons.info_outline), title: Text('Document info'))),
            if (!split && _headings().isNotEmpty)
              const PopupMenuItem(value: 'outline', child: ListTile(leading: Icon(Icons.toc), title: Text('Outline'))),
            CheckedPopupMenuItem(value: 'layout', checked: _printLayout ?? true, child: const Text('Print layout')),
            CheckedPopupMenuItem(value: 'dark', checked: _darkPage, child: const Text('Dark page')),
            const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Copy text'))),
            const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_outlined), title: Text('Share'))),
            if (model.format != 'docx')
              const PopupMenuItem(value: 'convert', child: ListTile(leading: Icon(Icons.save_as_outlined), title: Text('Save as .docx'))),
            const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open with…'))),
          ],
        ),
    ]);
  }

  Widget _editActions(BuildContext context) {
    final color = ClearGlassForeground.icon(context);
    final options = <(_SaveKind, String)>[
      if (_saveFormat != null) (_SaveKind.overwrite, 'Save'),
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
            for (final o in options) PopupMenuItem(value: o.$1, child: Text(o.$2)),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: _ErrorView(message: _error!, onOpenWith: () => OpenFilex.open(_file.path)),
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
      view = layout == null
          ? _LayoutProgress(progress: _layoutProgress)
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

    final content = Stack(children: [
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
    ]);

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

class _LayoutProgress extends StatelessWidget {
  const _LayoutProgress({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 160,
          child: LinearProgressIndicator(value: progress > 0 ? progress : null),
        ),
        const SizedBox(height: 12),
        Text('Laying out pages…', style: Theme.of(context).textTheme.bodyMedium),
      ]),
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.description_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onOpenWith,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open with another app'),
          ),
        ]),
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
        child: Row(children: [
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
              child: Text(count == 0 ? '0/0' : '${index + 1}/$count',
                  style: Theme.of(context).textTheme.labelMedium),
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
        ]),
      ),
    );
  }
}

class _OutlineList extends StatelessWidget {
  const _OutlineList({required this.headings, required this.onTap, this.controller});
  final List<(int, DocParagraph)> headings;
  final void Function(int index, DocParagraph paragraph) onTap;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          contentPadding: EdgeInsets.only(left: 16.0 + (level - 1) * 14, right: 12),
          title: Text(
            para.plainText.replaceAll('\uFFFC', '').trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: level == 1
                ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                : theme.textTheme.bodyMedium,
          ),
          onTap: () => onTap(index, para),
        );
      },
    );
  }
}
