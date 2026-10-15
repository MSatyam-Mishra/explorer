import 'dart:io';

import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/features/viewer_image/image_codec.dart';
import 'package:explorer/features/viewer_image/screens/image_editor_screen.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';

/// Swipeable gallery of the images in a folder, with info and editing.
class ImageViewerScreen extends StatefulWidget {
  final File imageFile;

  const ImageViewerScreen({super.key, required this.imageFile});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  PageController? _pageController;
  List<File> _images = [];
  int _currentIndex = 0;
  bool _showInfo = false;
  bool _changed = false;
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _loadImages({String? focusPath}) async {
    List<File> images;
    try {
      images = (await widget.imageFile.parent.list().toList())
          .whereType<File>()
          .where((f) {
        final kind = FileTypes.kindOf(f.path);
        return kind == FileKind.image || kind == FileKind.rasterImage;
      }).toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    } catch (_) {
      images = [];
    }
    if (images.isEmpty) images = [widget.imageFile];
    final target = focusPath ?? widget.imageFile.path;
    final index = images.indexWhere((f) => f.path == target);
    if (!mounted) return;
    _pageController?.dispose();
    setState(() {
      _images = images;
      _currentIndex = index < 0 ? 0 : index;
      _pageController = PageController(initialPage: _currentIndex);
    });
  }

  File get _current => _images[_currentIndex];

  Future<void> _edit() async {
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => ImageEditorScreen(file: _current)),
    );
    if (saved == null || !mounted) return;
    _changed = true;
    imageCache.evict(FileImage(File(saved)));
    imageCache.clear();
    _reloadToken++;
    await _loadImages(focusPath: saved);
  }

  Future<void> _share() async {
    await SharePlus.instance.share(ShareParams(files: [XFile(_current.path)]));
  }

  @override
  Widget build(BuildContext context) {
    if (_images.isEmpty || _pageController == null) {
      return const ExplorerScaffold(
        backgroundColor: Colors.black,
        title: 'Photos',
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final iconColor = ClearGlassForeground.icon(context);
    final gallery = PhotoViewGallery.builder(
        key: ValueKey(_reloadToken),
        scrollPhysics: const BouncingScrollPhysics(),
        pageController: _pageController,
        itemCount: _images.length,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (context, event) =>
            const Center(child: CircularProgressIndicator()),
        builder: (context, index) {
          final file = _images[index];
          return PhotoViewGalleryPageOptions(
            imageProvider: ImageCodec.providerFor(file),
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4.0,
            heroAttributes: PhotoViewHeroAttributes(tag: file.path),
            errorBuilder: (context, error, stack) => _UnsupportedImage(
              file: file,
              error: error,
            ),
          );
        },
        onPageChanged: (index) => setState(() => _currentIndex = index),
    );

    final infoPane = _ImageInfoPane(
      key: ValueKey(_current.path),
      file: _current,
      onClose: () => setState(() => _showInfo = false),
    );

    final body = _showInfo && AdaptiveSplitView.isSplit(context, minWidthForSplit: 720)
        ? AdaptiveSplitView(
            minWidthForSplit: 720,
            secondaryOnLeading: false,
            secondaryWidth: 320,
            primary: gallery,
            secondary: Padding(
              padding: EdgeInsets.only(
                top: DockedGlossyTopBar.contentTopInset(context),
              ),
              child: infoPane,
            ),
          )
        : gallery;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: ExplorerScaffold(
        backgroundColor: Colors.black,
        title: '${_currentIndex + 1} / ${_images.length}  ·  ${p.basename(_current.path)}',
        trailing: ExplorerTopBar.actions(context, [
          ExplorerTopBar.iconButton(
            context: context,
            icon: Icon(Icons.edit_outlined, color: iconColor),
            tooltip: 'Edit',
            onPressed: _edit,
          ),
          ExplorerTopBar.iconButton(
            context: context,
            icon: Icon(Icons.share_outlined, color: iconColor),
            tooltip: 'Share',
            onPressed: _share,
          ),
          ExplorerTopBar.iconButton(
            context: context,
            icon: Icon(Icons.info_outline, color: iconColor),
            tooltip: 'Details',
            onPressed: () {
              if (AdaptiveSplitView.isSplit(context, minWidthForSplit: 720)) {
                setState(() => _showInfo = !_showInfo);
              } else {
                showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => FractionallySizedBox(
                    heightFactor: 0.6,
                    child: _ImageInfoPane(file: _current),
                  ),
                );
              }
            },
          ),
        ]),
        body: body,
      ),
    );
  }
}

class _UnsupportedImage extends StatelessWidget {
  const _UnsupportedImage({required this.file, required this.error});

  final File file;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64),
            const SizedBox(height: 12),
            Text(
              "This image format isn't supported on this device.",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageInfoPane extends StatefulWidget {
  const _ImageInfoPane({super.key, required this.file, this.onClose});

  final File file;
  final VoidCallback? onClose;

  @override
  State<_ImageInfoPane> createState() => _ImageInfoPaneState();
}

class _ImageInfoPaneState extends State<_ImageInfoPane> {
  Map<String, String>? _details;
  String? _dimensions;
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    (info, _) {
      if (mounted) {
        setState(() => _dimensions = '${info.image.width} × ${info.image.height}');
      }
    },
    onError: (_, _) {},
  );

  @override
  void initState() {
    super.initState();
    _stream = ImageCodec.providerFor(widget.file)
        .resolve(ImageConfiguration.empty)
      ..addListener(_listener);
    _load();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  Future<void> _load() async {
    final details = <String, String>{};
    try {
      final stat = await widget.file.stat();
      details['Name'] = p.basename(widget.file.path);
      details['Size'] = filesize(stat.size);
      details['Modified'] = DateFormat.yMMMd().add_jm().format(stat.modified);
      details['Folder'] = widget.file.parent.path;
      details.addAll(await ImageCodec.readExif(widget.file));
    } catch (_) {}
    if (mounted) setState(() => _details = details);
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: details == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Details', style: theme.textTheme.titleMedium),
                    ),
                    if (widget.onClose != null)
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: widget.onClose,
                      ),
                  ],
                ),
                for (final e in {
                  if (_dimensions != null) 'Dimensions': _dimensions!,
                  ...details,
                }.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.key, style: theme.textTheme.labelMedium),
                    subtitle: SelectableText(e.value),
                  ),
              ],
            ),
    );
  }
}
