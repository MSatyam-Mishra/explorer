/// Pure-Dart Zstandard decoder (RFC 8878).
///
/// Decodes everything a conforming zstd encoder emits (all compression
/// levels, long-distance matching, with or without content checksum and
/// content size, single-segment frames, any window size): raw, RLE and
/// compressed blocks; raw, RLE, Huffman-compressed (1 or 4 streams) and
/// treeless literals; predefined, RLE, FSE-compressed and repeat sequence
/// tables; repeat offsets. Several concatenated frames are decoded one after
/// another and skippable frames (e.g. the seek table appended by Blender's
/// zstd "seekable" format) are skipped.
///
/// Dictionaries are not supported: a frame that names a non-zero dictionary
/// ID is rejected. Malformed input throws [FormatException].
library;

import 'dart:typed_data';

/// Returns true if [bytes] starts with a zstd frame (magic 0xFD2FB528,
/// stored little-endian as `28 B5 2F FD`).
bool isZstd(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x28 &&
    bytes[1] == 0xB5 &&
    bytes[2] == 0x2F &&
    bytes[3] == 0xFD;

/// Decompresses all frames in [input] (concatenated), skipping skippable
/// frames (magic 0x184D2A50..0x184D2A5F).
///
/// Throws [FormatException] on corrupt or unsupported input (including a
/// dictionary-compressed frame or a failed content checksum). [maxOutput]
/// bounds the decompressed size (default 2 GiB) to guard against
/// decompression bombs; exceeding it also throws [FormatException].
Uint8List zstdDecompress(Uint8List input, {int maxOutput = 1 << 31}) {
  if (maxOutput < 0) {
    throw ArgumentError.value(maxOutput, 'maxOutput', 'must not be negative');
  }
  try {
    return _ZstdDecoder(input, maxOutput).run();
  } on FormatException {
    rethrow;
  } on ArgumentError catch (e) {
    // RangeError/IndexError: a malformed stream read or wrote out of bounds.
    throw FormatException('zstd: corrupt input (${e.message ?? e})');
  }
}

Never _corrupt(String message) => throw FormatException('zstd: $message');

const int _frameMagic = 0xFD2FB528;
const int _skippableMagicMask = 0xFFFFFFF0;
const int _skippableMagic = 0x184D2A50;

/// Absolute maximum size of a block (compressed or regenerated): 128 KiB.
const int _blockSizeMax = 1 << 17;

const int _maxLlSymbol = 35;
const int _maxMlSymbol = 52;
const int _maxOfSymbol = 31;
const int _maxLlLog = 9;
const int _maxMlLog = 9;
const int _maxOfLog = 8;

/// Huffman codes never exceed 11 bits per the RFC; libzstd's decoder accepts
/// up to 12, and so do we.
const int _maxHuffBits = 12;

// ---------------------------------------------------------------------------
// Sequence code tables (RFC 8878 3.1.1.3.2.1.1 / appendix A).

final Int32List _llBase = Int32List.fromList(const [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
]);

final Uint8List _llBits = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
]);

final Int32List _mlBase = Int32List.fromList(const [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, //
  19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
  35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
  4099, 8195, 16387, 32771, 65539,
]);

final Uint8List _mlBits = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
  12, 13, 14, 15, 16,
]);

// Predefined FSE distributions (RFC 8878 3.1.1.3.2.2).
final _FseTable _predefinedLl = _buildFseTable(
  Int16List.fromList(const [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1,
  ]),
  36,
  6,
);

final _FseTable _predefinedMl = _buildFseTable(
  Int16List.fromList(const [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1,
  ]),
  53,
  6,
);

final _FseTable _predefinedOf = _buildFseTable(
  Int16List.fromList(const [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
  ]),
  29,
  5,
);

// ---------------------------------------------------------------------------
// FSE tables.

/// An FSE decoding table. Each entry packs
/// `baseline << 16 | numberOfBits << 8 | symbol`.
final class _FseTable {
  _FseTable(this.accuracyLog, this.entries);

  /// A single-state table that always yields [symbol] (RLE mode).
  factory _FseTable.rle(int symbol) => _FseTable(0, Int32List(1)..[0] = symbol);

  final int accuracyLog;
  final Int32List entries;
}

