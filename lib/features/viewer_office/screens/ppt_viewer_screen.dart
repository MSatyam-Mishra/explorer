import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../common/office_files.dart';
import '../common/office_package.dart';
import '../slides/pptx_editor.dart';
import '../slides/pptx_parser.dart';
import '../slides/slide_loader.dart';
import '../slides/slide_model.dart';
import '../slides/widgets/slide_canvas.dart';
import '../slides/widgets/slide_widgets.dart';

Future<SlideDeck> _parseInBackground(Uint8List bytes, String ext) =>
    Isolate.run(() => parseAnyPresentation(bytes, ext));

Future<OfficePackage> _decodeInBackground(Uint8List bytes) =>
    Isolate.run(() => OfficePackage.decode(bytes));

Future<Uint8List> _encodeInBackground(OfficePackage pkg) =>
    Isolate.run(() => pkg.encode());

/// Viewer for presentations (PPTX family, PPT/PPS/POT, ODP/OTP) with
/// thumbnails, notes, a fullscreen slideshow and, for PPTX, editing (text,
/// duplicate/delete/reorder slides).
///
/// Pops with `true` when it created a new file (e.g. "Save as copy").
class PptViewerScreen extends StatefulWidget {
  const PptViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<PptViewerScreen> createState() => _PptViewerScreenState();
}

class _PptViewerScreenState extends State<PptViewerScreen> {
  late File _file;
  Uint8List? _bytes;
  SlideDeck? _deck;
  SlideImageCache? _images;
  String? _error;
  bool _loading = true;

  OfficePackage? _pkg;
  int _index = 0;
  PageController _pages = PageController();
  final ScrollController _thumbs = ScrollController();
  bool _showNotes = false;
  bool _zoomed = false;

  bool _editing = false;
  bool _dirty = false;
  bool _busy = false;
  bool _createdNewFile = false;
  String? _selectedShape;

  @override
  void initState() {
    super.initState();
    _file = widget.file;
    _load();
  }

  @override
  void dispose() {
    _pages.dispose();
    _thumbs.dispose();
    super.dispose();
  }

  String get _ext =>
      p.extension(_file.path).toLowerCase().replaceFirst('.', '');

