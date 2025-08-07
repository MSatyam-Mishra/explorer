import 'dart:io';
import 'package:explorer/features/viewer_text/screens/text_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';

// Import all our viewer screens (we will create the missing ones)
import '../../features/viewer_3d/screens/viewer_3d_screen.dart';
import '../../features/viewer_obj/screens/viewer_obj_screen.dart';
import '../../features/viewer_image/screens/viewer_image_screen.dart';
import '../../features/viewer_pdf/screens/viewer_pdf_screen.dart';
// TODO: Add imports for text, epub, and rive viewers when we create them.

class FileOpener {
  static void open(BuildContext context, File file) {
    final extension = p.extension(file.path).toLowerCase();

    switch (extension) {
      // Image cases
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.bmp':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ImageViewerScreen(imageFile: file)),
        );
        break;

      // 3D cases
      case '.glb':
      case '.gltf':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ThreeDViewerScreen(modelFile: file)),
        );
        break;
      case '.obj':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ObjViewerScreen(modelFile: file)),
        );
        break;

      // PDF case
      case '.pdf':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PdfViewerScreen(pdfFile: file)),
        );
        break;
       case '.txt':
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TextEditorScreen(textFile: file)),
    );
    break;
      // TODO: Add cases for .txt, .epub, .riv

      // Hand-off cases for complex/project files
      case '.doc':
      case '.docx':
      case '.xls':
      case '.xlsx':
      case '.ppt':
      case '.pptx':
      case '.unity':
      case '.unitypackage':
      case '.blend':
      default:
        OpenFilex.open(file.path);
        break;
    }
  }
}