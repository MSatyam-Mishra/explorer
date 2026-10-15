import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/core/formats/cfb_reader.dart';

enum TextEncoding { utf8, utf8Bom, utf16le, utf16be, windows1252 }

enum LineEnding {
  lf('\n', 'LF'),
  crlf('\r\n', 'CRLF'),
  cr('\r', 'CR');

  const LineEnding(this.sequence, this.label);
  final String sequence;
  final String label;
}

/// A text file decoded for editing, remembering how to write it back
/// byte-for-byte compatible (encoding, BOM, line endings).
class TextDocument {
  TextDocument({
    required this.text,
    required this.encoding,
    required this.lineEnding,
    required this.endsWithNewline,
  });

  /// Content with line endings normalised to `\n`.
  final String text;
  final TextEncoding encoding;
  final LineEnding lineEnding;
  final bool endsWithNewline;

  /// Files above this size open read-only until the user opts in, because a
  /// single TextField over many megabytes becomes sluggish.
  static const editableLimit = 3 * 1024 * 1024;

  static Future<TextDocument> load(File file) async {
    final bytes = await file.readAsBytes();
    return decode(bytes);
  }

  static TextDocument decode(Uint8List bytes) {
    final encoding = _detectEncoding(bytes);
    final raw = switch (encoding) {
      TextEncoding.utf8 => utf8.decode(bytes, allowMalformed: true),
      TextEncoding.utf8Bom => utf8.decode(bytes.sublist(3), allowMalformed: true),
      TextEncoding.windows1252 => decodeCp1252(bytes),
      _ => decodeTextBytes(bytes),
    };
    final crlf = '\r\n'.allMatches(raw).length;
    final lf = '\n'.allMatches(raw).length - crlf;
    final cr = '\r'.allMatches(raw).length - crlf;
    final ending = crlf > lf && crlf >= cr
        ? LineEnding.crlf
        : (cr > lf ? LineEnding.cr : LineEnding.lf);
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return TextDocument(
      text: text,
      encoding: encoding,
      lineEnding: ending,
      endsWithNewline: text.endsWith('\n'),
    );
  }

  static TextEncoding _detectEncoding(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      return TextEncoding.utf8Bom;
    }
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return TextEncoding.utf16le;
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return TextEncoding.utf16be;
    try {
      utf8.decode(b);
      return TextEncoding.utf8;
    } on FormatException {
      return TextEncoding.windows1252;
    }
  }

  /// Encodes [content] (with `\n` line endings) the same way the file was
  /// originally stored.
  Uint8List encode(String content) {
    final out = lineEnding == LineEnding.lf
        ? content
        : content.replaceAll('\n', lineEnding.sequence);
    switch (encoding) {
      case TextEncoding.utf8:
        return Uint8List.fromList(utf8.encode(out));
      case TextEncoding.utf8Bom:
        return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(out)]);
      case TextEncoding.utf16le:
      case TextEncoding.utf16be:
        final le = encoding == TextEncoding.utf16le;
        final builder = BytesBuilder()..add(le ? [0xFF, 0xFE] : [0xFE, 0xFF]);
        for (final unit in out.codeUnits) {
          final lo = unit & 0xFF, hi = unit >> 8;
          builder.add(le ? [lo, hi] : [hi, lo]);
        }
        return builder.takeBytes();
      case TextEncoding.windows1252:
        // Characters outside Latin-1 can't round-trip; fall back to UTF-8 for
        // the whole file rather than corrupting them.
        if (out.codeUnits.any((c) => c > 0xFF)) {
          return Uint8List.fromList(utf8.encode(out));
        }
        return Uint8List.fromList(out.codeUnits);
    }
  }

  String get encodingLabel => switch (encoding) {
        TextEncoding.utf8 => 'UTF-8',
        TextEncoding.utf8Bom => 'UTF-8 BOM',
        TextEncoding.utf16le => 'UTF-16 LE',
        TextEncoding.utf16be => 'UTF-16 BE',
        TextEncoding.windows1252 => 'Windows-1252',
      };
}

/// Heuristic: does this look like human-readable text rather than binary?
bool looksLikeText(Uint8List sample) {
  if (sample.isEmpty) return true;
  if (sample.length >= 2 &&
      ((sample[0] == 0xFF && sample[1] == 0xFE) ||
          (sample[0] == 0xFE && sample[1] == 0xFF))) {
    return true;
  }
  var control = 0;
  for (final b in sample) {
    if (b == 0) return false;
    if (b < 0x09 || (b > 0x0D && b < 0x20)) control++;
  }
  return control / sample.length < 0.02;
}

/// Reads up to [length] bytes from the start of [file].
Future<Uint8List> readHead(File file, [int length = 8192]) async {
  final raf = await file.open();
  try {
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}