/// Builds the decoding table for normalized counts [norm] (RFC 8878 4.1.1).
_FseTable _buildFseTable(Int16List norm, int symbolCount, int accuracyLog) {
  final size = 1 << accuracyLog;
  final symbols = Uint8List(size);
  final next = Int32List(symbolCount);
  var high = size - 1;
  for (var s = 0; s < symbolCount; s++) {
    if (norm[s] == -1) {
      if (high < 0) _corrupt('invalid FSE distribution');
      symbols[high--] = s;
      next[s] = 1;
    }
  }
  final step = (size >> 1) + (size >> 3) + 3;
  final mask = size - 1;
  var pos = 0;
  for (var s = 0; s < symbolCount; s++) {
    final n = norm[s];
    if (n <= 0) continue;
    if (high < 0) _corrupt('invalid FSE distribution');
    next[s] = n;
    for (var i = 0; i < n; i++) {
      symbols[pos] = s;
      do {
        pos = (pos + step) & mask;
      } while (pos > high);
    }
  }
  if (pos != 0) _corrupt('invalid FSE distribution');
  final entries = Int32List(size);
  for (var i = 0; i < size; i++) {
    final s = symbols[i];
    final x = next[s]++;
    final nb = accuracyLog - (x.bitLength - 1);
    entries[i] = (((x << nb) - size) << 16) | (nb << 8) | s;
  }
  return _FseTable(accuracyLog, entries);
}

/// Up to 25 bits of the little-endian forward bitstream `src[pos..end)`
/// starting at [bitPos]; bytes past [end] read as zero.
int _forwardBits(Uint8List src, int pos, int end, int bitPos) {
  final i = pos + (bitPos >> 3);
  var v = 0;
  for (var k = 0; k < 4; k++) {
    final j = i + k;
    if (j < end) v |= src[j] << (k << 3);
  }
  return v >>> (bitPos & 7);
}

/// Reads an FSE table description (RFC 8878 4.1.1) from `src[pos..end)`.
/// Returns the table and the number of bytes consumed.
(_FseTable, int) _readFseTable(
  Uint8List src,
  int pos,
  int end,
  int maxSymbol,
  int maxLog,
) {
  if (pos >= end) _corrupt('truncated FSE table description');
  final accuracyLog = (src[pos] & 15) + 5;
  if (accuracyLog > maxLog) _corrupt('FSE accuracy log too large');
  final norm = Int16List(maxSymbol + 1);
  var bitPos = 4;
  var remaining = 1 << accuracyLog;
  var symbols = 0;
  while (remaining > 0) {
    if (symbols > maxSymbol) _corrupt('too many FSE symbols');
    final bits = (remaining + 1).bitLength;
    final lowerMask = (1 << (bits - 1)) - 1;
    final threshold = (1 << bits) - 1 - (remaining + 1);
    var v = _forwardBits(src, pos, end, bitPos) & ((1 << bits) - 1);
    if ((v & lowerMask) < threshold) {
      v &= lowerMask;
      bitPos += bits - 1;
    } else {
      if (v > lowerMask) v -= threshold;
      bitPos += bits;
    }
    final p = v - 1;
    remaining -= p < 0 ? -p : p;
    norm[symbols++] = p;
    if (p == 0) {
      while (true) {
        final repeat = _forwardBits(src, pos, end, bitPos) & 3;
        bitPos += 2;
        for (var k = 0; k < repeat; k++) {
          if (symbols > maxSymbol) _corrupt('too many FSE symbols');
          norm[symbols++] = 0;
        }
        if (repeat != 3) break;
      }
    }
  }
  if (remaining != 0) _corrupt('invalid FSE distribution');
  final used = (bitPos + 7) >> 3;
  if (pos + used > end) _corrupt('truncated FSE table description');
  return (_buildFseTable(norm, symbols, accuracyLog), used);
}

// ---------------------------------------------------------------------------
// Backward bitstream (RFC 8878 4.1 / 4.2.2): read from the last byte towards
// the first, starting just below the highest set bit of the last byte.

/// Loads the 8 bytes at [p] as a little-endian 64-bit container; bytes before
/// [start] read as zero (the caller guarantees `p + 8 <= end of stream`).
int _loadBack(Uint8List src, ByteData bd, int start, int p) {
  if (p >= start) return bd.getUint64(p, Endian.little);
  var v = 0;
  for (var i = 7; i >= 0; i--) {
    final j = p + i;
    v = (v << 8) | (j >= start ? src[j] : 0);
  }
  return v;
}

final class _BackBits {
  _BackBits(this._src, this._bd, this._start, int end) {
    if (end <= _start) _corrupt('empty bitstream');
    final last = _src[end - 1];
    if (last == 0) _corrupt('bitstream lacks its end marker');
    _ptr = end - 8;
    _bits = _loadBack(_src, _bd, _start, _ptr);
    _consumed = 9 - last.bitLength;
  }

  final Uint8List _src;
  final ByteData _bd;
  final int _start;

  /// Start of the 8 bytes currently held in [_bits].
  int _ptr = 0;
  int _bits = 0;

  /// Bits already consumed from the top of [_bits].
  int _consumed = 0;

