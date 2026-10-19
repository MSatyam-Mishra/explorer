// SHA-256 for fingerprints and file checksums.
//
// A small dedicated implementation: in AOT builds it is several times faster
// than the generic digest in pointycastle, which matters for checksums of
// large received files. Hashing files runs in a background isolate.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

class LsSha256 {
  LsSha256() {
    _reset();
  }

  static final Uint32List _k = Uint32List.fromList(const [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ]);

  final Uint32List _h = Uint32List(8);
  final Uint32List _w = Uint32List(64);
  final Uint8List _block = Uint8List(64);
  int _blockLen = 0;
  int _total = 0;

  void _reset() {
    _h.setAll(0, const [
      0x6a09e667,
      0xbb67ae85,
      0x3c6ef372,
      0xa54ff53a,
      0x510e527f,
      0x9b05688c,
      0x1f83d9ab,
      0x5be0cd19,
    ]);
    _blockLen = 0;
    _total = 0;
  }

  void add(List<int> data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var i = start;
    _total += stop - start;
    if (_blockLen > 0) {
      while (i < stop && _blockLen < 64) {
        _block[_blockLen++] = bytes[i++];
      }
      if (_blockLen == 64) {
        _compress(_block, 0);
        _blockLen = 0;
      }
    }
    while (stop - i >= 64) {
      _compress(bytes, i);
      i += 64;
    }
    while (i < stop) {
      _block[_blockLen++] = bytes[i++];
    }
  }

  Uint8List close() {
    final bitLen = _total * 8;
    _block[_blockLen++] = 0x80;
    if (_blockLen > 56) {
      while (_blockLen < 64) {
        _block[_blockLen++] = 0;
      }
      _compress(_block, 0);
      _blockLen = 0;
    }
    while (_blockLen < 56) {
      _block[_blockLen++] = 0;
    }
    for (var i = 7; i >= 0; i--) {
      _block[56 + (7 - i)] = (bitLen >> (8 * i)) & 0xff;
    }
    _compress(_block, 0);
    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      final v = _h[i];
      out[i * 4] = v >> 24;
      out[i * 4 + 1] = (v >> 16) & 0xff;
      out[i * 4 + 2] = (v >> 8) & 0xff;
      out[i * 4 + 3] = v & 0xff;
    }
    _reset();
    return out;
  }

  void _compress(Uint8List b, int offset) {
    final w = _w;
    for (var t = 0; t < 16; t++) {
      final o = offset + t * 4;
      w[t] = (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    }
    for (var t = 16; t < 64; t++) {
      final x = w[t - 15];
      final y = w[t - 2];
      final s0 = ((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3);
      final s1 = ((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = _h[0], bb = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    final k = _k;
    for (var t = 0; t < 64; t++) {
      final s1 =
          (((e >> 6) | (e << 26)) ^
              ((e >> 11) | (e << 21)) ^
              ((e >> 25) | (e << 7))) &
          0xffffffff;
      final ch = (e & f) ^ (~e & g);
      final t1 = (h + s1 + ch + k[t] + w[t]) & 0xffffffff;
      final s0 =
          (((a >> 2) | (a << 30)) ^
              ((a >> 13) | (a << 19)) ^
              ((a >> 22) | (a << 10))) &
          0xffffffff;
      final maj = (a & bb) ^ (a & c) ^ (bb & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = bb;
      bb = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] += a;
    _h[1] += bb;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }

  static Uint8List of(List<int> data) => (LsSha256()..add(data)).close();
}

String lsHex(List<int> bytes, {bool upper = false}) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  final s = sb.toString();
  return upper ? s.toUpperCase() : s;
}

/// Lower-case hex SHA-256 of a file, computed in a background isolate so big
/// files never block the UI isolate.
Future<String> lsSha256OfFile(String path) =>
    Isolate.run(() => lsSha256OfFileSync(path));

String lsSha256OfFileSync(String path) {
  final hasher = LsSha256();
  final raf = File(path).openSync();
  try {
    final buffer = Uint8List(1 << 20);
    while (true) {
      final n = raf.readIntoSync(buffer);
      if (n <= 0) break;
      hasher.add(buffer, 0, n);
    }
  } finally {
    raf.closeSync();
  }
  return lsHex(hasher.close());
}
