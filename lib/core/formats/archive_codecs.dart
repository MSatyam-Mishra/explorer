/// Streaming decompressors with bounded memory, for formats the platform
/// zlib doesn't cover: Deflate64 (ZIP method 9), BZip2 (`.bz2`, ZIP method
/// 12) and XZ/LZMA2 (`.xz`, ZIP method 95). Gzip uses dart:io's native
/// decoder. All decoders throw [FormatException] on malformed input.
library;

import 'dart:async';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' show Crc32;
import 'package:koni_codecs/crypto.dart' show Sha256;

/// Gzip (multi-member) through the platform zlib.
Stream<Uint8List> gunzipStream(Stream<Uint8List> input) => gzip.decoder
    .bind(input)
    .map((c) => c is Uint8List ? c : Uint8List.fromList(c));

// ---------------------------------------------------------------------------
// Pull reader over a chunk stream
// ---------------------------------------------------------------------------

class _ChunkReader {
  _ChunkReader(Stream<Uint8List> input) : _it = StreamIterator(input);

  final StreamIterator<Uint8List> _it;
  Uint8List buf = Uint8List(0);
  int pos = 0;
  bool _eof = false;

  int get available => buf.length - pos;
  bool get inputDone => _eof;

  /// Buffers at least [n] bytes, fewer only at the end of input.
  Future<void> fill(int n) async {
    if (available >= n || _eof) return;
    final parts = <Uint8List>[];
    var have = available;
    if (have > 0) parts.add(Uint8List.sublistView(buf, pos));
    while (have < n) {
      if (!await _it.moveNext()) {
        _eof = true;
        break;
      }
      final c = _it.current;
      if (c.isEmpty) continue;
      parts.add(c);
      have += c.length;
    }
    if (parts.length == 1) {
      buf = parts.first;
    } else {
      final out = Uint8List(have);
      var o = 0;
      for (final p in parts) {
        out.setRange(o, o + p.length, p);
        o += p.length;
      }
      buf = out;
    }
    pos = 0;
  }

  Future<Uint8List> readExact(int n) async {
    await fill(n);
    if (available < n) throw const FormatException('unexpected end of data');
    final out = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return out;
  }

  Future<int> readByte() async => (await readExact(1))[0];

  /// Whether any byte remains (pulls more input when needed).
  Future<bool> hasMore() async {
    await fill(1);
    return available > 0;
  }

  Future<void> cancel() => _it.cancel();
}

/// A power-of-two ring window that also queues decoded bytes for output.
class _Window {
  _Window(int minSize) {
    var size = 1 << 16;
    while (size < minSize) {
      size <<= 1;
    }
    data = Uint8List(size);
    mask = size - 1;
  }

  late final Uint8List data;
  late final int mask;

  /// Total bytes written.
  int pos = 0;

  /// Bytes written before this point have been handed out.
  int flushed = 0;

  int get pending => pos - flushed;

  void put(int b) => data[pos++ & mask] = b;

  /// Copies [len] bytes from [dist] back (LZ77 match).
  void copy(int dist, int len) {
    final d = data, m = mask;
    var src = pos - dist;
    var dst = pos;
    final end = pos + len;
    while (dst < end) {
      d[dst++ & m] = d[src++ & m];
    }
    pos = end;
  }

  void putAll(Uint8List bytes, int start, int end) {
    for (var i = start; i < end; i++) {
      data[pos++ & mask] = bytes[i];
    }
  }

  /// Returns (a copy of) everything not yet handed out.
  Uint8List take() {
    final n = pending;
    final out = Uint8List(n);
    final start = flushed & mask;
    final first = data.length - start;
    if (n <= first) {
      out.setRange(0, n, data, start);
    } else {
      out.setRange(0, first, data, start);
      out.setRange(first, n, data, 0);
    }
    flushed = pos;
    return out;
  }
}

// ---------------------------------------------------------------------------
// Inflate (DEFLATE / Deflate64)
// ---------------------------------------------------------------------------

/// Raw Deflate64 ("enhanced deflate", ZIP method 9).
Stream<Uint8List> inflate64Stream(Stream<Uint8List> input) =>
    _inflate(input, deflate64: true);

/// Raw DEFLATE in pure Dart (used where dart:io's zlib is unavailable).
Stream<Uint8List> inflatePureStream(Stream<Uint8List> input) =>
    _inflate(input, deflate64: false);

const _lenBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, //
  67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const _lenExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, //
  5, 5, 5, 5, 0,
];
const _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, //
  769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769,
  49153,
];
const _distExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, //
  11, 11, 12, 12, 13, 13, 14, 14,
];
const _clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/// LSB-first canonical Huffman lookup table.
class _LsbHuffman {
  _LsbHuffman(List<int> lengths, int n) {
    var maxLen = 0;
    final count = List<int>.filled(16, 0);
    for (var i = 0; i < n; i++) {
      final l = lengths[i];
      if (l > maxLen) maxLen = l;
      count[l]++;
    }
    if (maxLen == 0) maxLen = 1;
    bits = maxLen;
    table = Int32List(1 << maxLen)..fillRange(0, 1 << maxLen, -1);
    count[0] = 0;
    final next = List<int>.filled(16, 0);
    var code = 0;
    for (var len = 1; len <= 15; len++) {
      code = (code + count[len - 1]) << 1;
      next[len] = code;
    }
    for (var sym = 0; sym < n; sym++) {
      final len = lengths[sym];
      if (len == 0) continue;
      final c = next[len]++;
      if (c >= (1 << len)) throw const FormatException('bad Huffman code');
      var rev = 0;
      for (var i = 0; i < len; i++) {
        rev |= ((c >> i) & 1) << (len - 1 - i);
      }
      for (var i = rev; i < table.length; i += 1 << len) {
        table[i] = (sym << 4) | len;
      }
    }
  }

