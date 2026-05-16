import 'dart:io';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class WordViewerScreen extends StatelessWidget {
  final File file;

  const WordViewerScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: p.basename(file.path),
      body: DocxViewer(file: file),
    );
  }
}
