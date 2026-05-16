import 'dart:io';

import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:path/path.dart' as p;

class ImageViewerScreen extends StatefulWidget {
  final File imageFile;

  const ImageViewerScreen({super.key, required this.imageFile});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late PageController _pageController;
  List<File> _images = [];
  bool _isLoading = true;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    try {
      final parentDir = widget.imageFile.parent;
      final entities = parentDir.listSync();
      final images = entities.whereType<File>().where((file) {
        final ext = p.extension(file.path).toLowerCase();
        return [
          '.jpg',
          '.jpeg',
          '.png',
          '.gif',
          '.bmp',
          '.webp',
          '.svg',
        ].contains(ext);
      }).toList();

      // Sort alphabetically to maintain order
      images.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );

      final initialIndex = images.indexWhere(
        (f) => f.path == widget.imageFile.path,
      );

      setState(() {
        _images = images;
        _currentIndex = initialIndex != -1 ? initialIndex : 0;
        _pageController = PageController(initialPage: _currentIndex);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading images: $e');
      setState(() {
        _images = [widget.imageFile];
        _pageController = PageController();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const ExplorerScaffold(
        backgroundColor: Colors.black,
        title: 'Photos',
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return ExplorerScaffold(
      backgroundColor: Colors.black,
      title: '${_currentIndex + 1} / ${_images.length}',
      body: PhotoViewGallery.builder(
        scrollPhysics: const BouncingScrollPhysics(),
        builder: (BuildContext context, int index) {
          return PhotoViewGalleryPageOptions(
            imageProvider: FileImage(_images[index]),
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3.0,
            heroAttributes: PhotoViewHeroAttributes(tag: _images[index].path),
          );
        },
        itemCount: _images.length,
        loadingBuilder: (context, event) =>
            const Center(child: CircularProgressIndicator()),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        pageController: _pageController,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}