  late final int bits;
  late final Int32List table;
}

class _Inflater {
  _Inflater(this.r, this.deflate64);

  final _ChunkReader r;
  final bool deflate64;
  final _Window win = _Window(1 << 17);

  int bitBuf = 0;
  int bitCnt = 0;
  int padBits = 0; // virtual zero bits added past the end of input

  // 0 = block header, 1 = stored, 2 = huffman, 3 = done
  int state = 0;
  bool last = false;
  int storedLeft = 0;
  _LsbHuffman? lit;
  _LsbHuffman? dist;

  void need(int n) {
    while (bitCnt < n) {
      int b;
      if (r.pos < r.buf.length) {
        b = r.buf[r.pos++];
      } else if (r.inputDone) {
        b = 0;
        padBits += 8;
      } else {
        throw StateError('inflate input underrun');
      }
      bitBuf |= b << bitCnt;
      bitCnt += 8;
    }
  }

  int bits(int n) {
    if (n == 0) return 0;
    need(n);
    final v = bitBuf & ((1 << n) - 1);
    bitBuf >>>= n;
    bitCnt -= n;
    return v;
  }

  int decode(_LsbHuffman h) {
    need(h.bits);
    final e = h.table[bitBuf & ((1 << h.bits) - 1)];
    if (e < 0) throw const FormatException('invalid Huffman code');
    final len = e & 15;
    bitBuf >>>= len;
    bitCnt -= len;
    return e >> 4;
  }

  void _checkPad() {
    if (padBits > bitCnt) {
      throw const FormatException('truncated deflate data');
    }
  }

  /// One unit of work; returns false when the stream is complete.
  bool step() {
    switch (state) {
      case 0:
        if (last) {
          state = 3;
          return false;
        }
        last = bits(1) == 1;
        final type = bits(2);
        if (type == 0) {
          // Byte-align, then LEN/NLEN.
          bits(bitCnt & 7);
          final len = bits(16);
          final nlen = bits(16);
          if (len != (~nlen & 0xFFFF)) {
            throw const FormatException('bad stored block length');
          }
          storedLeft = len;
          state = 1;
        } else if (type == 1) {
          _fixedTables();
          state = 2;
        } else if (type == 2) {
          _dynamicTables();
          state = 2;
        } else {
          throw const FormatException('invalid deflate block type');
        }
        _checkPad();
        return true;
      case 1:
        if (storedLeft == 0) {
          state = 0;
          return true;
        }
        // Drain whole bytes left in the bit buffer first.
        while (storedLeft > 0 && bitCnt >= 8) {
          win.put(bits(8));
          storedLeft--;
        }
        if (storedLeft > 0) {
          final avail = r.buf.length - r.pos;
          if (avail == 0) {
            if (r.inputDone) {
              throw const FormatException('truncated stored block');
            }
            return true;
          }
          final take = avail < storedLeft ? avail : storedLeft;
          final chunk = take < 32768 ? take : 32768;
          win.putAll(r.buf, r.pos, r.pos + chunk);
          r.pos += chunk;
          storedLeft -= chunk;
        }
        return true;
      case 2:
        final sym = decode(lit!);
        if (sym < 256) {
          win.put(sym);
        } else if (sym == 256) {
          state = 0;
        } else {
          final li = sym - 257;
          if (li >= 29) throw const FormatException('bad length code');
          int len;
          if (deflate64 && li == 28) {
            len = 3 + bits(16);
          } else {
            len = _lenBase[li] + bits(_lenExtra[li]);
          }
          final ds = decode(dist!);
          if (ds >= (deflate64 ? 32 : 30)) {
            throw const FormatException('bad distance code');
          }
          final d = _distBase[ds] + bits(_distExtra[ds]);
          if (d > win.pos) {
            throw const FormatException('distance before start of data');
          }
          win.copy(d, len);
        }
        _checkPad();
        return true;
      default:
        return false;
    }
  }

  static _LsbHuffman? _fixedLit;
  static _LsbHuffman? _fixedDist;

  void _fixedTables() {
    _fixedLit ??= _LsbHuffman([
      for (var i = 0; i < 144; i++) 8,
      for (var i = 144; i < 256; i++) 9,
      for (var i = 256; i < 280; i++) 7,
      for (var i = 280; i < 288; i++) 8,
    ], 288);
    _fixedDist ??= _LsbHuffman(List<int>.filled(32, 5), 32);
    lit = _fixedLit;
    dist = _fixedDist;
  }

