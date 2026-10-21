import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// One file or folder in a [ZipStream].
class ZipStreamEntry {
  const ZipStreamEntry.file(
    this.name,
    File this.file,
    this.size,
    this.modified,
  );

  ZipStreamEntry.directory(String name, this.modified)
    : name = name.endsWith('/') ? name : '$name/',
      file = null,
      size = 0;

  /// Path inside the archive, `/` separated (folders end with `/`).
  final String name;
  final File? file;
  final int size;
  final DateTime modified;

  bool get isDirectory => file == null;
}

/// Writes a ZIP archive of files on disk as a stream, without temporary
/// files or holding file contents in memory.
///
/// Entries are stored (not compressed), which is what makes [length] known
/// before any data is read, so browsers can show download progress; CRCs go
/// in data descriptors after each file. Uses ZIP64 where sizes, offsets or
/// the entry count need it.
class ZipStream {
  ZipStream(List<ZipStreamEntry> entries)
    : _entries = [for (final e in entries) _Planned(e)] {
    var offset = 0;
    for (final e in _entries) {
      e.offset = offset;
      offset += e.localLength;
    }
    _centralOffset = offset;
    _centralLength = _entries.fold(0, (sum, e) => sum + e.centralLength);
    _zip64End =
        _entries.length >= 0xFFFF ||
        _centralOffset >= _max32 ||
        _centralLength >= _max32;
    length =
        _centralOffset +
        _centralLength +
        (_zip64End ? _zip64EndLength + _zip64LocatorLength : 0) +
        _endLength;
  }

  static const _max32 = 0xFFFFFFFF;
  static const _zip64EndLength = 56;
  static const _zip64LocatorLength = 20;
  static const _endLength = 22;

  final List<_Planned> _entries;
  late final int _centralOffset;
  late final int _centralLength;
  late final bool _zip64End;

  /// Exact size of the archive in bytes.
  late final int length;

  /// The archive's bytes. Fails if a file's size changed since it was
  /// listed, rather than produce an archive of the wrong length.
  Stream<List<int>> stream() async* {
    for (final e in _entries) {
      yield e.localHeader();
      final file = e.entry.file;
      if (file == null) continue;
      var crc = 0;
      var read = 0;
      await for (final chunk in file.openRead(0, e.entry.size)) {
        crc = getCrc32(chunk, crc);
        read += chunk.length;
        yield chunk;
      }
      if (read != e.entry.size) {
        throw FileSystemException('File changed while zipping', file.path);
      }
      e.crc = crc;
      yield e.dataDescriptor();
    }
    for (final e in _entries) {
      yield e.centralHeader();
    }
    yield _end();
  }

  Uint8List _end() {
    final count = _entries.length;
    final out = _Writer(
      (_zip64End ? _zip64EndLength + _zip64LocatorLength : 0) + _endLength,
    );
    if (_zip64End) {
      final zip64EndOffset = _centralOffset + _centralLength;
      out
        ..u32(0x06064b50)
        ..u64(_zip64EndLength - 12)
        ..u16(45)
        ..u16(45)
        ..u32(0)
        ..u32(0)
        ..u64(count)
        ..u64(count)
        ..u64(_centralLength)
        ..u64(_centralOffset)
        // Locator.
        ..u32(0x07064b50)
        ..u32(0)
        ..u64(zip64EndOffset)
        ..u32(1);
    }
    out
      ..u32(0x06054b50)
      ..u16(0)
      ..u16(0)
      ..u16(count >= 0xFFFF ? 0xFFFF : count)
      ..u16(count >= 0xFFFF ? 0xFFFF : count)
      ..u32(_centralLength >= _max32 ? _max32 : _centralLength)
      ..u32(_centralOffset >= _max32 ? _max32 : _centralOffset)
      ..u16(0);
    return out.bytes;
  }
}

class _Planned {
  _Planned(this.entry)
    : name = utf8.encode(entry.name),
      zip64Sizes = entry.size >= ZipStream._max32 {
    final (time, date) = _dosDateTime(entry.modified);
    dosTime = time;
    dosDate = date;
  }

  final ZipStreamEntry entry;
  final Uint8List name;

