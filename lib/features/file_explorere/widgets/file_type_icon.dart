import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/files/file_types.dart';
import 'package:flutter/material.dart';

class FileTypeIcon extends StatelessWidget {
  final String filePath;
  final double size;

  const FileTypeIcon({super.key, required this.filePath, this.size = 42});

  static (IconData, Color) styleFor(String path) {
    final ext = FileTypes.extensionOf(path);
    return switch (FileTypes.kindOf(path)) {
      FileKind.pdf => (BootstrapIcons.file_earmark_pdf_fill, const Color(0xFFE57373)),
      FileKind.word ||
      FileKind.legacyWord ||
      FileKind.richText ||
      FileKind.openDocumentText =>
        (BootstrapIcons.file_earmark_word_fill, const Color(0xFF64B5F6)),
      FileKind.spreadsheet ||
      FileKind.legacySpreadsheet ||
      FileKind.openDocumentSpreadsheet =>
        (BootstrapIcons.file_earmark_excel_fill, const Color(0xFF81C784)),
      FileKind.delimited =>
        (BootstrapIcons.file_earmark_spreadsheet_fill, const Color(0xFF66BB6A)),
      FileKind.presentation ||
      FileKind.legacyPresentation ||
      FileKind.openDocumentPresentation =>
        (BootstrapIcons.file_earmark_ppt_fill, const Color(0xFFFFA726)),
      FileKind.image || FileKind.rasterImage =>
        (BootstrapIcons.file_earmark_image_fill, const Color(0xFFCE93D8)),
      FileKind.svg => (BootstrapIcons.vector_pen, const Color(0xFFBA68C8)),
      FileKind.video => (BootstrapIcons.file_earmark_play_fill, const Color(0xFF4DB6AC)),
      FileKind.audio => (BootstrapIcons.file_earmark_music_fill, const Color(0xFFFFD54F)),
      FileKind.epub || FileKind.ebook => (BootstrapIcons.book_fill, const Color(0xFFF57F17)),
      FileKind.comic => (BootstrapIcons.book_half, const Color(0xFFEF6C00)),
      FileKind.model3d => (BootstrapIcons.box_fill, const Color(0xFF90CAF9)),
      FileKind.archive => (BootstrapIcons.file_earmark_zip_fill, const Color(0xFFBCAAA4)),
      FileKind.markdown => (BootstrapIcons.markdown_fill, const Color(0xFF78909C)),
      FileKind.html => (BootstrapIcons.filetype_html, const Color(0xFFFF7043)),
      FileKind.json => (BootstrapIcons.braces, const Color(0xFF9CCC65)),
      FileKind.lottie || FileKind.rive =>
        (BootstrapIcons.film, const Color(0xFF26C6DA)),
      FileKind.font => (BootstrapIcons.fonts, const Color(0xFF8D6E63)),
      FileKind.code => (BootstrapIcons.file_earmark_code_fill, const Color(0xFF5C6BC0)),
      FileKind.text => (BootstrapIcons.file_earmark_text_fill, const Color(0xFF9E9E9E)),
      FileKind.package => ext == 'apk'
          ? (BootstrapIcons.android, const Color(0xFFAED581))
          : (BootstrapIcons.box_seam_fill, const Color(0xFF7E57C2)),
      FileKind.unknown => (BootstrapIcons.file_earmark_fill, const Color(0xFF757575)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (iconData, backgroundColor) = styleFor(filePath);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(size * 0.2),
      ),
      child: Icon(iconData, color: Colors.white, size: size * 0.57),
    );
  }
}
