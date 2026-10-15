import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../slide_model.dart';
import 'slide_canvas.dart';

/// A slide preview card.
class SlideThumbnail extends StatelessWidget {
  const SlideThumbnail({
    super.key,
    required this.deck,
    required this.slide,
    required this.images,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final SlideDeck deck;
  final Slide slide;
  final SlideImageCache images;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label:
          'Slide ${slide.index + 1}${slide.title.isEmpty ? '' : ': ${slide.title}'}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${slide.index + 1}',
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: selected ? scheme.primary : scheme.outlineVariant,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Stack(
                      children: [
                        RepaintBoundary(
                          child: SlideFit(
                            deck: deck,
                            child: SlideCanvas(
                              deck: deck,
                              slide: slide,
                              images: images,
                              thumbnail: true,
                            ),
                          ),
                        ),
                        if (slide.hidden)
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.white.withValues(alpha: 0.55),
                              child: const Center(
                                child: Icon(
                                  Icons.visibility_off_outlined,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Fullscreen slideshow: immersive, tap right/left (or arrows/space) to
/// navigate. Pops with the index of the last slide shown.
class PresentationMode extends StatefulWidget {
  const PresentationMode({
    super.key,
    required this.deck,
    required this.images,
    required this.startIndex,
  });

  final SlideDeck deck;
  final SlideImageCache images;
  final int startIndex;

  @override
  State<PresentationMode> createState() => _PresentationModeState();
}

class _PresentationModeState extends State<PresentationMode> {
  late final PageController _pages;
  late int _index;
  bool _showHud = true;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _pages = PageController(initialPage: _index);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (Platform.isAndroid || Platform.isIOS) {
      final landscape = widget.deck.width >= widget.deck.height;
      SystemChrome.setPreferredOrientations(
        landscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      );
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showHud = false);
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setPreferredOrientations(const []);
    }
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.deck.slides.length - 1);
    if (next == _index) {
      if (delta > 0 && _index == widget.deck.slides.length - 1) _exit();
      return;
    }
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _exit() => Navigator.of(context).pop(_index);

  @override
  Widget build(BuildContext context) {
    final deck = widget.deck;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: KeyboardListener(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (e) {
            if (e is! KeyDownEvent) return;
            final k = e.logicalKey;
            if (k == LogicalKeyboardKey.arrowRight ||
                k == LogicalKeyboardKey.space ||
                k == LogicalKeyboardKey.pageDown ||
                k == LogicalKeyboardKey.enter) {
              _go(1);
            } else if (k == LogicalKeyboardKey.arrowLeft ||
                k == LogicalKeyboardKey.pageUp ||
                k == LogicalKeyboardKey.backspace) {
              _go(-1);
            } else if (k == LogicalKeyboardKey.escape) {
              _exit();
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final w = MediaQuery.sizeOf(context).width;
              if (d.globalPosition.dx < w * 0.3) {
                _go(-1);
              } else {
                _go(1);
              }
            },
            onLongPress: () => setState(() => _showHud = !_showHud),
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pages,
                  itemCount: deck.slides.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => Center(
                    child: SlideFit(
                      deck: deck,
                      child: SlideCanvas(
                        deck: deck,
                        slide: deck.slides[i],
                        images: widget.images,
                      ),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: _showHud ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                child: Text(
                                  '${_index + 1} / ${deck.slides.length}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Exit slideshow',
                              color: Colors.white,
                              icon: const Icon(Icons.close),
                              onPressed: _exit,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Edits the text of one shape: one line per paragraph. Returns the new
/// paragraphs or null when cancelled.
Future<List<String>?> showShapeTextEditor(
  BuildContext context, {
  required List<String> paragraphs,
  String? title,
}) {
  final controller = TextEditingController(text: paragraphs.join('\n'));
  return showDialog<List<String>>(
    context: context,
    builder: (d) {
      final width = MediaQuery.sizeOf(d).width;
      return AlertDialog(
        title: Text(title ?? 'Edit text'),
        content: SizedBox(
          width: width < 600 ? width : 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Each line is a paragraph. Formatting of unchanged text is kept.',
                style: Theme.of(d).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 3,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, controller.text.split('\n')),
            child: const Text('Apply'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

/// Asks for a slide number (1-based); returns a 0-based index.
Future<int?> showGoToSlide(BuildContext context, int count) {
  final controller = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (d) {
      void submit() {
        final n = int.tryParse(controller.text.trim());
        if (n != null && n >= 1 && n <= count) Navigator.pop(d, n - 1);
      }

      return AlertDialog(
        title: const Text('Go to slide'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: '1 – $count'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: submit, child: const Text('Go')),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}
