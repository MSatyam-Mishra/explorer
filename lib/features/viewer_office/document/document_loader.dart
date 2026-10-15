import 'dart:typed_data';

import 'package:explorer/core/formats/cfb_reader.dart';

import '../common/office_package.dart';
import 'doc_binary_parser.dart';
import 'doc_model.dart';
import 'docx_parser.dart';
import 'odt_parser.dart';
import 'rtf_parser.dart';

export 'doc_binary_parser.dart' show DocumentEncryptedException;

/// Parses any supported word-processing file, sniffing the real format
/// from its bytes (a `.doc` that is really RTF or DOCX still opens).
///
/// Pure Dart; call through `Isolate.run`.
DocModel parseAnyDocument(Uint8List bytes, String extension) {
  final ext = extension.toLowerCase().replaceFirst('.', '');
  if (bytes.isEmpty) {
    return DocModel(format: _formatForExt(ext), blocks: [DocParagraph()]);
  }
  if (OfficePackage.isZip(bytes)) {
    final pkg = OfficePackage.decode(bytes);
    final mime = pkg.text('mimetype')?.trim() ?? '';
    if (mime.contains('opendocument') || (pkg.has('content.xml') && !pkg.has('[Content_Types].xml'))) {
      return parseOdtBytes(bytes);
    }
    return DocxParser(pkg).parse();
  }
  if (CfbReader.isCfb(bytes)) {
    final cfb = CfbReader(bytes);
    if (cfb.find('EncryptedPackage') != null) {
      throw const DocumentEncryptedException();
    }
    if (cfb.find('WordDocument') != null) {
      return parseDocBytes(bytes, format: ext == 'wps' ? 'wps' : 'doc');
    }
    return _worksText(cfb, ext);
  }
  final head = String.fromCharCodes(bytes.take(64)).trimLeft();
  if (head.startsWith('{\\rtf')) return parseRtfBytes(bytes);
  if (head.startsWith('<?xml') || head.startsWith('<office:document')) {
    try {
      return parseOdtBytes(bytes);
    } catch (_) {
      // Not flat ODF; show as text below.
    }
  }
  return plainTextModel(decodeTextBytes(bytes), _formatForExt(ext),
      html: head.toLowerCase().startsWith('<html') || head.toLowerCase().startsWith('<!doctype html'));
}

String _formatForExt(String ext) {
  switch (ext) {
    case 'docx':
    case 'docm':
    case 'dotx':
    case 'dotm':
      return 'docx';
    case 'rtf':
      return 'rtf';
    case 'odt':
    case 'ott':
    case 'fodt':
      return 'odt';
    case 'wps':
      return 'wps';
    case 'doc':
    case 'dot':
      return 'doc';
    default:
      return 'txt';
  }
}

/// One paragraph per line.
DocModel plainTextModel(String text, String format, {bool html = false}) {
  var t = text;
  if (html) {
    t = t
        .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|h[1-6]|li|tr)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
  }
  const base = DocRunStyle(fontSize: 11, fontFamily: 'Calibri');
  final lines = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final blocks = <DocBlock>[
    for (final l in lines)
      DocParagraph(
        inlines: l.isEmpty ? [] : [DocText(l, base)],
        spaceAfter: 4,
        markStyle: base,
      ),
  ];
  return DocModel(
    format: format,
    blocks: blocks.isEmpty ? [DocParagraph()] : blocks,
    baseStyle: base,
    warnings: const ['plainText'],
  );
}

/// Best-effort text from a Microsoft Works (non-Word) `.wps` container.
DocModel _worksText(CfbReader cfb, String ext) {
  var best = '';
  for (final entry in cfb.streams) {
    if (entry.size < 16) continue;
    final data = cfb.read(entry);
    final utf16 = _printableRuns(decodeUtf16le(data));
    final ansi = _printableRuns(decodeCp1252(data));
    final pick = utf16.length >= ansi.length ? utf16 : ansi;
    if (pick.length > best.length) best = pick;
  }
  if (best.trim().isEmpty) {
    throw const FormatException('This Works document format isn\'t supported.');
  }
  final m = plainTextModel(best, ext == 'wps' ? 'wps' : 'doc');
  return m;
}

/// Keeps runs of readable text (≥ 4 characters), joined by newlines.
String _printableRuns(String s) {
  final out = StringBuffer();
  final run = StringBuffer();
  void flush() {
    final r = run.toString();
    if (r.trim().length >= 4 && RegExp(r'[A-Za-zÀ-ɏЀ-ӿ]{2}').hasMatch(r)) {
      out.writeln(r.trim());
    }
    run.clear();
  }

  for (final c in s.runes) {
    final ok = c == 0x09 ||
        (c >= 0x20 && c < 0x7F) ||
        (c >= 0xA0 && c < 0xD800) ||
        (c >= 0xE000 && c < 0xFFF0 && c != 0xFFFD);
    if (ok) {
      run.writeCharCode(c);
    } else {
      flush();
    }
  }
  flush();
  return out.toString();
}
