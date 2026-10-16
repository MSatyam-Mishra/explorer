import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart' show InputFileStream, ZipDirectory;

import 'book_models.dart';

/// Location of one stored file inside a ZIP container.
class ZipEntryInfo {
  const ZipEntryInfo({
    required this.name,
    required this.headerOffset,
    required this.compressedSize,
    required this.size,
    required this.method,
    required this.encrypted,
  });

  final String name;
  final int headerOffset;
  final int compressedSize;
  final int size;
  final int method;
  final bool encrypted;
}

/// Where the central directory is, from the end-of-central-directory record.
class _DirLocation {
  const _DirLocation(this.offset, this.size, this.count);

  final int offset;
  final int size;
  final int count;
}

/// Central-directory index of a ZIP file. Only the end record and the
/// central directory are read (never the entries themselves), and entries
/// are later read lazily straight from disk.
class ZipIndex {
  ZipIndex._(this.entries, {this.directoryOffset = -1})
      : _lower = {
          for (final name in entries.keys) name.toLowerCase(): name,
        };

  final Map<String, ZipEntryInfo> entries;
  final Map<String, String> _lower;

  /// Offset of the central directory (-1 if unknown); together with the
  /// entry count it identifies this exact archive layout.
  final int directoryOffset;

  /// The end record lives in the last 22 bytes plus an optional comment of
  /// up to 64 KiB.
  static const _maxTail = 22 + 0xFFFF + 20;

