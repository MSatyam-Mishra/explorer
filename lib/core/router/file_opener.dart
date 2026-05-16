import 'dart:io';

import 'package:explorer/features/viewer_archive/screens/archive_viewer_screen.dart';
import 'package:explorer/features/viewer_comic/screens/comic_viewer.dart';
import 'package:explorer/features/viewer_epub/screens/epub_viewer_screen.dart';
import 'package:explorer/features/viewer_text/screens/tabbed_text_editor.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';

// Import all our viewer screens
import 'package:explorer/features/viewer_media/screens/audio_player_screen.dart';
import 'package:explorer/features/viewer_media/screens/video_player_screen.dart';
import 'package:explorer/features/viewer_vector/screens/svg_viewer_screen.dart';
import 'package:explorer/features/viewer_vector/screens/lottie_viewer_screen.dart';
import 'package:explorer/features/viewer_vector/screens/rive_viewer_screen.dart';
import 'package:explorer/features/viewer_3d/screens/three_d_viewer_screen.dart';
import '../../features/viewer_image/screens/viewer_image_screen.dart';
import '../../features/viewer_pdf/screens/viewer_pdf_screen.dart';
import 'package:explorer/features/viewer_html/screens/html_viewer_screen.dart';
import 'package:explorer/features/viewer_office/screens/word_viewer_screen.dart';
import 'package:explorer/features/viewer_office/screens/excel_viewer_screen.dart';
import 'package:explorer/features/viewer_office/screens/ppt_viewer_screen.dart';

class FileOpener {
  static Future<bool?> open(BuildContext context, File file) async {
    final extension = p.extension(file.path).toLowerCase();
    bool? refresh;
    switch (extension) {
      // Audio cases
      case '.mp3':
      case '.wav':
      case '.flac':
      case '.ogg':
      case '.m4a':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioFile: file)),
        );
        break;

      // Video cases
      case '.mp4':
      case '.mkv':
      case '.avi':
      case '.webm':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoFile: file)),
        );
        break;

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
      case '.obj':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ThreeDViewerScreen(file: file)),
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
      case '.md':
      case '.yaml':
      case '.yml':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TabbedTextEditorScreen(initialFile: file),
          ),
        );
        break;
      case '.epub':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => EpubViewerScreen(epubFile: file)),
        );
        break;
      case '.riv':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => RiveViewerScreen(riveFile: file)),
        );
        break;

      case '.cbz':
      case '.cbr':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ComicViewerScreen(comicFile: file)),
        );
        break;

      case '.svg':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SvgViewerScreen(filePath: file.path),
          ),
        );
        break;

      case '.json':
        // Rudimentary check: assume JSON is Lottie for now in this viewer context
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => LottieViewerScreen(file: file)),
        );
        break;

      // Archive Support
      case '.zip':
      case '.rar':
      case '.7z':
      case '.tar':
      case '.gz':
      case '.tgz':
        refresh = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => ArchiveViewerScreen(archiveFile: file),
          ),
        );
        break;

      // HTML & Source cases
      case '.html':
      case '.htm':
      case '.xml':
      case '.opml':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => HtmlViewerScreen(file: file)),
        );
        break;

      // Ebook cases (Not supported yet)
      case '.mobi':
      case '.azw':
      case '.azw3':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MOBI format not supported yet')),
        );
        break;

      // Office cases
      case '.docx':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => WordViewerScreen(file: file)),
        );
        break;
      case '.xlsx':
      case '.xls': // xls might trigger error in 'excel' package if it only supports xlsx, but mostly it supports both or we fail gracefully
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ExcelViewerScreen(file: file)),
        );
        break;
      case '.pptx':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PptViewerScreen(file: file)),
        );
        break;

      // Legacy/Complex
      case '.doc':
      case '.ppt':
      case '.unity':
      case '.unitypackage':
      case '.blend':
      default:
        OpenFilex.open(file.path);
        break;
    }
    return refresh;
  }
}
