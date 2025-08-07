
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

class ThreeDViewerScreen extends StatelessWidget {
  final File modelFile;

  const ThreeDViewerScreen({super.key, required this.modelFile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(modelFile.path.split('/').last),
      ),
      body: ModelViewer(
        backgroundColor: const Color(0xFF1E1E1E),
        src: 'file://${modelFile.path}', // IMPORTANT: Load from local file path
        alt: 'A 3D model',
        ar: true, // Enable Augmented Reality view
        autoRotate: true,
        cameraControls: true, // Enable zoom, pan, rotate
      ),
    );
  }
}