import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:path/path.dart' as p;

class ComicViewerScreen extends StatefulWidget {
  final File comicFile;

  const ComicViewerScreen({super.key, required this.comicFile});

  @override
  State<ComicViewerScreen> createState() => _ComicViewerScreenState();
}

class _ComicViewerScreenState extends State<ComicViewerScreen> {
  List<Uint8List> _images = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadComicBook();
  }

Future<void> _loadComicBook() async {
    try {
      final bytes = await widget.comicFile.readAsBytes();
      Archive archive;

      final extension = p.extension(widget.comicFile.path).toLowerCase();
      if (extension == '.cbz') {
        archive = ZipDecoder().decodeBytes(bytes);
      } else {
        throw Exception('Unsupported archive type: $extension');
      }

      // 1. Create a new, modifiable list from the original read-only list.
      final sortedFiles = List<ArchiveFile>.from(archive.files);
      
      // 2. Sort our new copy of the list alphabetically.
      sortedFiles.sort((a, b) => a.name.compareTo(b.name));

      final List<Uint8List> comicImages = [];
      // 3. Loop through our sorted copy, not the original.
      for (final file in sortedFiles) {
        if (file.isFile) {
          final fileName = file.name.toLowerCase();
          if (fileName.endsWith('.jpg') || fileName.endsWith('.jpeg') || fileName.endsWith('.png') || fileName.endsWith('.gif')) {
             comicImages.add(file.content as Uint8List);
          }
        }
      }
      
      setState(() {
        _images = comicImages;
        _isLoading = false;
      });

    } catch (e) {
      print('Error loading comic book: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      backgroundColor: Colors.black,
      title: p.basename(widget.comicFile.path),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _images.isEmpty
              ? const Center(child: Text('No images found in this comic archive.'))
              : PageView.builder(
                  itemCount: _images.length,
                  itemBuilder: (context, index) {
                    return PhotoView(
                      imageProvider: MemoryImage(_images[index]),
                      minScale: PhotoViewComputedScale.contained,
                      maxScale: PhotoViewComputedScale.covered * 2.5,
                      heroAttributes: PhotoViewHeroAttributes(tag: 'page_$index'),
                    );
                  },
                ),
    );
  }
}