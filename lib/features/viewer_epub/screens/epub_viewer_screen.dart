import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import 'dart:io';

class EpubViewerScreen extends StatefulWidget {
  final File epubFile;

  const EpubViewerScreen({super.key, required this.epubFile});

  @override
  State<EpubViewerScreen> createState() => _EpubViewerScreenState();
}

class _EpubViewerScreenState extends State<EpubViewerScreen> {
  late final EpubController _epubController;

  @override
  void initState() {
    super.initState();
    _epubController = EpubController();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.epubFile.path.split('/').last),
        actions: [
          IconButton(
            onPressed: () {
              // FIX #1: getChapters() is synchronous, so we call it directly.
              final chapters = _epubController.getChapters();
              // For now, we'll just print them to the console to see the data.
              // Later, we can show these in a beautiful dialog or drawer.
              print('Table of Contents:');
              for (var chapter in chapters) {
                print(chapter.title);
              }
            },
            icon: const Icon(Icons.toc_rounded), // Material icon, for now
          )
        ],
      ),
      body: EpubViewer(
        epubController: _epubController,
        // FIX #2: Use EpubSource.file() and pass the File object.
        epubSource: EpubSource.fromFile(widget.epubFile),
        //file(widget.epubFile),
        onEpubLoaded: () => print('Epub loaded successfully'),
        // FIX #3: The 'onError' parameter does not exist, so it's removed.
      ),
    );
  }
}