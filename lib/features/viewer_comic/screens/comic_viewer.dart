import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/formats/archive_backend.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/bookmark_service.dart';
import 'package:explorer/features/viewer_archive/archive_ui_utils.dart';
import 'package:explorer/features/viewer_archive/widgets/archive_dialogs.dart';
import 'package:explorer/features/viewer_comic/comic_book.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

enum _Layout { auto, single, double }

/// Reads CBZ/CBR/CB7/CBT comics (any archive with images, detected by
/// content): lazy page loading, pinch zoom, swipe/tap navigation, page
/// slider, right-to-left mode and two-page spreads on wide screens.
class ComicViewerScreen extends StatefulWidget {
  final File comicFile;

  const ComicViewerScreen({super.key, required this.comicFile});

  @override
  State<ComicViewerScreen> createState() => _ComicViewerScreenState();
}

class _ComicViewerScreenState extends State<ComicViewerScreen> {
  late final ComicBook _book = ComicBook(widget.comicFile);
  PageController? _controller;
  bool? _controllerDouble;

  bool _rtl = false;
  _Layout _layout = _Layout.auto;
  bool _chrome = true;
  int _page = 0;
  int? _savedPage;
  bool _restored = false;
  bool _askingPassword = false;
  Timer? _saveTimer;
  final _focusNode = FocusNode();

  String get _name => p.basename(widget.comicFile.path);