  Future<void> _load() async {
    try {
      final bytes = await _file.readAsBytes();
      final deck = await _parseInBackground(bytes, _ext);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _setDeck(deck);
        _loading = false;
      });
      if (deck.slides.isEmpty) {
        setState(() => _error = 'This presentation has no slides.');
      }
    } on PresentationEncryptedException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'This presentation is password-protected. Open it in PowerPoint or another app that can decrypt it.';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'This file couldn\'t be read as a presentation.\n${e.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong while opening this presentation.';
      });
    }
  }

  void _setDeck(SlideDeck deck) {
    final old = _images;
    _deck = deck;
    _images = SlideImageCache(deck);
    if (old != null) _images!.adoptFrom(old);
    if (_index >= deck.slides.length) {
      _index = math.max(0, deck.slides.length - 1);
    }
  }

  void _goTo(int i, {bool animate = true}) {
    final deck = _deck;
    if (deck == null || deck.slides.isEmpty) return;
    final t = i.clamp(0, deck.slides.length - 1);
    if (_pages.hasClients) {
      if (animate && (t - _index).abs() <= 2) {
        _pages.animateToPage(
          t,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _pages.jumpToPage(t);
      }
    }
    setState(() {
      _index = t;
      _selectedShape = null;
    });
    _revealThumb(t);
  }

  void _revealThumb(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_thumbs.hasClients) return;
      final pos = _thumbs.position;
      final extent = _thumbExtent;
      if (extent <= 0) return;
      final start = i * extent;
      final end = start + extent;
      double? target;
      if (start < pos.pixels) target = start - extent * 0.3;
      if (end > pos.pixels + pos.viewportDimension) {
        target = end - pos.viewportDimension + extent * 0.3;
      }
      if (target != null) {
        _thumbs.animateTo(
          target.clamp(0, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  double _thumbExtent = 0;

  // ---------------------------------------------------------------------------
  // Editing

  bool get _canEdit => _deck?.format == 'pptx';

  Future<void> _startEditing() async {
    if (!_canEdit || _bytes == null) return;
    setState(() => _busy = true);
    try {
      _pkg ??= await _decodeInBackground(_bytes!);
      if (!mounted) return;
      setState(() => _editing = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tap a text box to edit it. Use the slide menu to duplicate, delete or move slides.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Can\'t edit this file: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs an edit on the package and re-reads the deck from it.
  Future<void> _apply(
    String? Function(PptxEditor editor) op, {
    int Function(SlideDeck deck, String? result)? focus,
  }) async {
    final pkg = _pkg;
    if (pkg == null || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = op(PptxEditor(pkg));
      // Parsing the in-memory package reuses media bytes, so decoded images
      // stay cached.
      final deck = PptxParser(pkg).parse();
      if (!mounted) return;
      final target = focus?.call(deck, result) ?? _index;
      setState(() {
        _setDeck(deck);
        _dirty = true;
      });
      _pages.dispose();
      _pages = PageController(
        initialPage: target.clamp(0, math.max(0, deck.slides.length - 1)),
      );
      setState(() {
        _index = target.clamp(0, math.max(0, deck.slides.length - 1));
        _selectedShape = null;
      });
      _revealThumb(_index);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is StateError ? e.message : 'Couldn\'t apply the change: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editShape(SlideAutoShape shape) async {
    final deck = _deck;
    final pkg = _pkg;
    if (deck == null || pkg == null) return;
    final slide = deck.slides[_index];
    final part = slide.partName;
    final id = shape.id;
    if (part == null || id == null) return;
    setState(() => _selectedShape = id);
    final paragraphs = PptxEditor(pkg).shapeParagraphs(part, id);
    if (paragraphs == null) return;
    final result = await showShapeTextEditor(
      context,
      paragraphs: paragraphs,
      title: shape.placeholder == 'title' || shape.placeholder == 'ctrTitle'
          ? 'Edit title'
          : 'Edit text',
    );
    if (!mounted) return;
    if (result == null) {
      setState(() => _selectedShape = null);
      return;
    }
    await _apply((ed) {
      ed.setShapeText(part, id, result);
      return null;
    });
  }

  Future<void> _duplicate(int index) async {
    final rel = _deck?.slides[index].relId;
    if (rel == null) return;
    await _apply(
      (ed) => ed.duplicateSlide(rel),
      focus: (deck, newRel) => deck.slides.indexWhere((s) => s.relId == newRel),
    );
  }

  Future<void> _delete(int index) async {
    final deck = _deck;
    final rel = deck?.slides[index].relId;
    if (deck == null || rel == null) return;
    if (deck.slides.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A presentation needs at least one slide.'),
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete slide ${index + 1}?'),
        content: const Text('The slide and its speaker notes will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _apply((ed) {
      ed.deleteSlide(rel);
      return null;
    }, focus: (deck, _) => math.min(index, deck.slides.length - 1));
  }

  Future<void> _move(int from, int to) async {
    final deck = _deck;
    if (deck == null || to < 0 || to >= deck.slides.length || from == to) {
      return;
    }
    await _apply((ed) {
      ed.moveSlide(from, to);
      return null;
    }, focus: (_, _) => to);
  }

  Future<void> _save({required bool copy}) async {
    final pkg = _pkg;
    if (pkg == null || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _encodeInBackground(pkg);
      final target = copy
          ? await uniqueSibling(_file, _ext, suffix: ' copy')
          : _file;
      await writeFileSafely(target, bytes);
      if (!mounted) return;
      setState(() {
        if (!copy) {
          _dirty = false;
          _bytes = bytes;
        } else {
          _createdNewFile = true;
        }
      });
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${p.basename(target.path)}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmLeaveEditing() async {
    if (!_dirty) return true;
    final choice = await askUnsavedChanges(context);
    if (!mounted || choice == UnsavedChoice.cancel) return false;
    if (choice == UnsavedChoice.save) {
      await _save(copy: false);
      return !_dirty;
    }
    // Discard: reload the file as it is on disk.
    _pkg = null;
    _dirty = false;
    final bytes = _bytes;
    if (bytes != null) {
      final deck = await _parseInBackground(bytes, _ext);
      if (mounted) setState(() => _setDeck(deck));
    }
    return true;
  }

  Future<void> _finishEditing() async {
    if (!await _confirmLeaveEditing()) return;
    if (mounted) {
      setState(() {
        _editing = false;
        _selectedShape = null;
      });
    }
  }

  Future<void> _onPop() async {
    if (_dirty && !await _confirmLeaveEditing()) return;
    if (mounted) Navigator.of(context).pop(_createdNewFile);
  }

  // ---------------------------------------------------------------------------
  // Actions

  Future<void> _present() async {
    final deck = _deck;
    final images = _images;
    if (deck == null || images == null) return;
    final last = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            PresentationMode(deck: deck, images: images, startIndex: _index),
      ),
    );
    if (last != null && mounted) _goTo(last, animate: false);
  }

  void _showInfo() {
    final deck = _deck;
    if (deck == null) return;
    String cm(double pt) => (pt / 72 * 2.54).toStringAsFixed(1);
    final notes = deck.slides.where((s) => s.notes.isNotEmpty).length;
    final rows = <(String, String)>[
      ('Name', p.basename(_file.path)),
      (
        'Format',
        switch (deck.format) {
          'pptx' => 'PowerPoint presentation',
          'ppt' => 'PowerPoint 97–2003 presentation (view only)',
          _ => 'OpenDocument presentation (view only)',
        },
      ),
      ('Size', formatBytes(_bytes?.length ?? 0)),
      ('Slides', '${deck.slides.length}'),
      ('Hidden slides', '${deck.slides.where((s) => s.hidden).length}'),
      ('Slides with notes', '$notes'),
      ('Slide size', '${cm(deck.width)} × ${cm(deck.height)} cm'),
    ];
    ExplorerLiquidGlassBottomSheet.show<void>(
      context,
      maxHeightFraction: 0.55,
      child: Builder(
        builder: (context) {
          final fg = ClearGlassForeground.primaryText(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Presentation info',
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
                        width: 150,
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

  Future<void> _askGoTo() async {
    final deck = _deck;
    if (deck == null) return;
    final i = await showGoToSlide(context, deck.slides.length);
    if (i != null && mounted) _goTo(i, animate: false);
  }

  Future<void> _onMenu(String action) async {
    switch (action) {
      case 'goto':
        await _askGoTo();
      case 'info':
        _showInfo();
      case 'notes':
        setState(() => _showNotes = !_showNotes);
      case 'share':
        await SharePlus.instance.share(ShareParams(files: [XFile(_file.path)]));
      case 'open':
        await OpenFilex.open(_file.path);
    }
  }

  void _openLink(String url) => showLinkSheet(context, url);

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty && !_createdNewFile,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPop();
      },
      child: ExplorerScaffold(
        title: p.basename(_file.path) + (_dirty ? ' •' : ''),
        trailing: _deck == null || _error != null
            ? null
            : (_editing ? _editActions(context) : _viewActions(context)),
        body: _body(context),
      ),
    );
  }

  Widget _viewActions(BuildContext context) {
    final color = ClearGlassForeground.icon(context);
    return ExplorerTopBar.actions(context, [
      ExplorerTopBar.iconButton(
        context: context,
        icon: Icon(Icons.slideshow_outlined, color: color),
        tooltip: 'Present',
        onPressed: _present,
      ),
      if (_canEdit)
        ExplorerTopBar.iconButton(
          context: context,
          icon: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              : Icon(Icons.edit_outlined, color: color),
          tooltip: 'Edit',
          onPressed: _busy ? null : _startEditing,
        ),
      PopupMenuButton<String>(
        tooltip: 'More',
        icon: Icon(Icons.more_vert, color: color),
        onSelected: _onMenu,
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'goto',
            child: ListTile(
              leading: Icon(Icons.pin_outlined),
              title: Text('Go to slide'),
            ),
          ),
          CheckedPopupMenuItem(
            value: 'notes',
            checked: _showNotes,
            child: const Text('Speaker notes'),
          ),
          const PopupMenuItem(
            value: 'info',
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Presentation info'),
            ),
          ),
          const PopupMenuItem(
            value: 'share',
            child: ListTile(
              leading: Icon(Icons.share_outlined),
              title: Text('Share'),
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
    return ExplorerTopBar.actions(context, [
      PopupMenuButton<bool>(
        tooltip: 'Save',
        enabled: !_busy,
        icon: _busy
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : Icon(Icons.save_outlined, color: color),
        onSelected: (copy) => _save(copy: copy),
        itemBuilder: (context) => const [
          PopupMenuItem(value: false, child: Text('Save')),
          PopupMenuItem(value: true, child: Text('Save as copy')),
        ],
      ),
      ExplorerTopBar.iconButton(
        context: context,
        icon: Icon(Icons.check, color: color),
        tooltip: 'Done',
        onPressed: _busy ? null : _finishEditing,
      ),
    ]);
  }

  Widget _body(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final deck = _deck;
    if (_error != null || deck == null) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.slideshow_outlined,
                  size: 56,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  _error ?? 'Nothing to show.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => OpenFilex.open(_file.path),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open with another app'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final split = AdaptiveSplitView.isSplit(context);
    final main = _mainArea(context, deck);
    if (split) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: AdaptiveSplitView(
          secondaryWidth: 240,
          secondary: _thumbnailList(context, deck, Axis.vertical),
          primary: main,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        children: [
          Expanded(child: main),
          SizedBox(
            height: 92,
            child: _thumbnailList(context, deck, Axis.horizontal),
          ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }

  Widget _mainArea(BuildContext context, SlideDeck deck) {
    final slide = deck.slides[_index.clamp(0, deck.slides.length - 1)];
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pages,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
            itemCount: deck.slides.length,
            onPageChanged: (i) {
              setState(() {
                _index = i;
                _selectedShape = null;
                _zoomed = false;
              });
              _revealThumb(i);
            },
            itemBuilder: (context, i) => _ZoomableSlide(
              onZoomChanged: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x40000000),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: SlideFit(
                      deck: deck,
                      child: SlideCanvas(
                        deck: deck,
                        slide: deck.slides[i],
                        images: _images!,
                        onShapeTap: _editing && i == _index ? _editShape : null,
                        onLink: _openLink,
                        selectedShapeId: i == _index ? _selectedShape : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_showNotes)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.25,
            ),
            child: Material(
              color: scheme.surfaceContainerHigh,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Speaker notes',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.primary),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        slide.notes.isEmpty
                            ? 'No notes for this slide.'
                            : slide.notes,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: slide.notes.isEmpty
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        _bottomBar(context, deck),
      ],
    );
  }

  Widget _bottomBar(BuildContext context, SlideDeck deck) {
    final scheme = Theme.of(context).colorScheme;
    final n = deck.slides.length;
    return Material(
      color: scheme.surfaceContainer.withValues(alpha: 0.95),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous slide',
              icon: const Icon(Icons.chevron_left),
              onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
            ),
            TextButton(onPressed: _askGoTo, child: Text('${_index + 1} / $n')),
            IconButton(
              tooltip: 'Next slide',
              icon: const Icon(Icons.chevron_right),
              onPressed: _index < n - 1 ? () => _goTo(_index + 1) : null,
            ),
            const Spacer(),
            IconButton(
              tooltip: _showNotes ? 'Hide notes' : 'Show notes',
              isSelected: _showNotes,
              icon: const Icon(Icons.sticky_note_2_outlined),
              selectedIcon: const Icon(Icons.sticky_note_2),
              onPressed: () => setState(() => _showNotes = !_showNotes),
            ),
            if (_editing)
              _slideMenu(
                _index,
                n,
                icon: const Icon(Icons.view_carousel_outlined),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _slideMenu(int index, int count, {Widget? icon}) {
    return PopupMenuButton<String>(
      tooltip: 'Slide actions',
      enabled: !_busy,
      icon: icon ?? const Icon(Icons.more_vert, size: 18),
      onSelected: (a) {
        switch (a) {
          case 'dup':
            _duplicate(index);
          case 'del':
            _delete(index);
          case 'up':
            _move(index, index - 1);
          case 'down':
            _move(index, index + 1);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'dup',
          child: ListTile(
            leading: Icon(Icons.copy_outlined),
            title: Text('Duplicate slide'),
          ),
        ),
        PopupMenuItem(
          value: 'up',
          enabled: index > 0,
          child: const ListTile(
            leading: Icon(Icons.arrow_upward),
            title: Text('Move earlier'),
          ),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: index < count - 1,
          child: const ListTile(
            leading: Icon(Icons.arrow_downward),
            title: Text('Move later'),
          ),
        ),
        PopupMenuItem(
          value: 'del',
          enabled: count > 1,
          child: const ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Delete slide'),
          ),
        ),
      ],
    );
  }

  Widget _thumbnailList(BuildContext context, SlideDeck deck, Axis axis) {
    final vertical = axis == Axis.vertical;
    return LayoutBuilder(
      builder: (context, c) {
        // Fixed extents so the current slide can be scrolled into view.
        final extent = vertical
            ? (c.maxWidth - 44) / deck.aspect + 8
            : (c.maxHeight - 8) * deck.aspect + 36;
        _thumbExtent = extent;
        Widget item(BuildContext context, int i) {
          final slide = deck.slides[i];
          final thumb = SlideThumbnail(
            key: ValueKey('${slide.relId ?? slide.index}-$i'),
            deck: deck,
            slide: slide,
            images: _images!,
            selected: i == _index,
            onTap: () => _goTo(i),
            trailing: _editing && vertical
                ? _slideMenu(i, deck.slides.length)
                : null,
          );
          return SizedBox(
            key: ValueKey('thumb-${slide.relId ?? i}'),
            width: vertical ? null : extent,
            height: vertical ? extent : null,
            child: thumb,
          );
        }

        return Material(
          type: MaterialType.transparency,
          child: _thumbnailScroller(deck, axis, extent, item),
        );
      },
    );
  }

  Widget _thumbnailScroller(
    SlideDeck deck,
    Axis axis,
    double extent,
    Widget Function(BuildContext, int) item,
  ) {
    if (_editing) {
      return ReorderableListView.builder(
        scrollController: _thumbs,
        scrollDirection: axis,
        padding: const EdgeInsets.all(4),
        itemCount: deck.slides.length,
        buildDefaultDragHandles: true,
        onReorderItem: (from, to) => _move(from, to),
        itemBuilder: item,
      );
    }
    return ListView.builder(
      controller: _thumbs,
      scrollDirection: axis,
      padding: const EdgeInsets.all(4),
      itemExtent: extent,
      itemCount: deck.slides.length,
      itemBuilder: item,
    );
  }
}

/// Pinch-to-zoom wrapper that tells the pager when it's zoomed in so swipes
/// pan the slide instead of changing pages.
class _ZoomableSlide extends StatefulWidget {
  const _ZoomableSlide({required this.child, required this.onZoomChanged});
  final Widget child;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableSlide> createState() => _ZoomableSlideState();
}

class _ZoomableSlideState extends State<_ZoomableSlide> {
  final TransformationController _t = TransformationController();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () {
        _t.value = Matrix4.identity();
        widget.onZoomChanged(false);
      },
      child: InteractiveViewer(
        transformationController: _t,
        minScale: 1,
        maxScale: 5,
        onInteractionEnd: (_) =>
            widget.onZoomChanged(_t.value.getMaxScaleOnAxis() > 1.01),
        child: widget.child,
      ),
    );
  }
}