  /// Bits not yet read; negative once reading went past the stream start.
  int get bitsLeft => ((_ptr - _start) << 3) + 64 - _consumed;

  /// Reads [n] (0..56) bits.
  int read(int n) {
    if (_consumed + n > 64) {
      _ptr -= _consumed >> 3;
      _consumed &= 7;
      _bits = _loadBack(_src, _bd, _start, _ptr);
    }
    final v = (_bits << _consumed) >>> (64 - n);
    _consumed += n;
    return v;
  }
}

// ---------------------------------------------------------------------------
// Huffman tables (RFC 8878 4.2).

final class _HuffTable {
  _HuffTable(this.maxBits, this.table);

  final int maxBits;

  /// Indexed by the next [maxBits] bits: `symbol | numberOfBits << 8`.
  final Uint16List table;
}

/// Decodes FSE-compressed Huffman weights from `src[start..end)` into
/// [weights]; returns the number of weights decoded.
int _decodeHuffWeights(
  Uint8List src,
  ByteData bd,
  int start,
  int end,
  _FseTable fse,
  Uint8List weights,
) {
  final br = _BackBits(src, bd, start, end);
  final t = fse.entries;
  var s1 = br.read(fse.accuracyLog);
  var s2 = br.read(fse.accuracyLog);
  var n = 0;
  while (true) {
    if (n > 253) _corrupt('too many Huffman weights');
    var e = t[s1];
    weights[n++] = e;
    s1 = (e >> 16) + br.read((e >> 8) & 0xFF);
    if (br.bitsLeft < 0) {
      weights[n++] = t[s2];
      break;
    }
    if (n > 253) _corrupt('too many Huffman weights');
    e = t[s2];
    weights[n++] = e;
    s2 = (e >> 16) + br.read((e >> 8) & 0xFF);
    if (br.bitsLeft < 0) {
      weights[n++] = t[s1];
      break;
    }
  }
  return n;
}

/// Reads a Huffman tree description from `src[pos..end)`; returns the table
/// and the number of bytes consumed.
(_HuffTable, int) _readHuffTable(Uint8List src, ByteData bd, int pos, int end) {
  if (pos >= end) _corrupt('truncated Huffman tree description');
  final header = src[pos];
  final weights = Uint8List(257);
  int n;
  int used;
  if (header >= 128) {
    n = header - 127;
    used = 1 + ((n + 1) >> 1);
    if (pos + used > end) _corrupt('truncated Huffman weights');
    for (var i = 0; i < n; i++) {
      final b = src[pos + 1 + (i >> 1)];
      weights[i] = i.isEven ? b >> 4 : b & 15;
    }
  } else {
    if (header == 0) _corrupt('empty Huffman weights');
    used = 1 + header;
    if (pos + used > end) _corrupt('truncated Huffman weights');
    final (fse, fseUsed) = _readFseTable(src, pos + 1, pos + used, 255, 6);
    n = _decodeHuffWeights(
      src,
      bd,
      pos + 1 + fseUsed,
      pos + used,
      fse,
      weights,
    );
  }

  var sum = 0;
  for (var i = 0; i < n; i++) {
    final w = weights[i];
    if (w > _maxHuffBits) _corrupt('invalid Huffman weight');
    if (w > 0) sum += 1 << (w - 1);
  }
  if (sum == 0) _corrupt('invalid Huffman weights');
  final maxBits = sum.bitLength;
  if (maxBits > _maxHuffBits) _corrupt('Huffman table too deep');
  final leftover = (1 << maxBits) - sum;
  if (leftover & (leftover - 1) != 0) _corrupt('invalid Huffman weights');
  weights[n++] = leftover.bitLength;

  // Canonical code assignment: longest codes first, symbols in natural
  // order within the same length.
  final rankCount = Int32List(maxBits + 2);
  for (var s = 0; s < n; s++) {
    final w = weights[s];
    if (w > 0) rankCount[maxBits + 1 - w]++;
  }
  final rankStart = Int32List(maxBits + 2);
  for (var b = maxBits; b >= 1; b--) {
    rankStart[b - 1] = rankStart[b] + (rankCount[b] << (maxBits - b));
  }
  if (rankStart[0] != 1 << maxBits) _corrupt('invalid Huffman weights');
  final table = Uint16List(1 << maxBits);
  for (var s = 0; s < n; s++) {
    final w = weights[s];
    if (w == 0) continue;
    final nb = maxBits + 1 - w;
    final code = rankStart[nb];
    final len = 1 << (maxBits - nb);
    table.fillRange(code, code + len, s | (nb << 8));
    rankStart[nb] = code + len;
  }
  return (_HuffTable(maxBits, table), used);
}