  void _dynamicTables() {
    final hlit = bits(5) + 257;
    final hdist = bits(5) + 1;
    final hclen = bits(4) + 4;
    final cl = List<int>.filled(19, 0);
    for (var i = 0; i < hclen; i++) {
      cl[_clOrder[i]] = bits(3);
    }
    final clh = _LsbHuffman(cl, 19);
    final lengths = List<int>.filled(hlit + hdist, 0);
    var i = 0;
    while (i < hlit + hdist) {
      final sym = decode(clh);
      if (sym < 16) {
        lengths[i++] = sym;
      } else {
        int rep;
        var val = 0;
        if (sym == 16) {
          if (i == 0) throw const FormatException('repeat with no length');
          val = lengths[i - 1];
          rep = 3 + bits(2);
        } else if (sym == 17) {
          rep = 3 + bits(3);
        } else {
          rep = 11 + bits(7);
        }
        if (i + rep > hlit + hdist) {
          throw const FormatException('too many code lengths');
        }
        for (var k = 0; k < rep; k++) {
          lengths[i++] = val;
        }
      }
    }
    if (lengths[256] == 0) throw const FormatException('no end-of-block code');
    lit = _LsbHuffman(lengths.sublist(0, hlit), hlit);
    dist = _LsbHuffman(lengths.sublist(hlit), hdist);
  }
}

Stream<Uint8List> _inflate(
  Stream<Uint8List> input, {
  required bool deflate64,
}) async* {
  final r = _ChunkReader(input);
  final inf = _Inflater(r, deflate64);
  const margin = 4096;
  try {
    var running = true;
    while (running) {
      await r.fill(margin * 4);
      // Decode while a full step's worth of input is buffered.
      while (running && (r.inputDone || r.available >= margin)) {
        running = inf.step();
        if (inf.win.pending >= 1 << 15) yield inf.win.take();
        if (inf.state == 1 && r.available == 0 && !r.inputDone) break;
      }
      if (running && r.inputDone && r.available == 0 && inf.state == 1) {
        throw const FormatException('truncated deflate data');
      }
    }
    if (inf.win.pending > 0) yield inf.win.take();
  } finally {
    await r.cancel();
  }
}

// ---------------------------------------------------------------------------
// BZip2
// ---------------------------------------------------------------------------

/// BZip2 decoder (multi-stream), block by block.
Stream<Uint8List> bzip2Stream(Stream<Uint8List> input) async* {
  final r = _ChunkReader(input);
  try {
    final bz = _Bzip2(r);
    var first = true;
    while (true) {
      await r.fill(64 * 1024);
      if (!first) {
        // Another concatenated stream? (pbzip2 and friends.)
        if (r.available < 4 || r.buf[r.pos] != 0x42) break;
      }
      bz.readStreamHeader();
      first = false;
      while (true) {
        await r.fill(bz.blockSize100k * 250000 + 64 * 1024);
        final more = bz.readBlockHeader();
        if (!more) break;
        bz.decodeBlock();
        for (final out in bz.output()) {
          yield out;
        }
      }
      // Give back the unread whole bytes before refilling the buffer.
      bz.alignToByte();
    }
  } finally {
    await r.cancel();
  }
}

class _Bzip2 {
  _Bzip2(this.r);

  final _ChunkReader r;
  int bitBuf = 0;
  int bitCnt = 0;
  int blockSize100k = 9;
  int blockCrc = 0;
  int combinedCrc = 0;
  int origPtr = 0;
  int nblock = 0;
  Uint32List tt = Uint32List(0);

