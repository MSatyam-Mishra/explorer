import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';

class ObjViewerScreen extends StatelessWidget {
  final File modelFile;

  const ObjViewerScreen({super.key, required this.modelFile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(modelFile.path.split('/').last),
      ),
      body: Flutter3DViewer(
        // THIS IS THE FIX: Add 'file://' to the path
        src: 'file://${modelFile.path}',
        progressBarColor: Theme.of(context).colorScheme.primary,
        onError: (error) {
    print("Error loading 3D model: $error");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Error loading model: $error")),
    );
  },
      ),
    );
  }
}