  @override
  void initState() {
    super.initState();
    _book.addListener(_onBook);
    _book.open();
    BookmarkService()
        .getLastReadPosition(widget.comicFile.path)
        .timeout(const Duration(seconds: 2))
        .then<void>((v) {
          _savedPage = v is int ? v : int.tryParse('$v');
        })
        .catchError((Object _) {})
        .whenComplete(() {
          _bookmarkLoaded = true;
          if (mounted) setState(_maybeRestore);
        });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePosition();
    _book.removeListener(_onBook);
    _book.dispose();
    _controller?.dispose();
    _focusNode.dispose();
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _onBook() {
    if (!mounted) return;
    final err = _book.error;
    if (err != null &&
        (err.kind == ArcErrorKind.needPassword ||
            err.kind == ArcErrorKind.wrongPassword) &&
        !_askingPassword) {
      _askPassword(err);
    }
    _maybeRestore();
    setState(() {});
  }

  Future<void> _askPassword(ArcException err) async {
    _askingPassword = true;
    final pw = await showArchivePasswordDialog(
      context,
      archiveName: _name,
      wrongPassword: err.kind == ArcErrorKind.wrongPassword,
      detail: err.message,
    );
    _askingPassword = false;
    if (pw != null && mounted) _book.open(password: pw);
  }

  void _maybeRestore() {
    if (_restored || !_bookmarkLoaded || _book.loading || _book.pages.isEmpty) {
      return;
    }
    _restored = true;
    final saved = _savedPage;
    if (saved != null && saved > 0 && saved < _book.pages.length) {
      _page = saved;
      _retireController();
    }
    _book.focus(_page, visible: _isDouble ? 2 : 1);
  }

  bool _bookmarkLoaded = false;

  /// Drops the page controller after the frame (a gallery may still be
  /// attached to it during this one).
  void _retireController() {
    final c = _controller;
    _controller = null;
    _controllerDouble = null;
    if (c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    }
  }

  void _savePosition() {
    if (_book.pages.isEmpty) return;
    BookmarkService()
        .saveLastReadPosition(widget.comicFile.path, _page)
        .catchError((Object _) {});
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  bool _isDouble = false;

  bool _computeDouble(BuildContext context) {
    switch (_layout) {
      case _Layout.single:
        return false;
      case _Layout.double:
        return true;
      case _Layout.auto:
        final size = MediaQuery.sizeOf(context);
        final fold = FoldInfo.of(context);
        if (fold != null && fold.isVertical) return true;
        return size.width > size.height && size.width >= 600;
    }
  }

  List<List<int>> _spreads(int count, bool dbl) {
    if (!dbl) return [for (var i = 0; i < count; i++) [i]];
    final out = <List<int>>[];
    if (count > 0) out.add([0]); // the cover stands alone
    for (var i = 1; i < count; i += 2) {
      out.add(i + 1 < count ? [i, i + 1] : [i]);
    }
    return out;
  }

  int _spreadOf(int page, bool dbl) => dbl ? (page == 0 ? 0 : (page + 1) ~/ 2) : page;

  PageController _controllerFor(bool dbl) {
    if (_controller == null || _controllerDouble != dbl) {
      _retireController();
      _controller = PageController(initialPage: _spreadOf(_page, dbl));
      _controllerDouble = dbl;
    }
    return _controller!;
  }

  void _go(int delta) {
    final c = _controller;
    if (c == null || !c.hasClients) return;
    final count = _spreads(_book.pages.length, _isDouble).length;
    final current = c.page?.round() ?? 0;
    final target = (current + delta).clamp(0, count - 1);
    if (target == current) return;
    c.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _jumpToSpread(int spread) {
    final c = _controller;
    if (c == null || !c.hasClients) return;
    c.jumpToPage(spread);
  }

  void _onSpreadChanged(int spread, List<List<int>> spreads) {
    final s = spreads[spread];
    setState(() => _page = s.first);
    _book.focus(s.first, visible: s.length);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _savePosition);
  }

  void _setChrome(bool visible) {
    setState(() => _chrome = visible);
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(
        visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      );
    }
  }

  void _onTapUp(BuildContext context, TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.globalPosition.dx;
    if (x < width * 0.3) {
      _go(_rtl ? 1 : -1);
    } else if (x > width * 0.7) {
      _go(_rtl ? -1 : 1);
    } else {
      _setChrome(!_chrome);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final dbl = _computeDouble(context);
    if (dbl != _isDouble) {
      _isDouble = dbl;
      if (_book.pages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _book.focus(_page, visible: dbl ? 2 : 1),
        );
      }
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _go(_rtl ? -1 : 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _go(_rtl ? 1 : -1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.space): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _jumpToSpread(0),
        const SingleActivator(LogicalKeyboardKey.end): () => _jumpToSpread(
          _spreads(_book.pages.length, _isDouble).length - 1,
        ),
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(child: _content(context)),
              _topBar(context),
              if (_book.pages.isNotEmpty) _bottomBar(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final err = _book.error;
    if (err != null) return _errorView(context, err);
    if (_book.loading || (_book.pages.isNotEmpty && !_restored)) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 16),
            Text('Opening comic…', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    final spreads = _spreads(_book.pages.length, _isDouble);
    final controller = _controllerFor(_isDouble);
    final mq = MediaQuery.of(context);
    final maxPx = (math.max(mq.size.width, mq.size.height) *
            mq.devicePixelRatio *
            2)
        .clamp(1024, 4096)
        .round();
    return PhotoViewGallery.builder(
      key: ValueKey('gallery-$_isDouble'),
      pageController: controller,
      reverse: _rtl,
      itemCount: spreads.length,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      onPageChanged: (i) => _onSpreadChanged(i, spreads),
      builder: (context, i) {
        final spread = spreads[i];
        final pages = _rtl ? spread.reversed.toList() : spread;
        Widget child;
        if (pages.length == 1) {
          child = _ComicPage(
            book: _book,
            index: pages.first,
            maxPx: maxPx,
            alignment: Alignment.center,
          );
        } else {
          child = Row(
            children: [
              Expanded(
                child: _ComicPage(
                  book: _book,
                  index: pages[0],
                  maxPx: maxPx,
                  alignment: Alignment.centerRight,
                ),
              ),
              Expanded(
                child: _ComicPage(
                  book: _book,
                  index: pages[1],
                  maxPx: maxPx,
                  alignment: Alignment.centerLeft,
                ),
              ),
            ],
          );
        }
        return PhotoViewGalleryPageOptions.customChild(
          child: child,
          minScale: PhotoViewComputedScale.contained,
          initialScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.contained * 5,
          onTapUp: (context, details, _) => _onTapUp(context, details),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    final count = _book.pages.length;
    final spread = _spreads(count, _isDouble);
    final current = count == 0 ? null : spread[_spreadOf(_page, _isDouble).clamp(0, spread.length - 1)];
    final label = current == null
        ? _book.formatLabel
        : current.length == 2
        ? 'Pages ${current[0] + 1}–${current[1] + 1} of $count'
        : 'Page ${current[0] + 1} of $count';
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      top: _chrome || _book.error != null || _book.loading ? 0 : -120,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  tooltip: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (label.isNotEmpty)
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _rtl ? 'Reading right to left' : 'Reading left to right',
                  icon: Icon(
                    _rtl
                        ? Icons.format_textdirection_r_to_l
                        : Icons.format_textdirection_l_to_r,
                    color: Colors.white,
                  ),
                  onPressed: count == 0 ? null : () => setState(() => _rtl = !_rtl),
                ),
                PopupMenuButton<Object>(
                  tooltip: 'Page layout',
                  icon: Icon(
                    _isDouble ? Icons.auto_stories : Icons.crop_portrait,
                    color: Colors.white,
                  ),
                  onSelected: (v) {
                    if (v is _Layout) {
                      setState(() {
                        _layout = v;
                        _retireController();
                      });
                    } else if (v == 'external') {
                      FileOpener.openExternally(context, widget.comicFile);
                    }
                  },
                  itemBuilder: (context) => [
                    for (final (value, text) in [
                      (_Layout.auto, 'Automatic'),
                      (_Layout.single, 'Single page'),
                      (_Layout.double, 'Two pages'),
                    ])
                      CheckedPopupMenuItem<Object>(
                        value: value,
                        checked: _layout == value,
                        child: Text(text),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem<Object>(
                      value: 'external',
                      child: Text('Open with another app'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final spreads = _spreads(_book.pages.length, _isDouble);
    final current = _spreadOf(_page, _isDouble).clamp(0, spreads.length - 1);
    final waiting = _book.sequential && _book.unpacked < _book.pages.length;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      bottom: _chrome ? 0 : -140,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (waiting)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Unpacking pages… ${_book.unpacked} of ${_book.pages.length}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                Row(
                  children: [
                    Text(
                      '${spreads[current].first + 1}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Expanded(
                      child: Directionality(
                        textDirection:
                            _rtl ? TextDirection.rtl : TextDirection.ltr,
                        child: spreads.length > 1
                            ? Slider(
                                value: current.toDouble(),
                                min: 0,
                                max: (spreads.length - 1).toDouble(),
                                divisions: spreads.length - 1,
                                label: '${spreads[current].first + 1}',
                                onChanged: (v) => _jumpToSpread(v.round()),
                              )
                            : const SizedBox(height: 48),
                      ),
                    ),
                    Text(
                      '${_book.pages.length}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView(BuildContext context, ArcException err) {
    final needsPassword = err.kind == ArcErrorKind.needPassword ||
        err.kind == ArcErrorKind.wrongPassword;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                needsPassword ? Icons.lock_outline : Icons.menu_book_outlined,
                size: 56,
                color: Colors.white54,
              ),
              const SizedBox(height: 16),
              Text(
                errorTitle(err.kind),
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(height: 8),
              Text(
                err.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (needsPassword)
                    FilledButton.icon(
                      onPressed: () => _askPassword(err),
                      icon: const Icon(Icons.key),
                      label: const Text('Enter password'),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: () => _book.open(password: _book.password),
                      child: const Text('Try again'),
                    ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () =>
                        FileOpener.openExternally(context, widget.comicFile),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open with another app'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One page image, loaded on demand.
class _ComicPage extends StatelessWidget {
  const _ComicPage({
    required this.book,
    required this.index,
    required this.maxPx,
    required this.alignment,
  });

  final ComicBook book;
  final int index;
  final int maxPx;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ComicPageState>(
      valueListenable: book.page(index),
      builder: (context, state, _) {
        ImageProvider? provider;
        if (state.bytes != null) {
          provider = MemoryImage(state.bytes!);
        } else if (state.file != null) {
          provider = FileImage(state.file!);
        }
        if (provider != null) {
          return Image(
            image: ResizeImage(
              provider,
              width: maxPx,
              height: maxPx,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            alignment: alignment,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => _message(
              Icons.broken_image_outlined,
              'Page ${index + 1} can\'t be displayed.',
            ),
          );
        }
        final err = state.error;
        if (err != null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _message(Icons.broken_image_outlined, err.message),
                TextButton(
                  onPressed: () => book.retry(index),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white54,
                ),
              ),
              if (state.waiting) ...[
                const SizedBox(height: 12),
                Text(
                  'Unpacking… ${book.unpacked} of ${book.pages.length} pages ready',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _message(IconData icon, String text) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white38, size: 48),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
      ],
    ),
  );
}