  static final Uint32List _crcTable = () {
    final t = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i << 24;
      for (var k = 0; k < 8; k++) {
        c = (c & 0x80000000) != 0 ? ((c << 1) ^ 0x04C11DB7) : (c << 1);
        c &= 0xFFFFFFFF;
      }
      t[i] = c;
    }
    return t;
  }();

  int bits(int n) {
    while (bitCnt < n) {
      if (r.pos >= r.buf.length) {
        throw const FormatException('truncated bzip2 data');
      }
      bitBuf = ((bitBuf << 8) | r.buf[r.pos++]) & 0xFFFFFFFFFFFF;
      bitCnt += 8;
    }
    bitCnt -= n;
    return (bitBuf >> bitCnt) & ((1 << n) - 1);
  }

  int bit() => bits(1);

  void alignToByte() {
    bitCnt -= bitCnt & 7;
    // Return whole unread bytes in the bit buffer to the input.
    r.pos -= bitCnt >> 3;
    bitCnt = 0;
    bitBuf = 0;
  }

  void readStreamHeader() {
    if (bits(8) != 0x42 || bits(8) != 0x5A || bits(8) != 0x68) {
      throw const FormatException('not a bzip2 stream');
    }
    final level = bits(8) - 0x30;
    if (level < 1 || level > 9) {
      throw const FormatException('bad bzip2 block size');
    }
    blockSize100k = level;
    combinedCrc = 0;
    if (tt.length < level * 100000) tt = Uint32List(level * 100000);
  }

  /// Reads a block or end-of-stream marker; false at end of stream.
  bool readBlockHeader() {
    final hi = bits(24);
    final lo = bits(24);
    if (hi == 0x314159 && lo == 0x265359) {
      blockCrc = bits(32);
      return true;
    }
    if (hi == 0x177245 && lo == 0x385090) {
      final stored = bits(32);
      if (stored != combinedCrc) {
        throw const FormatException('bzip2 stream CRC mismatch');
      }
      return false;
    }
    throw const FormatException('bad bzip2 block magic');
  }

  void decodeBlock() {
    if (bit() != 0) {
      throw const FormatException('randomised bzip2 blocks are not supported');
    }
    origPtr = bits(24);
    // Symbol map.
    final inUse16 = bits(16);
    final seqToUnseq = Uint8List(256);
    var nInUse = 0;
    for (var i = 0; i < 16; i++) {
      if (inUse16 & (0x8000 >> i) != 0) {
        final v = bits(16);
        for (var j = 0; j < 16; j++) {
          if (v & (0x8000 >> j) != 0) seqToUnseq[nInUse++] = i * 16 + j;
        }
      }
    }
    if (nInUse == 0) throw const FormatException('bzip2 block uses no symbols');
    final alphaSize = nInUse + 2;
    final nGroups = bits(3);
    if (nGroups < 2 || nGroups > 6) {
      throw const FormatException('bad bzip2 group count');
    }
    final nSelectorsRaw = bits(15);
    if (nSelectorsRaw < 1) throw const FormatException('bad selector count');
    final nSelectors = nSelectorsRaw > 18002 ? 18002 : nSelectorsRaw;
    final selectors = Uint8List(nSelectors);
    final mtfGroups = List<int>.generate(nGroups, (i) => i);
    for (var i = 0; i < nSelectorsRaw; i++) {
      var j = 0;
      while (bit() == 1) {
        j++;
        if (j >= nGroups) throw const FormatException('bad selector');
      }
      if (i < nSelectors) {
        final v = mtfGroups[j];
        for (var k = j; k > 0; k--) {
          mtfGroups[k] = mtfGroups[k - 1];
        }
        mtfGroups[0] = v;
        selectors[i] = v;
      }
    }
    // Coding tables.
    final limit = List.generate(nGroups, (_) => Int32List(24));
    final base = List.generate(nGroups, (_) => Int32List(24));
    final perm = List.generate(nGroups, (_) => Int32List(258));
    final minLens = Int32List(nGroups);
    final len = Uint8List(alphaSize);
    for (var t = 0; t < nGroups; t++) {
      var curr = bits(5);
      for (var i = 0; i < alphaSize; i++) {
        while (true) {
          if (curr < 1 || curr > 20) {
            throw const FormatException('bad bzip2 code length');
          }
          if (bit() == 0) break;
          curr += bit() == 0 ? 1 : -1;
        }
        len[i] = curr;
      }
      var minLen = 32, maxLen = 0;
      for (var i = 0; i < alphaSize; i++) {
        if (len[i] > maxLen) maxLen = len[i];
        if (len[i] < minLen) minLen = len[i];
      }
      _createDecodeTables(limit[t], base[t], perm[t], len, minLen, maxLen,
          alphaSize);
      minLens[t] = minLen;
    }

    // MTF + RLE2 decode into tt (low byte = symbol).
    final eob = nInUse + 1;
    final nblockMax = blockSize100k * 100000;
    final unzftab = Int32List(256);
    final yy = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      yy[i] = i;
    }
    var groupNo = -1;
    var groupPos = 0;
    Int32List gLimit = limit[0], gBase = base[0], gPerm = perm[0];
    var gMinLen = 0;
    int nextSym() {
      if (groupPos == 0) {
        groupNo++;
        if (groupNo >= nSelectors) {
          throw const FormatException('bzip2 selector overflow');
        }
        groupPos = 50;
        final g = selectors[groupNo];
        gLimit = limit[g];
        gBase = base[g];
        gPerm = perm[g];
        gMinLen = minLens[g];
      }
      groupPos--;
      var zn = gMinLen;
      var zvec = bits(zn);
      while (true) {
        if (zn > 20) throw const FormatException('bad bzip2 code');
        if (zvec <= gLimit[zn]) break;
        zn++;
        zvec = (zvec << 1) | bit();
      }
      final idx = zvec - gBase[zn];
      if (idx < 0 || idx >= 258) throw const FormatException('bad bzip2 code');
      return gPerm[idx];
    }

    final tt = this.tt;
    var nb = 0;
    var sym = nextSym();
    while (true) {
      if (sym == eob) break;
      if (sym <= 1) {
        var es = -1;
        var n = 1;
        do {
          if (n >= 2 * 1024 * 1024) {
            throw const FormatException('bzip2 run too long');
          }
          es += (sym + 1) * n;
          n <<= 1;
          sym = nextSym();
        } while (sym <= 1);
        es++;
        final uc = seqToUnseq[yy[0]];
        unzftab[uc] += es;
        if (nb + es > nblockMax) {
          throw const FormatException('bzip2 block overflow');
        }
        for (var k = 0; k < es; k++) {
          tt[nb++] = uc;
        }
        continue;
      }
      if (nb >= nblockMax) throw const FormatException('bzip2 block overflow');
      final nn = sym - 1;
      final uc = yy[nn];
      for (var k = nn; k > 0; k--) {
        yy[k] = yy[k - 1];
      }
      yy[0] = uc;
      final b = seqToUnseq[uc];
      unzftab[b]++;
      tt[nb++] = b;
      sym = nextSym();
    }
    if (origPtr < 0 || origPtr >= nb) {
      throw const FormatException('bad bzip2 origin pointer');
    }
    // Inverse BWT links.
    final cftab = Int32List(257);
    for (var i = 1; i <= 256; i++) {
      cftab[i] = cftab[i - 1] + unzftab[i - 1];
    }
    for (var i = 0; i < nb; i++) {
      final uc = tt[i] & 0xFF;
      tt[cftab[uc]] |= i << 8;
      cftab[uc]++;
    }
    nblock = nb;
  }

  static void _createDecodeTables(
    Int32List limit,
    Int32List base,
    Int32List perm,
    Uint8List length,
    int minLen,
    int maxLen,
    int alphaSize,
  ) {
    var pp = 0;
    for (var i = minLen; i <= maxLen; i++) {
      for (var j = 0; j < alphaSize; j++) {
        if (length[j] == i) perm[pp++] = j;
      }
    }
    for (var i = 0; i < 23; i++) {
      base[i] = 0;
    }
    for (var i = 0; i < alphaSize; i++) {
      base[length[i] + 1]++;
    }
    for (var i = 1; i < 23; i++) {
      base[i] += base[i - 1];
    }
    for (var i = 0; i < 23; i++) {
      limit[i] = 0;
    }
    var vec = 0;
    for (var i = minLen; i <= maxLen; i++) {
      vec += base[i + 1] - base[i];
      limit[i] = vec - 1;
      vec <<= 1;
    }
    for (var i = minLen + 1; i <= maxLen; i++) {
      base[i] = ((limit[i - 1] + 1) << 1) - base[i];
    }
  }

  /// Walks the BWT chain, undoes the initial RLE and checks the block CRC.
  Iterable<Uint8List> output() sync* {
    const chunk = 1 << 18;
    var out = Uint8List(chunk);
    var o = 0;
    var crc = 0xFFFFFFFF;
    final table = _crcTable;
    var tPos = tt[origPtr] >> 8;
    var last = -1;
    var run = 0;
    for (var k = 0; k < nblock; k++) {
      tPos = tt[tPos];
      final b = tPos & 0xFF;
      tPos >>= 8;
      if (run == 4) {
        for (var c = 0; c < b; c++) {
          if (o == chunk) {
            yield out;
            out = Uint8List(chunk);
            o = 0;
          }
          out[o++] = last;
          crc = ((crc << 8) ^ table[((crc >> 24) ^ last) & 0xFF]) & 0xFFFFFFFF;
        }
        run = 0;
        last = -1;
        continue;
      }
      if (o == chunk) {
        yield out;
        out = Uint8List(chunk);
        o = 0;
      }
      out[o++] = b;
      crc = ((crc << 8) ^ table[((crc >> 24) ^ b) & 0xFF]) & 0xFFFFFFFF;
      if (b == last) {
        run++;
      } else {
        last = b;
        run = 1;
      }
    }
    if (o > 0) yield Uint8List.sublistView(out, 0, o);
    crc = (~crc) & 0xFFFFFFFF;
    if (crc != blockCrc) throw const FormatException('bzip2 block CRC mismatch');
    combinedCrc = (((combinedCrc << 1) | (combinedCrc >>> 31)) ^ crc) &
        0xFFFFFFFF;
  }
}

