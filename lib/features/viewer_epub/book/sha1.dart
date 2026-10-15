import 'dart:typed_data';

/// Minimal SHA-1, used only to derive the IDPF font-obfuscation key.
Uint8List sha1Digest(List<int> message) {
  final ml = message.length;
  final padded = Uint8List(((ml + 9 + 63) ~/ 64) * 64)..setAll(0, message);
  padded[ml] = 0x80;
  final bitLen = ml * 8;
  final bd = ByteData.sublistView(padded);
  bd.setUint32(padded.length - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF);
  bd.setUint32(padded.length - 4, bitLen & 0xFFFFFFFF);

  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE;
  var h3 = 0x10325476, h4 = 0xC3D2E1F0;
  final w = Uint32List(80);
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;

  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(chunk + i * 4);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }
  final out = ByteData(20)
    ..setUint32(0, h0)
    ..setUint32(4, h1)
    ..setUint32(8, h2)
    ..setUint32(12, h3)
    ..setUint32(16, h4);
  return out.buffer.asUint8List();
}
