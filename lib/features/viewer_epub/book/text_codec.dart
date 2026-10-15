import 'dart:convert';
import 'dart:typed_data';

/// Decodes book markup and text in the encodings e-books actually use:
/// UTF-8, UTF-16 (BOM), windows-1252/latin-1, windows-1251 and KOI8-R.
abstract final class TextCodec {
  /// Decodes markup, honouring a BOM, the XML declaration's `encoding`, and
  /// an HTML `<meta charset>`; falls back to UTF-8 then windows-1252.
  static String decodeMarkup(Uint8List bytes, {String? fallbackCharset}) {
    final bom = _decodeBom(bytes);
    if (bom != null) return bom;

    final head = latin1.decode(
      bytes.length > 1024 ? Uint8List.sublistView(bytes, 0, 1024) : bytes,
    );
    String? charset;
    final xmlDecl =
        RegExp(r'''<\?xml[^>]*encoding\s*=\s*["']([^"']+)["']''')
            .firstMatch(head);
    if (xmlDecl != null) {
      charset = xmlDecl.group(1);
    } else {
      final meta = RegExp(
        r'''<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9_\-:.]+)''',
        caseSensitive: false,
      ).firstMatch(head);
      charset = meta?.group(1);
    }
    return decode(bytes, charset ?? fallbackCharset);
  }

  /// Decodes [bytes] with the named [charset] (case-insensitive). Unknown or
  /// null charsets try strict UTF-8 first, then windows-1252.
  static String decode(Uint8List bytes, String? charset) {
    final bom = _decodeBom(bytes);
    if (bom != null) return bom;
    final cs = (charset ?? '').trim().toLowerCase().replaceAll('_', '-');
    switch (cs) {
      case 'windows-1251':
      case 'cp1251':
      case 'win-1251':
      case 'x-cp1251':
        return _decodeTable(bytes, _cp1251);
      case 'koi8-r':
      case 'koi8r':
      case 'koi8-u':
        return _decodeTable(bytes, _koi8r);
      case 'windows-1252':
      case 'cp1252':
      case 'iso-8859-1':
      case 'iso8859-1':
      case 'latin1':
      case 'latin-1':
      case 'us-ascii':
      case 'ascii':
        return _decodeTable(bytes, _cp1252);
      case 'utf-16':
      case 'utf-16le':
        return _decodeUtf16(bytes, littleEndian: true);
      case 'utf-16be':
        return _decodeUtf16(bytes, littleEndian: false);
      case 'utf-8':
      case 'utf8':
        return utf8.decode(bytes, allowMalformed: true);
      default:
        try {
          return utf8.decode(bytes);
        } on FormatException {
          return _decodeTable(bytes, _cp1252);
        }
    }
  }

  static String? _decodeBom(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      return utf8.decode(Uint8List.sublistView(b, 3), allowMalformed: true);
    }
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      return _decodeUtf16(Uint8List.sublistView(b, 2), littleEndian: true);
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return _decodeUtf16(Uint8List.sublistView(b, 2), littleEndian: false);
    }
    // UTF-16 without BOM: "<\0" or "\0<".
    if (b.length >= 4 && b[0] == 0x3C && b[1] == 0 && b[2] != 0 && b[3] == 0) {
      return _decodeUtf16(b, littleEndian: true);
    }
    if (b.length >= 4 && b[0] == 0 && b[1] == 0x3C && b[2] == 0 && b[3] != 0) {
      return _decodeUtf16(b, littleEndian: false);
    }
    return null;
  }

  static String _decodeUtf16(Uint8List b, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      units.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static String _decodeTable(Uint8List bytes, String high) {
    final codes = Uint16List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      final c = bytes[i];
      codes[i] = c < 0x80 ? c : high.codeUnitAt(c - 0x80);
    }
    return String.fromCharCodes(codes);
  }

  /// Decodes a single-byte windows-1252 buffer (used by MOBI).
  static String decodeCp1252(Uint8List bytes) => _decodeTable(bytes, _cp1252);

  static final String _cp1252 = String.fromCharCodes([
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    for (var c = 0xA0; c <= 0xFF; c++) c,
  ]);

  static final String _cp1251 = String.fromCharCodes([
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    for (var c = 0x0410; c <= 0x044F; c++) c,
  ]);

  static final String _koi8r = String.fromCharCodes([
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, //
    0x252C, 0x2534, 0x253C, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590,
    0x2591, 0x2592, 0x2593, 0x2320, 0x25A0, 0x2219, 0x221A, 0x2248,
    0x2264, 0x2265, 0x00A0, 0x2321, 0x00B0, 0x00B2, 0x00B7, 0x00F7,
    0x2550, 0x2551, 0x2552, 0x0451, 0x2553, 0x2554, 0x2555, 0x2556,
    0x2557, 0x2558, 0x2559, 0x255A, 0x255B, 0x255C, 0x255D, 0x255E,
    0x255F, 0x2560, 0x2561, 0x0401, 0x2562, 0x2563, 0x2564, 0x2565,
    0x2566, 0x2567, 0x2568, 0x2569, 0x256A, 0x256B, 0x256C, 0x00A9,
    ...'юабцдефгхийклмнопярстужвьызшэщчъ'.codeUnits,
    ...'юабцдефгхийклмнопярстужвьызшэщчъ'.toUpperCase().codeUnits,
  ]);
}