// ---------------------------------------------------------------------------
// XZ / LZMA2
// ---------------------------------------------------------------------------

/// XZ container (multi-stream) with LZMA2 and optional delta filter.
Stream<Uint8List> xzStream(Stream<Uint8List> input) async* {
  final r = _ChunkReader(input);
  try {
    var streams = 0;
    while (true) {
      if (streams > 0) {
        // Stream padding (zero bytes in groups of four), then maybe another.
        while (await r.hasMore() && r.buf[r.pos] == 0) {
          r.pos++;
        }
        if (!await r.hasMore()) break;
      }
      final header = await r.readExact(12);
      const magic = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00];
      for (var i = 0; i < 6; i++) {
        if (header[i] != magic[i]) throw const FormatException('not an XZ stream');
      }
      final checkType = header[7] & 0x0F;
      final checkSize = switch (checkType) {
        0 => 0,
        1 => 4,
        4 => 8,
        10 => 32,
        _ => throw FormatException('unsupported XZ check type $checkType'),
      };
      streams++;
      while (true) {
        final sizeByte = await r.readByte();
        if (sizeByte == 0) {
          await _skipXzIndex(r);
          break;
        }
        final hdr = await r.readExact((sizeByte + 1) * 4 - 1);
        final block = _XzBlockHeader.parse(sizeByte, hdr);
        final lz = _Lzma2(block.dictSize);
        final check = _XzCheck(checkType);
        final delta = block.deltaDistance == null
            ? null
            : _DeltaDecoder(block.deltaDistance!);
        var produced = 0;
        await for (final out in lz.decode(r)) {
          if (delta != null) delta.decode(out);
          check.add(out);
          produced += out.length;
          yield out;
        }
        if (block.uncompressedSize != null &&
            block.uncompressedSize != produced) {
          throw const FormatException('XZ block size mismatch');
        }
        // Block padding to a multiple of four.
        final unpadded = lz.consumed + (sizeByte + 1) * 4;
        final pad = (4 - unpadded % 4) % 4;
        if (pad > 0) await r.readExact(pad);
        if (checkSize > 0) {
          final stored = await r.readExact(checkSize);
          if (!check.matches(stored)) {
            throw const FormatException('XZ block checksum mismatch');
          }
        }
      }
      // Stream footer.
      final footer = await r.readExact(12);
      if (footer[10] != 0x59 || footer[11] != 0x5A) {
        throw const FormatException('bad XZ stream footer');
      }
    }
  } finally {
    await r.cancel();
  }
}

