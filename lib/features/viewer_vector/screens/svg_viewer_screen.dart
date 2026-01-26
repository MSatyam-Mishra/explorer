import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class SvgViewerScreen extends StatelessWidget {
  final File file;

  const SvgViewerScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // SVG often needs white bg or checkerboard
      appBar: AppBar(
        title: Text(file.path.split('/').last),
        iconTheme: const IconThemeData(color: Colors.black),
        backgroundColor: Colors.white,
        elevation: 1,
        titleTextStyle: const TextStyle(color: Colors.black, fontSize: 18),
      ),
      body: Center(
        child: SvgPicture.file(
          file,
          placeholderBuilder: (context) => const CircularProgressIndicator(),
        ),
      ),
    );
  }
}
