import 'dart:io';

import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

class SvgViewerScreen extends StatelessWidget {
  final File file;

  const SvgViewerScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      backgroundColor: Colors.white,
      title: p.basename(file.path),
      body: Center(
        child: SvgPicture.file(
          file,
          placeholderBuilder: (context) => const CircularProgressIndicator(),
        ),
      ),
    );
  }
}