// ---------------------------------------------------------------------------
// XXH64 (seed 0), used for the frame content checksum.

const int _xxP1 = 0x9E3779B185EBCA87;
const int _xxP2 = 0xC2B2AE3D27D4EB4F;
const int _xxP3 = 0x165667B19E3779F9;
const int _xxP4 = 0x85EBCA77C2B2AE63;
const int _xxP5 = 0x27D4EB2F165667C5;

int _rotl64(int x, int r) => (x << r) | (x >>> (64 - r));

int _xxRound(int acc, int input) => _rotl64(acc + input * _xxP2, 31) * _xxP1;

int _xxMerge(int acc, int v) => (acc ^ _xxRound(0, v)) * _xxP1 + _xxP4;

/// XXH64 (seed 0) of `data[start..end)`, as a wrapped 64-bit Dart int.
int _xxh64(Uint8List data, int start, int end) {
  final bd = ByteData.sublistView(data);
  final len = end - start;
  var p = start;
  int h;
  if (len >= 32) {
    var v1 = _xxP1 + _xxP2;
    var v2 = _xxP2;
    var v3 = 0;
    var v4 = -_xxP1;
    final limit = end - 32;
    while (p <= limit) {
      v1 = _xxRound(v1, bd.getUint64(p, Endian.little));
      v2 = _xxRound(v2, bd.getUint64(p + 8, Endian.little));
      v3 = _xxRound(v3, bd.getUint64(p + 16, Endian.little));
      v4 = _xxRound(v4, bd.getUint64(p + 24, Endian.little));
      p += 32;
    }
    h = _rotl64(v1, 1) + _rotl64(v2, 7) + _rotl64(v3, 12) + _rotl64(v4, 18);
    h = _xxMerge(h, v1);
    h = _xxMerge(h, v2);
    h = _xxMerge(h, v3);
    h = _xxMerge(h, v4);
  } else {
    h = _xxP5;
  }
  h += len;
  while (p + 8 <= end) {
    h ^= _xxRound(0, bd.getUint64(p, Endian.little));
    h = _rotl64(h, 27) * _xxP1 + _xxP4;
    p += 8;
  }
  if (p + 4 <= end) {
    h ^= bd.getUint32(p, Endian.little) * _xxP1;
    h = _rotl64(h, 23) * _xxP2 + _xxP3;
    p += 4;
  }
  while (p < end) {
    h ^= data[p] * _xxP5;
    h = _rotl64(h, 11) * _xxP1;
    p++;
  }
  h ^= h >>> 33;
  h *= _xxP2;
  h ^= h >>> 29;
  h *= _xxP3;
  h ^= h >>> 32;
  return h;
}

// ---------------------------------------------------------------------------
// Frames.

/// Header facts of one zstd frame, gathered by the pre-scan.
final class _FrameInfo {
  _FrameInfo({
    required this.blocksStart,
    required this.contentSize,
    required this.hasChecksum,
    required this.blockMax,
    required this.bound,
  });

  /// Offset of the first block header.
  final int blocksStart;

  /// Frame_Content_Size, or -1 when absent.
  final int contentSize;
  final bool hasChecksum;

  /// Block_Maximum_Size: min(Window_Size, 128 KiB).
  final int blockMax;

  /// Upper bound of the decompressed size (exact when [contentSize] is set).
  final int bound;
}

/// Per-frame decoder state carried from block to block.
final class _FrameState {
  int rep0 = 1;
  int rep1 = 4;
  int rep2 = 8;
  _HuffTable? huff;
  _FseTable? ll;
  _FseTable? of;
  _FseTable? ml;
}

final class _ZstdDecoder {
  _ZstdDecoder(this._in, this._maxOutput) : _bd = ByteData.sublistView(_in);

  final Uint8List _in;
  final ByteData _bd;
  final int _maxOutput;

  Uint8List _out = Uint8List(0);
  int _op = 0;
  int _capLimit = 0;

  /// Output offset where the current frame's content starts.
  int _frameStart = 0;

  /// Scratch buffer for decoded/RLE literals (one block's worth).
  final Uint8List _litScratch = Uint8List(_blockSizeMax);

  // Where the current block's literals live.
  Uint8List _lit = Uint8List(0);
  int _litPos = 0;
  int _litEnd = 0;

  int _u32(int p) => _bd.getUint32(p, Endian.little);