  /// Sizes don't fit in 32 bits: ZIP64 extra field in the local header and
  /// 64-bit sizes in the data descriptor.
  final bool zip64Sizes;
  late final int dosTime;
  late final int dosDate;
  late int offset;
  int crc = 0;

  bool get _hasDescriptor => !entry.isDirectory;
  bool get _zip64Offset => offset >= ZipStream._max32;

  // Bit 3: sizes and CRC follow the data; bit 11: UTF-8 names.
  int get _flags => _hasDescriptor ? 0x0808 : 0x0800;
  int get _versionNeeded => zip64Sizes || _zip64Offset ? 45 : 20;

  int get localLength =>
      30 +
      name.length +
      (zip64Sizes ? 20 : 0) +
      entry.size +
      (_hasDescriptor ? (zip64Sizes ? 24 : 16) : 0);

  int get _centralExtraLength {
    final fields = (zip64Sizes ? 2 : 0) + (_zip64Offset ? 1 : 0);
    return fields == 0 ? 0 : 4 + 8 * fields;
  }

  int get centralLength => 46 + name.length + _centralExtraLength;

  Uint8List localHeader() {
    final out = _Writer(30 + name.length + (zip64Sizes ? 20 : 0))
      ..u32(0x04034b50)
      ..u16(_versionNeeded)
      ..u16(_flags)
      ..u16(0) // Stored.
      ..u16(dosTime)
      ..u16(dosDate)
      ..u32(0)
      ..u32(zip64Sizes ? ZipStream._max32 : 0)
      ..u32(zip64Sizes ? ZipStream._max32 : 0)
      ..u16(name.length)
      ..u16(zip64Sizes ? 20 : 0)
      ..raw(name);
    if (zip64Sizes) {
      out
        ..u16(0x0001)
        ..u16(16)
        ..u64(0)
        ..u64(0);
    }
    return out.bytes;
  }

  Uint8List dataDescriptor() {
    final out = _Writer(zip64Sizes ? 24 : 16)
      ..u32(0x08074b50)
      ..u32(crc);
    if (zip64Sizes) {
      out
        ..u64(entry.size)
        ..u64(entry.size);
    } else {
      out
        ..u32(entry.size)
        ..u32(entry.size);
    }
    return out.bytes;
  }

  Uint8List centralHeader() {
    final extra = _centralExtraLength;
    final size32 = zip64Sizes ? ZipStream._max32 : entry.size;
    final out = _Writer(centralLength)
      ..u32(0x02014b50)
      ..u16(45) // Made by: MS-DOS attributes, ZIP 4.5.
      ..u16(_versionNeeded)
      ..u16(_flags)
      ..u16(0)
      ..u16(dosTime)
      ..u16(dosDate)
      ..u32(crc)
      ..u32(size32)
      ..u32(size32)
      ..u16(name.length)
      ..u16(extra)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32(entry.isDirectory ? 0x10 : 0)
      ..u32(_zip64Offset ? ZipStream._max32 : offset)
      ..raw(name);
    if (extra > 0) {
      out
        ..u16(0x0001)
        ..u16(extra - 4);
      if (zip64Sizes) {
        out
          ..u64(entry.size)
          ..u64(entry.size);
      }
      if (_zip64Offset) out.u64(offset);
    }
    return out.bytes;
  }

  static (int, int) _dosDateTime(DateTime when) {
    final t = when.toLocal();
    if (t.year < 1980) return (0, (1 << 5) | 1);
    final year = t.year > 2107 ? 2107 : t.year;
    return (
      (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2),
      ((year - 1980) << 9) | (t.month << 5) | t.day,
    );
  }
}

class _Writer {
  _Writer(int length) : bytes = Uint8List(length);

  final Uint8List bytes;
  late final ByteData _data = ByteData.sublistView(bytes);
  int _at = 0;

  void u16(int v) {
    _data.setUint16(_at, v, Endian.little);
    _at += 2;
  }

  void u32(int v) {
    _data.setUint32(_at, v, Endian.little);
    _at += 4;
  }

  void u64(int v) {
    _data.setUint32(_at, v & 0xFFFFFFFF, Endian.little);
    _data.setUint32(_at + 4, v >> 32, Endian.little);
    _at += 8;
  }

  void raw(List<int> v) {
    bytes.setRange(_at, _at + v.length, v);
    _at += v.length;
  }
}