Future<int> _readVarInt(_ChunkReader r) async {
  var value = 0;
  for (var i = 0; i < 9; i++) {
    final b = await r.readByte();
    value |= (b & 0x7F) << (7 * i);
    if (b & 0x80 == 0) return value;
  }
  throw const FormatException('bad XZ integer');
}

Future<void> _skipXzIndex(_ChunkReader r) async {
  var size = 1; // the indicator byte already read
  final count = await _readVarInt(r);
  size += _varIntSize(count);
  for (var i = 0; i < count; i++) {
    final a = await _readVarInt(r);
    final b = await _readVarInt(r);
    size += _varIntSize(a) + _varIntSize(b);
  }
  final pad = (4 - size % 4) % 4;
  await r.readExact(pad + 4); // padding + CRC32
}

int _varIntSize(int v) {
  var n = 1;
  while (v >= 0x80) {
    v >>= 7;
    n++;
  }
  return n;
}

class _XzBlockHeader {
  _XzBlockHeader(this.dictSize, this.uncompressedSize, this.deltaDistance);

  final int dictSize;
  final int? uncompressedSize;
  final int? deltaDistance;

  static _XzBlockHeader parse(int sizeByte, Uint8List h) {
    // h excludes the size byte; the last four bytes are its CRC32.
    final crc = Crc32()
      ..add(Uint8List.fromList([sizeByte]))
      ..add(h, 0, h.length - 4);
    final stored = ByteData.sublistView(h, h.length - 4).getUint32(0, Endian.little);
    if (crc.value != stored) throw const FormatException('XZ block header CRC');
    var p = 0;
    int varint() {
      var v = 0;
      for (var i = 0; i < 9; i++) {
        final b = h[p++];
        v |= (b & 0x7F) << (7 * i);
        if (b & 0x80 == 0) return v;
      }
      throw const FormatException('bad XZ integer');
    }

    final flags = h[p++];
    final nFilters = (flags & 3) + 1;
    if (flags & 0x40 != 0) varint(); // compressed size
    final uncompressed = flags & 0x80 != 0 ? varint() : null;
    int? dict;
    int? delta;
    for (var i = 0; i < nFilters; i++) {
      final id = varint();
      final propSize = varint();
      final props = Uint8List.sublistView(h, p, p + propSize);
      p += propSize;
      if (id == 0x21) {
        if (i != nFilters - 1 || propSize != 1) {
          throw const FormatException('bad LZMA2 filter');
        }
        final bits = props[0] & 0x3F;
        if (bits > 40) throw const FormatException('bad LZMA2 dictionary');
        dict = bits == 40 ? 0xFFFFFFFF : (2 | (bits & 1)) << (bits ~/ 2 + 11);
      } else if (id == 0x03 && propSize == 1) {
        delta = props[0] + 1;
      } else {
        throw FormatException(
          'XZ filter 0x${id.toRadixString(16)} is not supported',
        );
      }
    }
    if (dict == null) throw const FormatException('XZ block without LZMA2');
    return _XzBlockHeader(dict, uncompressed, delta);
  }
}

class _DeltaDecoder {
  _DeltaDecoder(this.distance);
  final int distance;
  final Uint8List _hist = Uint8List(256);
  int _pos = 0;

  void decode(Uint8List data) {
    for (var i = 0; i < data.length; i++) {
      final b = (data[i] + _hist[(_pos - distance) & 0xFF]) & 0xFF;
      data[i] = b;
      _hist[_pos & 0xFF] = b;
      _pos++;
    }
  }
}

class _XzCheck {
  _XzCheck(this.type);
  final int type;
  final Crc32 _crc32 = Crc32();
  int _crc64 = -1; // all ones
  final Sha256 _sha = Sha256();

  static final List<int> _crc64Table = () {
    const poly = 0xC96C5795D7870F42;
    final t = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (c >>> 1) ^ poly : c >>> 1;
      }
      t[i] = c;
    }
    return t;
  }();

  void add(Uint8List data) {
    switch (type) {
      case 1:
        _crc32.add(data);
      case 4:
        var c = _crc64;
        final t = _crc64Table;
        for (var i = 0; i < data.length; i++) {
          c = t[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
        }
        _crc64 = c;
      case 10:
        _sha.add(data);
    }
  }

  bool matches(Uint8List stored) {
    switch (type) {
      case 1:
        return ByteData.sublistView(stored).getUint32(0, Endian.little) ==
            _crc32.value;
      case 4:
        final v = ~_crc64;
        for (var i = 0; i < 8; i++) {
          if (stored[i] != (v >>> (8 * i)) & 0xFF) return false;
        }
        return true;
      case 10:
        final d = _sha.finish();
        for (var i = 0; i < 32; i++) {
          if (d[i] != stored[i]) return false;
        }
        return true;
    }
    return true;
  }
}

