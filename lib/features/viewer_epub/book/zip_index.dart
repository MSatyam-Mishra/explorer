import 'dart:async';
import 'dart:io';
import 'dart:isolate';
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

/// Central-directory index of a ZIP file. Entries are read lazily straight
/// from disk, so nothing decompressed is retained by the archive library.
class ZipIndex {
  ZipIndex._(this.entries)
      : _lower = {
          for (final name in entries.keys) name.toLowerCase(): name,
        };

  final Map<String, ZipEntryInfo> entries;
  final Map<String, String> _lower;

  /// Reads only the central directory of [path].
  static ZipIndex read(String path) {
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

Uint8List _inflate(ZipEntryInfo e, Uint8List data) {
  if (e.encrypted) {
    throw const BookOpenException(
      'This book is password-protected or encrypted and cannot be opened.',
    );
  }
  switch (e.method) {
    case 0:
      return data;
    case 8:
      final out = ZLibDecoder(raw: true).convert(data);
      return out is Uint8List ? out : Uint8List.fromList(out);
    default:
      throw BookOpenException(
        'Unsupported compression in "${e.name}" (method ${e.method}).',
      );
  }
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
