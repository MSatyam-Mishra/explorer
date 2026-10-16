import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Random access to the bytes of a file (or a buffer) without loading all
/// of it: metadata parsers jump between small structures scattered through
/// files that are often tens of megabytes.
abstract class RandomBytes {
  int get length;

  /// Up to [count] bytes at [offset]; fewer at the end of the data, empty
  /// when [offset] is out of range.
  Uint8List read(int offset, int count);

  void close() {}

  /// Byte at [offset], or -1 past the end.
  int byteAt(int offset) {
    final b = read(offset, 1);
    return b.isEmpty ? -1 : b[0];
  }

  bool matches(int offset, List<int> pattern) {
    final b = read(offset, pattern.length);
    if (b.length != pattern.length) return false;
    for (var i = 0; i < b.length; i++) {
      if (b[i] != pattern[i]) return false;
    }
    return true;
  }

  int u16(int offset, {required bool littleEndian}) {
    final b = read(offset, 2);
    if (b.length < 2) return -1;
    return littleEndian ? b[0] | b[1] << 8 : b[0] << 8 | b[1];
  }

  int u32(int offset, {required bool littleEndian}) {
    final b = read(offset, 4);
    if (b.length < 4) return -1;
    return littleEndian
        ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
        : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
  }

  /// Index of the first occurrence of [pattern] in [start, end), scanning
  /// in chunks; -1 if absent.
  int indexOf(List<int> pattern, {int start = 0, int? end}) {
    final stop = math.min(end ?? length, length);
    const chunk = 1 << 20;
    var pos = math.max(0, start);
    while (pos < stop) {
      final want = math.min(chunk + pattern.length - 1, stop - pos);
      final b = read(pos, want);
      if (b.length < pattern.length) return -1;
      final i = indexOfBytes(b, pattern);
      if (i >= 0) return pos + i;
      pos += chunk;
    }
    return -1;
  }
}

/// [RandomBytes] over a [RandomAccessFile], with a small page cache so the
/// many tiny reads of an IFD walk don't each hit the OS.
class FileRandomBytes extends RandomBytes {
  FileRandomBytes._(this._file, this.length);

  /// Opens [path] for reading. Synchronous: meant for background isolates.
  factory FileRandomBytes.open(String path) {
    final file = File(path).openSync();
    try {
      return FileRandomBytes._(file, file.lengthSync());
    } catch (_) {
      file.closeSync();
      rethrow;
    }
  }

  static const _pageSize = 64 * 1024;
  static const _maxPages = 48;

  final RandomAccessFile _file;
  @override
  final int length;
  final Map<int, Uint8List> _pages = {};
  final List<int> _order = [];

  /// Bytes actually read from disk (for diagnostics and tests).
  int bytesRead = 0;

  Uint8List _page(int index) {
    final cached = _pages[index];
    if (cached != null) return cached;
    _file.setPositionSync(index * _pageSize);
    final data = _file.readSync(_pageSize);
    bytesRead += data.length;
    _pages[index] = data;
    _order.add(index);
    if (_order.length > _maxPages) _pages.remove(_order.removeAt(0));
    return data;
  }

  @override
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= length || count <= 0) return Uint8List(0);
    final end = math.min(length, offset + count);
    final n = end - offset;
    // Big reads (embedded JPEGs) go straight to the file.
    if (n > _pageSize * 2) {
      _file.setPositionSync(offset);
      final data = _file.readSync(n);
      bytesRead += data.length;
      return data;
    }
    final first = offset ~/ _pageSize, last = (end - 1) ~/ _pageSize;
    if (first == last) {
      final page = _page(first);
      final start = offset - first * _pageSize;
      if (start >= page.length) return Uint8List(0);
      return Uint8List.sublistView(
          page, start, math.min(page.length, start + n));
    }
    final out = Uint8List(n);
    var filled = 0;
    for (var p = first; p <= last && filled < n; p++) {
      final page = _page(p);
      final start = p == first ? offset - first * _pageSize : 0;
      if (start >= page.length) break;
      final take = math.min(page.length - start, n - filled);
      out.setRange(filled, filled + take, page, start);
      filled += take;
    }
    return filled == n ? out : Uint8List.sublistView(out, 0, filled);
  }

  @override
  void close() {
    _pages.clear();
    _order.clear();
    try {
      _file.closeSync();
    } catch (_) {}
  }
}

/// [RandomBytes] over an in-memory buffer.
class MemoryRandomBytes extends RandomBytes {
  MemoryRandomBytes(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= bytes.length || count <= 0) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(
        bytes, offset, math.min(bytes.length, offset + count));
  }
}

/// Index of [pattern] in [data] from [start], or -1.
int indexOfBytes(List<int> data, List<int> pattern, [int start = 0]) {
  if (pattern.isEmpty) return start;
  final first = pattern[0];
  final last = data.length - pattern.length;
  outer:
  for (var i = math.max(0, start); i <= last; i++) {
    if (data[i] != first) continue;
    for (var j = 1; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Index of the last occurrence of [pattern] in [data], or -1.
int lastIndexOfBytes(List<int> data, List<int> pattern) {
  for (var i = data.length - pattern.length; i >= 0; i--) {
    var ok = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Latin-1 text of [bytes] up to the first NUL, trimmed.
String asciiz(List<int> bytes) {
  var end = bytes.indexOf(0);
  if (end < 0) end = bytes.length;
  return String.fromCharCodes(bytes.sublist(0, end)).trim();
}