/// LZMA2 chunk decoder over a ring dictionary.
class _Lzma2 {
  _Lzma2(int dictSize)
    : dictSize = dictSize,
      win = _Window(dictSize < (1 << 20) ? 1 << 20 : dictSize);

  final int dictSize;
  final _Window win;
  final _Lzma lzma = _Lzma();
  int consumed = 0; // compressed bytes read for this block
  int dictStart = 0;
  bool needDictReset = true;
  bool needProps = true;

  Stream<Uint8List> decode(_ChunkReader r) async* {
    while (true) {
      final control = await r.readByte();
      consumed++;
      if (control == 0) break;
      if (control == 1 || control == 2) {
        if (control == 1) {
          dictStart = win.pos;
          needDictReset = false;
        } else if (needDictReset) {
          throw const FormatException('LZMA2 dictionary not reset');
        }
        final sizeBytes = await r.readExact(2);
        final size = ((sizeBytes[0] << 8) | sizeBytes[1]) + 1;
        consumed += 2;
        final data = await r.readExact(size);
        consumed += size;
        win.putAll(data, 0, size);
        yield win.take();
        continue;
      }
      if (control < 0x80) throw const FormatException('bad LZMA2 control');
      final hdr = await r.readExact(4);
      consumed += 4;
      final unpacked = ((control & 0x1F) << 16) + (hdr[0] << 8) + hdr[1] + 1;
      final packed = (hdr[2] << 8) + hdr[3] + 1;
      final reset = (control >> 5) & 3;
      if (reset == 3) {
        dictStart = win.pos;
        needDictReset = false;
      } else if (needDictReset) {
        throw const FormatException('LZMA2 dictionary not reset');
      }
      if (reset >= 2) {
        final props = await r.readByte();
        consumed++;
        lzma.setProps(props);
        needProps = false;
      } else if (needProps) {
        throw const FormatException('LZMA2 chunk without properties');
      }
      if (reset >= 1) lzma.resetState();
      final data = await r.readExact(packed);
      consumed += packed;
      // Copy: the reader's buffer may be reused by the next fill.
      for (final out in lzma.decodeChunk(
        Uint8List.fromList(data),
        win,
        unpacked,
        dictStart,
        dictSize,
      )) {
        yield out;
      }
    }
  }
}

/// LZMA symbol decoder (spec: LzmaSpec.cpp, public domain).
class _Lzma {
  int lc = 0, lp = 0, pb = 0;
  Uint16List literal = Uint16List(0x300);
  final Uint16List isMatch = Uint16List(12 << 4);
  final Uint16List isRep = Uint16List(12);
  final Uint16List isRepG0 = Uint16List(12);
  final Uint16List isRepG1 = Uint16List(12);
  final Uint16List isRepG2 = Uint16List(12);
  final Uint16List isRep0Long = Uint16List(12 << 4);
  final Uint16List posSlot = Uint16List(4 << 6);
  final Uint16List posSpecial = Uint16List(115);
  final Uint16List align = Uint16List(16);
  final _LenDecoder lenDec = _LenDecoder();
  final _LenDecoder repLenDec = _LenDecoder();
  int state = 0;
  int rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0;

  // Range decoder.
  late Uint8List _in;
  int _ip = 0;
  int range = 0;
  int code = 0;

  void setProps(int d) {
    if (d >= 225) throw const FormatException('bad LZMA properties');
    lc = d % 9;
    d ~/= 9;
    lp = d % 5;
    pb = d ~/ 5;
    if (lc + lp > 4) throw const FormatException('bad LZMA2 properties');
    literal = Uint16List(0x300 << (lc + lp));
  }

  void resetState() {
    for (final p in [
      literal, isMatch, isRep, isRepG0, isRepG1, isRepG2, isRep0Long, //
      posSlot, posSpecial, align,
    ]) {
      p.fillRange(0, p.length, 1024);
    }
    lenDec.reset();
    repLenDec.reset();
    state = 0;
    rep0 = rep1 = rep2 = rep3 = 0;
  }

  int _byte() {
    if (_ip >= _in.length) throw const FormatException('truncated LZMA data');
    return _in[_ip++];
  }

  int bit(Uint16List probs, int i) {
    final p = probs[i];
    final bound = (range >>> 11) * p;
    int b;
    if (code < bound) {
      range = bound;
      probs[i] = p + ((2048 - p) >> 5);
      b = 0;
    } else {
      range -= bound;
      code -= bound;
      probs[i] = p - (p >> 5);
      b = 1;
    }
    if (range < 0x1000000) {
      range = (range << 8) & 0xFFFFFFFF;
      code = ((code << 8) | _byte()) & 0xFFFFFFFF;
    }
    return b;
  }

  int bitTree(Uint16List probs, int offset, int numBits) {
    var m = 1;
    for (var i = 0; i < numBits; i++) {
      m = (m << 1) + bit(probs, offset + m);
    }
    return m - (1 << numBits);
  }

  int reverseBitTree(Uint16List probs, int offset, int numBits) {
    var m = 1;
    var sym = 0;
    for (var i = 0; i < numBits; i++) {
      final b = bit(probs, offset + m);
      m = (m << 1) + b;
      sym |= b << i;
    }
    return sym;
  }