  /// Reads the central directory of [path] (synchronous; for isolates).
  static ZipIndex read(String path) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final length = raf.lengthSync();
      final tailStart = math.max(0, length - _maxTail);
      raf.setPositionSync(tailStart);
      final tail = raf.readSync(length - tailStart);
      final loc = _locate(tail, tailStart, length);
      if (loc != null) {
        raf.setPositionSync(loc.offset);
        final dir = raf.readSync(loc.size);
        final index = _parse(dir, loc);
        if (index != null) return index;
      }
    } on BookOpenException {
      rethrow;
    } catch (_) {
      // Fall through to the general-purpose reader.
    } finally {
      raf?.closeSync();
    }
    return _readWithArchive(path);
  }

  /// Reads the central directory through [raf] without blocking the calling
  /// isolate. Returns null when the archive needs the slower general-purpose
  /// reader ([read], in a background isolate).
  static Future<ZipIndex?> readAsync(RandomAccessFile raf) async {
    try {
      final length = await raf.length();
      final tailStart = math.max(0, length - _maxTail);
      await raf.setPosition(tailStart);
      final tail = await raf.read(length - tailStart);
      final loc = _locate(tail, tailStart, length);
      if (loc == null) return null;
      await raf.setPosition(loc.offset);
      final dir = await raf.read(loc.size);
      return _parse(dir, loc);
    } catch (_) {
      return null;
    }
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  static int _u64(Uint8List b, int o) => _u32(b, o) + _u32(b, o + 4) * 0x100000000;

  /// Finds the central directory from the file's last bytes ([tail] starts
  /// at file offset [tailStart]).
  static _DirLocation? _locate(Uint8List tail, int tailStart, int length) {
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] != 0x50 ||
          tail[i + 1] != 0x4B ||
          tail[i + 2] != 0x05 ||
          tail[i + 3] != 0x06) {
        continue;
      }
      var count = _u16(tail, i + 10);
      var size = _u32(tail, i + 12);
      var offset = _u32(tail, i + 16);
      if (count == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF) {
        // ZIP64: the locator sits just before the end record and points at
        // the ZIP64 end record, normally also inside the tail.
        final loc = i - 20;
        if (loc < 0 || _u32(tail, loc) != 0x07064b50) return null;
        final rec = _u64(tail, loc + 8) - tailStart;
        if (rec < 0 || rec + 56 > tail.length) return null;
        if (_u32(tail, rec) != 0x06064b50) return null;
        count = _u64(tail, rec + 32);
        size = _u64(tail, rec + 40);
        offset = _u64(tail, rec + 48);
      }
      if (offset + size > length || size > 64 * 1024 * 1024) return null;
      return _DirLocation(offset, size, count);
    }
    return null;
  }

  static String _name(Uint8List b, int start, int end, bool utf8Flag) {
    var ascii = true;
    for (var i = start; i < end; i++) {
      if (b[i] >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) return String.fromCharCodes(b, start, end);
    try {
      return utf8.decode(Uint8List.sublistView(b, start, end));
    } on FormatException {
      return utf8Flag
          ? utf8.decode(Uint8List.sublistView(b, start, end), allowMalformed: true)
          : latin1.decode(Uint8List.sublistView(b, start, end));
    }
  }

  /// Parses central directory records; null if they don't look right (the
  /// general-purpose reader then gets a chance).
  static ZipIndex? _parse(Uint8List dir, _DirLocation loc) {
    final entries = <String, ZipEntryInfo>{};
    var p = 0;
    var seen = 0;
    while (p + 46 <= dir.length && seen < loc.count) {
      if (_u32(dir, p) != 0x02014b50) return null;
      final flags = _u16(dir, p + 8);
      final method = _u16(dir, p + 10);
      var compressed = _u32(dir, p + 20);
      var size = _u32(dir, p + 24);
      final nameLen = _u16(dir, p + 28);
      final extraLen = _u16(dir, p + 30);
      final commentLen = _u16(dir, p + 32);
      var offset = _u32(dir, p + 42);
      final nameStart = p + 46;
      final extraStart = nameStart + nameLen;
      final next = extraStart + extraLen + commentLen;
      if (next > dir.length) return null;
      if (size == 0xFFFFFFFF || compressed == 0xFFFFFFFF || offset == 0xFFFFFFFF) {
        // ZIP64 extended information extra field (id 1).
        var e = extraStart;
        while (e + 4 <= extraStart + extraLen) {
          final id = _u16(dir, e);
          final len = _u16(dir, e + 2);
          if (id == 1) {
            var q = e + 4;
            if (size == 0xFFFFFFFF && q + 8 <= e + 4 + len) {
              size = _u64(dir, q);
              q += 8;
            }
            if (compressed == 0xFFFFFFFF && q + 8 <= e + 4 + len) {
              compressed = _u64(dir, q);
              q += 8;
            }
            if (offset == 0xFFFFFFFF && q + 8 <= e + 4 + len) {
              offset = _u64(dir, q);
            }
            break;
          }
          e += 4 + len;
        }
      }
      var name = _name(dir, nameStart, extraStart, (flags & 0x800) != 0)
          .replaceAll('\\', '/');
      while (name.startsWith('/')) {
        name = name.substring(1);
      }
      if (name.isNotEmpty && !name.endsWith('/')) {
        entries[name] = ZipEntryInfo(
          name: name,
          headerOffset: offset,
          compressedSize: compressed,
          size: size,
          method: method,
          encrypted: (flags & 1) != 0,
        );
      }
      p = next;
      seen++;
    }
    if (seen == 0 && loc.count > 0) return null;
    return ZipIndex._(entries, directoryOffset: loc.offset);
  }

  /// The archive package's reader: handles odd containers, but visits every
  /// local header (it reads most of the file).
  static ZipIndex _readWithArchive(String path) {
    final input = InputFileStream(path);
    try {
      final dir = ZipDirectory.read(input);
      final entries = <String, ZipEntryInfo>{};
      for (final h in dir.fileHeaders) {
        var name = h.filename.replaceAll('\\', '/');
        while (name.startsWith('/')) {
          name = name.substring(1);
        }
        if (name.isEmpty || name.endsWith('/')) continue;
        entries[name] = ZipEntryInfo(
          name: name,
          headerOffset: h.localHeaderOffset ?? 0,
          compressedSize: h.compressedSize ?? 0,
          size: h.uncompressedSize ?? 0,
          method: h.compressionMethod,
          encrypted: (h.generalPurposeBitFlag & 1) != 0,
        );
      }
      return ZipIndex._(entries);
    } on BookOpenException {
      rethrow;
    } catch (e) {
      throw BookOpenException(
        "This file isn't a valid ZIP container, it may be damaged or "
        'incomplete. ($e)',
      );
    } finally {
      input.closeSync();
    }
  }

  /// Exact lookup with a case-insensitive fallback.
  ZipEntryInfo? find(String path) =>
      entries[path] ?? entries[_lower[path.toLowerCase()] ?? ''];

  /// The canonical (stored) spelling of [path], if present.
  String? canonical(String path) => find(path)?.name;

  Iterable<String> get names => entries.keys;
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _dataOffset(ZipEntryInfo e, Uint8List localHeader) {
  if (localHeader.length < 30 ||
      localHeader[0] != 0x50 ||
      localHeader[1] != 0x4B ||
      localHeader[2] != 0x03 ||
      localHeader[3] != 0x04) {
    throw const BookOpenException('The book archive is damaged.');
  }
  return e.headerOffset + 30 + _u16(localHeader, 26) + _u16(localHeader, 28);
}

void _checkReadable(ZipEntryInfo e) {
  if (e.encrypted) {
    throw const BookOpenException(
      'This book is password-protected or encrypted and cannot be opened.',
    );
  }
  if (e.method != 0 && e.method != 8) {
    throw BookOpenException(
      'Unsupported compression in "${e.name}" (method ${e.method}).',
    );
  }
}

Uint8List _inflate(ZipEntryInfo e, Uint8List data) {
  _checkReadable(e);
  if (e.method == 0) return data;
  final out = ZLibDecoder(raw: true).convert(data);
  return out is Uint8List ? out : Uint8List.fromList(out);
}

/// Inflates at most about [maxOutput] bytes from the start of a deflate
/// stream (the rest of [data] is never touched).
Uint8List _inflateHead(Uint8List data, int maxOutput) {
  final filter = RawZLibFilter.inflateFilter(raw: true);
  final out = BytesBuilder(copy: false);
  const chunk = 4096;
  try {
    for (var i = 0; i < data.length && out.length < maxOutput; i += chunk) {
      filter.process(data, i, math.min(data.length, i + chunk));
      List<int>? piece;
      while ((piece = filter.processed(flush: false)) != null) {
        out.add(piece!);
      }
    }
  } catch (_) {
    // Damaged stream: keep what was decoded.
  }
  return out.takeBytes();
}

/// Synchronous reader, for use inside background isolates.
class ZipSyncReader {
  ZipSyncReader(String path) : _raf = File(path).openSync();

  final RandomAccessFile _raf;

  Uint8List read(ZipEntryInfo e) {
    _raf.setPositionSync(e.headerOffset);
    final header = _raf.readSync(30);
    _raf.setPositionSync(_dataOffset(e, header));
    return _inflate(e, _raf.readSync(e.compressedSize));
  }

  /// Roughly the first [maxBytes] bytes of an entry, reading and inflating
  /// only what that needs.
  Uint8List readHead(ZipEntryInfo e, int maxBytes) {
    // Small entries: one read and a one-shot inflate are cheapest.
    if (e.size <= maxBytes * 2) return read(e);
    _checkReadable(e);
    _raf.setPositionSync(e.headerOffset);
    final header = _raf.readSync(30);
    _raf.setPositionSync(_dataOffset(e, header));
    if (e.method == 0) {
      return _raf.readSync(math.min(maxBytes, e.compressedSize));
    }
    // Markup compresses 2-4x, so half the wanted output size in compressed
    // bytes is plenty.
    final compressed = _raf.readSync(
      math.min(e.compressedSize, math.max(16 * 1024, maxBytes ~/ 2)),
    );
    return _inflateHead(compressed, maxBytes);
  }

  void close() => _raf.closeSync();
}

/// Asynchronous reader for the UI isolate. Reads are serialized because a
/// [RandomAccessFile] allows one pending operation at a time.
class ZipAsyncReader {
  ZipAsyncReader(this.path);

  final String path;
  RandomAccessFile? _raf;
  Future<void> _tail = Future.value();
  bool _closed = false;

  Future<Uint8List> read(ZipEntryInfo e) {
    final completer = Completer<Uint8List>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await _readNow(e));
      } catch (err, st) {
        completer.completeError(err, st);
      }
    });
    return completer.future;
  }

  Future<Uint8List> _readNow(ZipEntryInfo e) async {
    if (_closed) throw StateError('closed');
    final raf = _raf ??= await File(path).open();
    await raf.setPosition(e.headerOffset);
    final header = await raf.read(30);
    await raf.setPosition(_dataOffset(e, header));
    final data = await raf.read(e.compressedSize);
    if (e.method == 8 && e.compressedSize > 1024 * 1024) {
      return Isolate.run(() => _inflate(e, data));
    }
    return _inflate(e, data);
  }

  Future<void> close() async {
    _closed = true;
    await _tail;
    await _raf?.close();
    _raf = null;
  }
}
