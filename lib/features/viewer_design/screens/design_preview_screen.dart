import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Shows the preview embedded in design, CAD and print files.
// Placeholder: being implemented.
class DesignPreviewScreen extends StatelessWidget {
  const DesignPreviewScreen({super.key, required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(p.basename(file.path))),
      body: const Center(child: Text('Preview not available yet')),
    );
  }
}