  Uint8List run() {
    final input = _in;
    final len = input.length;

    // Pass 1: walk frame and block headers to validate the layout and size
    // the output buffer.
    final frames = <_FrameInfo>[];
    var total = 0;
    var exact = true;
    var ip = 0;
    while (ip < len) {
      if (len - ip < 4) _corrupt('trailing garbage after last frame');
      final magic = _u32(ip);
      if ((magic & _skippableMagicMask) == _skippableMagic) {
        if (len - ip < 8) _corrupt('truncated skippable frame');
        final size = _u32(ip + 4);
        ip += 8 + size;
        if (ip > len) _corrupt('truncated skippable frame');
        continue;
      }
      if (magic != _frameMagic) {
        _corrupt('bad magic 0x${magic.toRadixString(16)} at offset $ip');
      }
      final (info, end) = _scanFrame(ip + 4);
      frames.add(info);
      total += info.bound;
      if (info.contentSize < 0) exact = false;
      ip = end;
    }
    if (exact && total > _maxOutput) {
      _corrupt('decompressed size $total exceeds limit $_maxOutput');
    }
    _capLimit = total < _maxOutput ? total : _maxOutput;
    var initial = _capLimit;
    if (!exact) {
      final guess = len * 4 < (1 << 16) ? (1 << 16) : len * 4;
      if (guess < initial) initial = guess;
    }
    _out = Uint8List(initial);

    // Pass 2: decode.
    for (final info in frames) {
      _decodeFrame(info);
    }
    final out = _out;
    return _op == out.length ? out : out.sublist(0, _op);
  }

  /// Parses the frame header at [ip] (just past the magic) and walks the
  /// block headers. Returns the frame info and the offset past the frame.
  (_FrameInfo, int) _scanFrame(int ip) {
    final input = _in;
    final len = input.length;
    if (ip >= len) _corrupt('truncated frame header');
    final fhd = input[ip++];
    final fcsFlag = fhd >> 6;
    final singleSegment = (fhd & 0x20) != 0;
    if ((fhd & 0x08) != 0) _corrupt('reserved frame header bit set');
    final hasChecksum = (fhd & 0x04) != 0;
    final dictIdSize = const [0, 1, 2, 4][fhd & 3];
    final fcsSize = fcsFlag == 0
        ? (singleSegment ? 1 : 0)
        : const [0, 2, 4, 8][fcsFlag];
    final headerRest = (singleSegment ? 0 : 1) + dictIdSize + fcsSize;
    if (ip + headerRest > len) _corrupt('truncated frame header');

    var windowSize = 0;
    if (!singleSegment) {
      final wd = input[ip++];
      final windowLog = 10 + (wd >> 3);
      final windowBase = 1 << windowLog;
      windowSize = windowBase + (windowBase >> 3) * (wd & 7);
    }
    var dictId = 0;
    for (var i = 0; i < dictIdSize; i++) {
      dictId |= input[ip + i] << (8 * i);
    }
    ip += dictIdSize;
    if (dictId != 0) {
      throw FormatException(
        'zstd: frame requires dictionary $dictId (dictionaries unsupported)',
      );
    }
    var contentSize = -1;
    if (fcsSize > 0) {
      var v = 0;
      for (var i = 0; i < fcsSize; i++) {
        v |= input[ip + i] << (8 * i);
      }
      if (fcsSize == 2) v += 256;
      // An 8-byte size at or above 2^63 wraps negative; it can never fit.
      if (v < 0) _corrupt('frame content size too large');
      contentSize = v;
    }
    ip += fcsSize;
    if (singleSegment) windowSize = contentSize;
    final blockMax = windowSize < _blockSizeMax ? windowSize : _blockSizeMax;
    final blocksStart = ip;

    var bound = 0;
    while (true) {
      if (ip + 3 > len) _corrupt('truncated block header');
      final bh = input[ip] | (input[ip + 1] << 8) | (input[ip + 2] << 16);
      ip += 3;
      final type = (bh >> 1) & 3;
      final size = bh >> 3;
      if (type == 3) _corrupt('reserved block type');
      if (size > blockMax) _corrupt('block size exceeds maximum');
      if (type == 1) {
        ip += 1;
        bound += size;
      } else {
        ip += size;
        bound += type == 0 ? size : blockMax;
      }
      if (ip > len) _corrupt('truncated block');
      if ((bh & 1) != 0) break;
    }
    if (hasChecksum) {
      ip += 4;
      if (ip > len) _corrupt('truncated content checksum');
    }
    if (contentSize >= 0) {
      if (contentSize > bound) _corrupt('frame content size is impossible');
      bound = contentSize;
    }
    return (
      _FrameInfo(
        blocksStart: blocksStart,
        contentSize: contentSize,
        hasChecksum: hasChecksum,
        blockMax: blockMax,
        bound: bound,
      ),
      ip,
    );
  }

