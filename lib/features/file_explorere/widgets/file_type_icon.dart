import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class FileTypeIcon extends StatelessWidget {
  final String filePath;
  final double size;

  const FileTypeIcon({super.key, required this.filePath, this.size = 42});

  @override
  Widget build(BuildContext context) {
    IconData iconData;
    Color iconColor;
    Color backgroundColor;

    final extension = p.extension(filePath).toLowerCase();

    switch (extension) {
      case '.pdf':
        iconData = BootstrapIcons.file_earmark_pdf_fill;
        backgroundColor = const Color(0xFFE57373); // Light Red
        break;
      case '.doc':
      case '.docx':
        iconData = BootstrapIcons.file_earmark_word_fill;
        backgroundColor = const Color(0xFF64B5F6); // Light Blue
        break;
      case '.xls':
      case '.xlsx':
        iconData = BootstrapIcons.file_earmark_excel_fill;
        backgroundColor = const Color(0xFF81C784); // Light Green
        break;
      case '.ppt':
      case '.pptx':
        iconData = BootstrapIcons.file_earmark_ppt_fill;
        backgroundColor = const Color(0xFFFFA726); // Light Orange
        break;
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.bmp':
        iconData = BootstrapIcons.file_earmark_image_fill;
        backgroundColor = const Color(0xFFCE93D8); // Light Purple
        break;
      case '.apk':
        iconData = BootstrapIcons.android;
        backgroundColor = const Color(0xFFAED581); // Light Lime
        break;
      case '.zip':
      case '.rar':
        iconData = BootstrapIcons.file_earmark_zip_fill;
        backgroundColor = const Color(0xFFD7CCC8); // Light Brown
        break;
      case '.mp3':
      case '.wav':
        iconData = BootstrapIcons.file_earmark_music_fill;
        backgroundColor = const Color(0xFFFFD54F); // Light Yellow
        break;
      case '.mp4':
      case '.mov':
      case '.mkv':
        iconData = BootstrapIcons.file_earmark_play_fill;
        backgroundColor = const Color(0xFF4DB6AC); // Light Teal
        break;
      case '.epub':
        iconData = BootstrapIcons.book_fill;
        backgroundColor = const Color(0xFFF57F17); // Deep Orange Accent
        break;
      case '.txt':
        iconData = BootstrapIcons.file_earmark_text_fill;
        backgroundColor = Colors.grey.shade400;
        break;
      case '.glb':
      case '.gltf':
      case '.obj':
        iconData = BootstrapIcons.box_fill;
        backgroundColor = const Color(0xFF90CAF9); // Lighter Blue
        break;
      default:
        iconData = BootstrapIcons.file_earmark;
        backgroundColor = Colors.grey.shade600;
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(size * 0.2), // Proportional radius
      ),
      child: Icon(
        iconData,
        color: Colors.white,
        size: size * 0.57, // Proportional icon size
      ),
    );
  }
}