  int directBits(int numBits) {
    var res = 0;
    for (var i = 0; i < numBits; i++) {
      range >>>= 1;
      int b;
      if (code >= range) {
        code -= range;
        b = 1;
      } else {
        b = 0;
      }
      res = (res << 1) | b;
      if (range < 0x1000000) {
        range = (range << 8) & 0xFFFFFFFF;
        code = ((code << 8) | _byte()) & 0xFFFFFFFF;
      }
    }
    return res;
  }

  /// Decodes one LZMA2 chunk of [unpacked] bytes from [data] into [win].
  Iterable<Uint8List> decodeChunk(
    Uint8List data,
    _Window win,
    int unpacked,
    int dictStart,
    int dictSize,
  ) sync* {
    _in = data;
    _ip = 0;
    if (_byte() != 0) throw const FormatException('bad LZMA range coder');
    code = 0;
    for (var i = 0; i < 4; i++) {
      code = (code << 8) | _byte();
    }
    range = 0xFFFFFFFF;
    final end = win.pos + unpacked;
    final pbMask = (1 << pb) - 1;
    final lpMask = (1 << lp) - 1;
    final wdata = win.data;
    final wmask = win.mask;
    while (win.pos < end) {
      final pos = win.pos;
      final rel = pos - dictStart;
      final posState = rel & pbMask;
      if (bit(isMatch, (state << 4) + posState) == 0) {
        // Literal.
        final prev = pos > dictStart ? wdata[(pos - 1) & wmask] : 0;
        final base = 0x300 * (((rel & lpMask) << lc) + (prev >> (8 - lc)));
        int sym;
        if (state >= 7) {
          var matchByte = wdata[(pos - rep0 - 1) & wmask];
          sym = 1;
          while (sym < 0x100) {
            final matchBit = (matchByte >> 7) & 1;
            matchByte <<= 1;
            final b = bit(literal, base + ((1 + matchBit) << 8) + sym);
            sym = (sym << 1) | b;
            if (matchBit != b) break;
          }
          while (sym < 0x100) {
            sym = (sym << 1) | bit(literal, base + sym);
          }
        } else {
          sym = 1;
          while (sym < 0x100) {
            sym = (sym << 1) | bit(literal, base + sym);
          }
        }
        wdata[win.pos++ & wmask] = sym & 0xFF;
        state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6);
      } else {
        int len;
        if (bit(isRep, state) == 1) {
          if (rel == 0) {
            throw const FormatException('LZMA rep match at start');
          }
          if (bit(isRepG0, state) == 0) {
            if (bit(isRep0Long, (state << 4) + posState) == 0) {
              // Short rep: one byte at rep0.
              state = state < 7 ? 9 : 11;
              wdata[win.pos & wmask] = wdata[(win.pos - rep0 - 1) & wmask];
              win.pos++;
              if (win.pending >= 1 << 18) yield win.take();
              continue;
            }
          } else {
            int dist;
            if (bit(isRepG1, state) == 0) {
              dist = rep1;
            } else {
              if (bit(isRepG2, state) == 0) {
                dist = rep2;
              } else {
                dist = rep3;
                rep3 = rep2;
              }
              rep2 = rep1;
            }
            rep1 = rep0;
            rep0 = dist;
          }
          len = repLenDec.decode(this, posState);
          state = state < 7 ? 8 : 11;
        } else {
          rep3 = rep2;
          rep2 = rep1;
          rep1 = rep0;
          len = lenDec.decode(this, posState);
          state = state < 7 ? 7 : 10;
          // Distance.
          final lenState = len < 4 ? len : 3;
          final slot = bitTree(posSlot, lenState << 6, 6);
          if (slot < 4) {
            rep0 = slot;
          } else {
            final numDirect = (slot >> 1) - 1;
            var dist = (2 | (slot & 1)) << numDirect;
            if (slot < 14) {
              dist += reverseBitTree(posSpecial, dist - slot, numDirect);
            } else {
              dist += directBits(numDirect - 4) << 4;
              dist += reverseBitTree(align, 0, 4);
            }
            rep0 = dist & 0xFFFFFFFF;
          }
          if (rep0 == 0xFFFFFFFF) {
            throw const FormatException('LZMA end marker inside LZMA2');
          }
        }
        len += 2;
        final dist = rep0 + 1;
        if (dist > rel || dist > dictSize) {
          throw const FormatException('LZMA distance out of range');
        }
        if (win.pos + len > end) {
          throw const FormatException('LZMA match past chunk end');
        }
        win.copy(dist, len);
      }
      if (win.pending >= 1 << 18) yield win.take();
    }
    if (win.pending > 0) yield win.take();
  }
}

class _LenDecoder {
  final Uint16List choice = Uint16List(2);
  final Uint16List low = Uint16List(16 << 3);
  final Uint16List mid = Uint16List(16 << 3);
  final Uint16List high = Uint16List(256);

  void reset() {
    for (final p in [choice, low, mid, high]) {
      p.fillRange(0, p.length, 1024);
    }
  }

  int decode(_Lzma rc, int posState) {
    if (rc.bit(choice, 0) == 0) return rc.bitTree(low, posState << 3, 3);
    if (rc.bit(choice, 1) == 0) return 8 + rc.bitTree(mid, posState << 3, 3);
    return 16 + rc.bitTree(high, 0, 8);
  }
}