  /// Makes room for [extra] more output bytes.
  void _reserve(int extra) {
    final need = _op + extra;
    if (need <= _out.length) return;
    if (need > _maxOutput) {
      throw FormatException(
        'zstd: decompressed size exceeds limit of $_maxOutput bytes',
      );
    }
    var cap = _out.length * 2;
    if (cap > _capLimit) cap = _capLimit;
    if (cap < need) cap = need;
    final grown = Uint8List(cap);
    grown.setRange(0, _op, _out);
    _out = grown;
  }

  void _decodeFrame(_FrameInfo info) {
    final input = _in;
    _frameStart = _op;
    final st = _FrameState();
    final blockMax = info.blockMax;
    var ip = info.blocksStart;
    while (true) {
      final bh = input[ip] | (input[ip + 1] << 8) | (input[ip + 2] << 16);
      ip += 3;
      final type = (bh >> 1) & 3;
      final size = bh >> 3;
      switch (type) {
        case 0:
          _reserve(size);
          _out.setRange(_op, _op + size, input, ip);
          _op += size;
          ip += size;
        case 1:
          _reserve(size);
          _out.fillRange(_op, _op + size, input[ip]);
          _op += size;
          ip += 1;
        default:
          _decodeCompressedBlock(ip, ip + size, st, blockMax);
          ip += size;
      }
      if ((bh & 1) != 0) break;
    }
    final produced = _op - _frameStart;
    if (info.contentSize >= 0 && produced != info.contentSize) {
      _corrupt(
        'frame content size mismatch '
        '(header ${info.contentSize}, decoded $produced)',
      );
    }
    if (info.hasChecksum) {
      final expected = _u32(ip);
      final actual = _xxh64(_out, _frameStart, _op) & 0xFFFFFFFF;
      if (actual != expected) _corrupt('content checksum mismatch');
    }
  }

  void _decodeCompressedBlock(int ip, int end, _FrameState st, int blockMax) {
    final blockLimit = _op + blockMax;
    ip = _decodeLiterals(ip, end, st, blockMax);

    // Sequences section header (RFC 8878 3.1.1.3.2.1).
    final input = _in;
    if (ip >= end) _corrupt('missing sequences section');
    final b0 = input[ip++];
    int nbSeq;
    if (b0 < 128) {
      nbSeq = b0;
    } else if (b0 < 255) {
      if (ip >= end) _corrupt('truncated sequences header');
      nbSeq = ((b0 - 128) << 8) + input[ip++];
    } else {
      if (ip + 2 > end) _corrupt('truncated sequences header');
      nbSeq = input[ip] + (input[ip + 1] << 8) + 0x7F00;
      ip += 2;
    }
    if (nbSeq == 0) {
      if (ip != end) _corrupt('extraneous data after empty sequences section');
      _copyLastLiterals(blockLimit);
      return;
    }
    if (ip >= end) _corrupt('truncated sequences header');
    final modes = input[ip++];
    if ((modes & 3) != 0) _corrupt('reserved sequence compression mode bits');
    final (llTable, afterLl) = _selectTable(
      modes >> 6,
      ip,
      end,
      _predefinedLl,
      st.ll,
      _maxLlSymbol,
      _maxLlLog,
    );
    final (ofTable, afterOf) = _selectTable(
      (modes >> 4) & 3,
      afterLl,
      end,
      _predefinedOf,
      st.of,
      _maxOfSymbol,
      _maxOfLog,
    );
    final (mlTable, afterMl) = _selectTable(
      (modes >> 2) & 3,
      afterOf,
      end,
      _predefinedMl,
      st.ml,
      _maxMlSymbol,
      _maxMlLog,
    );
    st.ll = llTable;
    st.of = ofTable;
    st.ml = mlTable;

    _decodeSequences(afterMl, end, nbSeq, st, blockLimit);
  }

  (_FseTable, int) _selectTable(
    int mode,
    int ip,
    int end,
    _FseTable predefined,
    _FseTable? previous,
    int maxSymbol,
    int maxLog,
  ) {
    switch (mode) {
      case 0:
        return (predefined, ip);
      case 1:
        if (ip >= end) _corrupt('truncated RLE sequence table');
        final symbol = _in[ip];
        if (symbol > maxSymbol) _corrupt('invalid RLE sequence symbol');
        return (_FseTable.rle(symbol), ip + 1);
      case 2:
        final (table, used) = _readFseTable(_in, ip, end, maxSymbol, maxLog);
        return (table, ip + used);
      default:
        if (previous == null) _corrupt('repeat table mode without a table');
        return (previous, ip);
    }
  }

