import 'dart:typed_data';

import 'package:explorer/core/formats/cfb_reader.dart';

import '../common/office_package.dart';
import 'odp_parser.dart';
import 'ppt_parser.dart';
import 'pptx_parser.dart';
import 'slide_model.dart';

export 'ppt_parser.dart' show PresentationEncryptedException;

/// Parses any supported presentation, sniffing the real format from its
/// bytes. Pure Dart; call through `Isolate.run`.
SlideDeck parseAnyPresentation(Uint8List bytes, String extension) {
  if (bytes.isEmpty) throw const FormatException('The file is empty.');
  if (OfficePackage.isZip(bytes)) {
    final pkg = OfficePackage.decode(bytes);
    final mime = pkg.text('mimetype')?.trim() ?? '';
    if (mime.contains('opendocument') ||
        (pkg.has('content.xml') && !pkg.has('[Content_Types].xml'))) {
      return parseOdpBytes(bytes);
    }
    return PptxParser(pkg).parse();
  }
  if (CfbReader.isCfb(bytes)) {
    final cfb = CfbReader(bytes);
    if (cfb.find('EncryptedPackage') != null) {
      throw const PresentationEncryptedException();
    }
    return parsePptBytes(bytes);
  }
  final head = String.fromCharCodes(bytes.take(64)).trimLeft();
  if (head.startsWith('<?xml') || head.startsWith('<office:document')) {
    return parseOdpBytes(bytes);
  }
  throw const FormatException(
    'This file isn\'t a presentation format we can read.',
  );
}

/// Whether [deck] can be edited and saved back (PPTX family only).
bool isEditablePresentation(SlideDeck deck) => deck.format == 'pptx';
