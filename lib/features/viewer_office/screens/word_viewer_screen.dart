import 'dart:io';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class WordViewerScreen extends StatelessWidget {
  final File file;

  const WordViewerScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(p.basename(file.path))),
      body: DocxViewer(file: file),
    );
  }
}
