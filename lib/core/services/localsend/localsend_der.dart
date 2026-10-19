// Minimal DER encoder: just what a self-signed X.509 v3 certificate and a
// PKCS#8 RSA private key need.

import 'dart:convert';
import 'dart:typed_data';

abstract final class Der {
  static Uint8List tlv(int tag, List<int> content) {
    final out = BytesBuilder(copy: false)
      ..addByte(tag)
      ..add(_length(content.length))
      ..add(content);
    return out.toBytes();
  }

  static List<int> _length(int n) {
    if (n < 0x80) return [n];
    final bytes = <int>[];
    var v = n;
    while (v > 0) {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  static Uint8List sequence(List<List<int>> items) =>
      tlv(0x30, [for (final i in items) ...i]);

  static Uint8List set(List<List<int>> items) =>
      tlv(0x31, [for (final i in items) ...i]);

  /// Two's complement, minimal length (DER).
  static Uint8List integer(BigInt value) {
    if (value == BigInt.zero) return tlv(0x02, [0]);
    if (value.isNegative) {
      throw ArgumentError('negative integers are not needed here');
    }
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final bytes = <int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return tlv(0x02, bytes);
  }

  static Uint8List smallInt(int value) => integer(BigInt.from(value));

  static Uint8List oid(String dotted) {
    final parts = dotted.split('.').map(int.parse).toList();
    final out = <int>[40 * parts[0] + parts[1]];
    for (final part in parts.skip(2)) {
      final chunk = <int>[part & 0x7f];
      var v = part >> 7;
      while (v > 0) {
        chunk.insert(0, 0x80 | (v & 0x7f));
        v >>= 7;
      }
      out.addAll(chunk);
    }
    return tlv(0x06, out);
  }

  static Uint8List nullValue() => Uint8List.fromList([0x05, 0x00]);

  static Uint8List bitString(List<int> bytes) => tlv(0x03, [0, ...bytes]);

  static Uint8List octetString(List<int> bytes) => tlv(0x04, bytes);

  static Uint8List utf8String(String s) => tlv(0x0c, utf8.encode(s));

  /// UTCTime for 1950-2049, GeneralizedTime otherwise (RFC 5280 4.1.2.5).
  static Uint8List time(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final rest =
        '${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    if (u.year >= 1950 && u.year < 2050) {
      return tlv(0x17, ascii.encode('${two(u.year % 100)}$rest'));
    }
    return tlv(0x18, ascii.encode('${u.year.toString().padLeft(4, '0')}$rest'));
  }

  /// Context-specific, constructed, explicit tag `[n]`.
  static Uint8List explicit(int n, List<int> inner) => tlv(0xa0 | n, inner);

  static String pem(String label, List<int> der) {
    final b64 = base64.encode(der);
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  /// First PEM block's DER bytes.
  static Uint8List? pemToDer(String pem) {
    final match = RegExp(
      r'-----BEGIN [A-Z ]+-----([\s\S]*?)-----END [A-Z ]+-----',
    ).firstMatch(pem);
    if (match == null) return null;
    try {
      return base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return null;
    }
  }
}