  /// Decodes the literals section at [ip]; sets [_lit]/[_litPos]/[_litEnd]
  /// and returns the offset of the sequences section.
  int _decodeLiterals(int ip, int end, _FrameState st, int blockMax) {
    final input = _in;
    if (ip >= end) _corrupt('empty compressed block');
    final b0 = input[ip];
    final litType = b0 & 3;
    final sizeFormat = (b0 >> 2) & 3;
    if (litType < 2) {
      int regen;
      int hdr;
      switch (sizeFormat) {
        case 1:
          hdr = 2;
          if (ip + hdr > end) _corrupt('truncated literals header');
          regen = (b0 >> 4) | (input[ip + 1] << 4);
        case 3:
          hdr = 3;
          if (ip + hdr > end) _corrupt('truncated literals header');
          regen = (b0 >> 4) | (input[ip + 1] << 4) | (input[ip + 2] << 12);
        default:
          hdr = 1;
          regen = b0 >> 3;
      }
      if (regen > blockMax) _corrupt('literals larger than a block');
      ip += hdr;
      if (litType == 0) {
        if (ip + regen > end) _corrupt('truncated raw literals');
        _lit = input;
        _litPos = ip;
        _litEnd = ip + regen;
        return ip + regen;
      }
      if (ip >= end) _corrupt('truncated RLE literals');
      _litScratch.fillRange(0, regen, input[ip]);
      _lit = _litScratch;
      _litPos = 0;
      _litEnd = regen;
      return ip + 1;
    }

    int hdr;
    int regen;
    int compressed;
    final fourStreams = sizeFormat != 0;
    switch (sizeFormat) {
      case 2:
        hdr = 4;
        if (ip + hdr > end) _corrupt('truncated literals header');
        final v = _u32(ip);
        regen = (v >> 4) & 0x3FFF;
        compressed = (v >> 18) & 0x3FFF;
      case 3:
        hdr = 5;
        if (ip + hdr > end) _corrupt('truncated literals header');
        final v = _u32(ip) | (input[ip + 4] << 32);
        regen = (v >> 4) & 0x3FFFF;
        compressed = (v >> 22) & 0x3FFFF;
      default:
        hdr = 3;
        if (ip + hdr > end) _corrupt('truncated literals header');
        final v = b0 | (input[ip + 1] << 8) | (input[ip + 2] << 16);
        regen = (v >> 4) & 0x3FF;
        compressed = (v >> 14) & 0x3FF;
    }
    if (regen > blockMax) _corrupt('literals larger than a block');
    ip += hdr;
    final litEnd = ip + compressed;
    if (litEnd > end) _corrupt('truncated compressed literals');
    _HuffTable huff;
    if (litType == 2) {
      final (table, used) = _readHuffTable(input, _bd, ip, litEnd);
      huff = table;
      st.huff = table;
      ip += used;
    } else {
      final previous = st.huff;
      if (previous == null) _corrupt('treeless literals without a table');
      huff = previous;
    }
    final out = _litScratch;
    if (!fourStreams) {
      _huffDecodeStream(ip, litEnd, out, 0, regen, huff);
    } else {
      if (litEnd - ip < 10) _corrupt('truncated literal jump table');
      final s1 = input[ip] | (input[ip + 1] << 8);
      final s2 = input[ip + 2] | (input[ip + 3] << 8);
      final s3 = input[ip + 4] | (input[ip + 5] << 8);
      final a = ip + 6;
      final b = a + s1;
      final c = b + s2;
      final d = c + s3;
      if (d >= litEnd) _corrupt('invalid literal jump table');
      final segment = (regen + 3) >> 2;
      final last = regen - 3 * segment;
      if (last < 0) _corrupt('too few literals for four streams');
      _huffDecodeStream(a, b, out, 0, segment, huff);
      _huffDecodeStream(b, c, out, segment, segment, huff);
      _huffDecodeStream(c, d, out, 2 * segment, segment, huff);
      _huffDecodeStream(d, litEnd, out, 3 * segment, last, huff);
    }
    _lit = out;
    _litPos = 0;
    _litEnd = regen;
    return litEnd;
  }

  /// Huffman-decodes exactly [count] symbols from the backward bitstream
  /// `_in[start..end)` into `out[outPos..)`.
  void _huffDecodeStream(
    int start,
    int end,
    Uint8List out,
    int outPos,
    int count,
    _HuffTable huff,
  ) {
    final src = _in;
    final bd = _bd;
    if (end <= start) _corrupt('empty Huffman stream');
    final lastByte = src[end - 1];
    if (lastByte == 0) _corrupt('Huffman stream lacks its end marker');
    var ptr = end - 8;
    var bits = _loadBack(src, bd, start, ptr);
    var consumed = 9 - lastByte.bitLength;
    final shift = 64 - huff.maxBits;
    final table = huff.table;
    final limit = outPos + count;
    for (var o = outPos; o < limit; o++) {
      if (consumed > shift) {
        ptr -= consumed >> 3;
        consumed &= 7;
        bits = ptr >= start
            ? bd.getUint64(ptr, Endian.little)
            : _loadBack(src, bd, start, ptr);
      }
      final e = table[(bits << consumed) >>> shift];
      consumed += e >> 8;
      out[o] = e;
    }
    if (((ptr - start) << 3) + 64 - consumed != 0) {
      _corrupt('Huffman stream size mismatch');
    }
  }

  /// Copies the literals not used by sequences to the output.
  void _copyLastLiterals(int blockLimit) {
    final n = _litEnd - _litPos;
    if (n == 0) return;
    if (_op + n > blockLimit) _corrupt('block decompresses past its maximum');
    _reserve(n);
    _out.setRange(_op, _op + n, _lit, _litPos);
    _op += n;
    _litPos = _litEnd;
  }

  void _decodeSequences(
    int start,
    int end,
    int nbSeq,
    _FrameState st,
    int blockLimit,
  ) {
    final br = _BackBits(_in, _bd, start, end);
    final llTable = st.ll!;
    final ofTable = st.of!;
    final mlTable = st.ml!;
    final llT = llTable.entries;
    final ofT = ofTable.entries;
    final mlT = mlTable.entries;
    final llBase = _llBase;
    final llBits = _llBits;
    final mlBase = _mlBase;
    final mlBits = _mlBits;
    var llState = br.read(llTable.accuracyLog);
    var ofState = br.read(ofTable.accuracyLog);
    var mlState = br.read(mlTable.accuracyLog);

    var rep0 = st.rep0;
    var rep1 = st.rep1;
    var rep2 = st.rep2;
    final lit = _lit;
    var litPos = _litPos;
    final litEnd = _litEnd;
    final frameStart = _frameStart;
    var out = _out;
    var op = _op;

    for (var i = 0; i < nbSeq; i++) {
      final le = llT[llState];
      final me = mlT[mlState];
      final oe = ofT[ofState];
      final ofCode = oe & 0xFF;
      final mlCode = me & 0xFF;
      final llCode = le & 0xFF;
      var offset = (1 << ofCode) + br.read(ofCode);
      final ml = mlBase[mlCode] + br.read(mlBits[mlCode]);
      final ll = llBase[llCode] + br.read(llBits[llCode]);

      // Repeat offsets (RFC 8878 3.1.2.5).
      if (offset > 3) {
        offset -= 3;
        rep2 = rep1;
        rep1 = rep0;
        rep0 = offset;
      } else {
        final index = ll == 0 ? offset : offset - 1;
        if (index == 0) {
          offset = rep0;
        } else {
          if (index == 1) {
            offset = rep1;
          } else {
            offset = index == 2 ? rep2 : rep0 - 1;
            rep2 = rep1;
          }
          rep1 = rep0;
          rep0 = offset;
        }
      }

      if (i + 1 < nbSeq) {
        llState = (le >> 16) + br.read((le >> 8) & 0xFF);
        mlState = (me >> 16) + br.read((me >> 8) & 0xFF);
        ofState = (oe >> 16) + br.read((oe >> 8) & 0xFF);
      }

      // Execute: copy literals, then the match.
      if (ll > litEnd - litPos) _corrupt('literal length exceeds literals');
      final need = op + ll + ml;
      if (need > blockLimit) _corrupt('block decompresses past its maximum');
      if (need > out.length) {
        _op = op;
        _reserve(ll + ml);
        out = _out;
      }
      if (ll > 0) {
        if (ll <= 16) {
          for (var k = 0; k < ll; k++) {
            out[op + k] = lit[litPos + k];
          }
        } else {
          out.setRange(op, op + ll, lit, litPos);
        }
        op += ll;
        litPos += ll;
      }
      if (offset < 1 || offset > op - frameStart) {
        _corrupt('match offset $offset out of range');
      }
      final src = op - offset;
      if (ml <= 32) {
        for (var k = 0; k < ml; k++) {
          out[op + k] = out[src + k];
        }
      } else if (offset >= ml) {
        out.setRange(op, op + ml, out, src);
      } else {
        // Overlapping match: replicate the period, doubling each copy.
        var d = op;
        var remaining = ml;
        while (remaining > 0) {
          final chunk = d - src;
          final n = remaining < chunk ? remaining : chunk;
          out.setRange(d, d + n, out, src);
          d += n;
          remaining -= n;
        }
      }
      op += ml;
    }

    if (br.bitsLeft != 0) _corrupt('sequence bitstream size mismatch');
    st.rep0 = rep0;
    st.rep1 = rep1;
    st.rep2 = rep2;
    _op = op;
    _litPos = litPos;
    _copyLastLiterals(blockLimit);
  }
}
