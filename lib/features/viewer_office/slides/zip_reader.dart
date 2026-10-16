import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One entry of a zip's central directory.
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.flags,
    required this.compressedSize,
    required this.size,
    required this.offset,
  });

  final String name;

  /// 0 stored, 8 deflated.
  final int method;
  final int flags;
  final int compressedSize;
  final int size;

  /// Offset of the local file header.
  final int offset;

  bool get encrypted => (flags & 1) != 0;
}

/// Random-access zip reader: lists the central directory and reads single
/// entries on demand, so opening a large package only touches the parts
/// that are used (a deck with 80 MB of video reads a few hundred KB of XML).
///
/// Synchronous; use it from a background isolate.
class LazyZip {
  LazyZip._(this.path, this._file, this.length, this.modified, this.entries);

  final String path;
  final RandomAccessFile _file;
  final int length;

  /// Milliseconds since epoch.
  final int modified;
  final Map<String, ZipEntry> entries;

  /// Opens [path]; null when it isn't a zip this reader handles (the caller
  /// falls back to decoding the whole file).
  static LazyZip? open(String path) {
    RandomAccessFile? f;
    try {
      final file = File(path);
      final stat = file.statSync();
      f = file.openSync();
      final entries = _readDirectory(f, stat.size);
      if (entries == null) {
        f.closeSync();
        return null;
      }
      return LazyZip._(
        path,
        f,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
        entries,
      );
    } catch (_) {
      try {
        f?.closeSync();
      } catch (_) {}
      return null;
    }
  }

  bool has(String name) => entries.containsKey(name);

  ZipEntry? entry(String name) => entries[name];

  /// Uncompressed bytes of [name], or null when missing or unreadable.
  Uint8List? read(String name) {
    final e = entries[name];
    return e == null ? null : readEntry(_file, e);
  }

  void close() {
    try {
      _file.closeSync();
    } catch (_) {}
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  static int _u64(Uint8List b, int o) =>
      _u32(b, o) + _u32(b, o + 4) * 0x100000000;

  static Uint8List _readAt(RandomAccessFile f, int offset, int count) {
    f.setPositionSync(offset);
    return f.readSync(count);
  }

  static Map<String, ZipEntry>? _readDirectory(RandomAccessFile f, int len) {
    if (len < 22) return null;
    // Same test as OfficePackage.isZip, so a .ppt (CFB) whose tail happens
    // to contain the end-record signature isn't mistaken for a zip.
    final magic = _readAt(f, 0, 2);
    if (magic.length < 2 || magic[0] != 0x50 || magic[1] != 0x4B) return null;
    // End of central directory: last 22 bytes plus up to 64 KB of comment.
    final tailLen = len < 22 + 0xFFFF ? len : 22 + 0xFFFF;
    final tailStart = len - tailLen;
    final tail = _readAt(f, tailStart, tailLen);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return null;
    var count = _u16(tail, eocd + 10);
    var cdSize = _u32(tail, eocd + 12);
    var cdOffset = _u32(tail, eocd + 16);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      // Zip64: the locator sits right before the classic record.
      final loc = eocd - 20;
      if (loc < 0 || _u32(tail, loc) != 0x07064b50) return null;
      final recOffset = _u64(tail, loc + 8);
      final rec = _readAt(f, recOffset, 56);
      if (rec.length < 56 || _u32(rec, 0) != 0x06064b50) return null;
      count = _u64(rec, 32);
      cdSize = _u64(rec, 40);
      cdOffset = _u64(rec, 48);
    }
    if (cdOffset + cdSize > len) return null;
    final cd = _readAt(f, cdOffset, cdSize);
    final entries = <String, ZipEntry>{};
    var p = 0;
    for (var n = 0; n < count && p + 46 <= cd.length; n++) {
      if (_u32(cd, p) != 0x02014b50) return null;
      final flags = _u16(cd, p + 8);
      final method = _u16(cd, p + 10);
      var csize = _u32(cd, p + 20);
      var usize = _u32(cd, p + 24);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      var offset = _u32(cd, p + 42);
      if (p + 46 + nameLen + extraLen > cd.length) return null;
      final name = utf8
          .decode(
            Uint8List.sublistView(cd, p + 46, p + 46 + nameLen),
            allowMalformed: true,
          )
          .replaceAll('\\', '/');
      if (usize == 0xFFFFFFFF || csize == 0xFFFFFFFF || offset == 0xFFFFFFFF) {
        var e = p + 46 + nameLen;
        final end = e + extraLen;
        while (e + 4 <= end) {
          final id = _u16(cd, e), size = _u16(cd, e + 2);
          if (id == 0x0001) {
            var q = e + 4;
            if (usize == 0xFFFFFFFF && q + 8 <= e + 4 + size) {
              usize = _u64(cd, q);
              q += 8;
            }
            if (csize == 0xFFFFFFFF && q + 8 <= e + 4 + size) {
              csize = _u64(cd, q);
              q += 8;
            }
            if (offset == 0xFFFFFFFF && q + 8 <= e + 4 + size) {
              offset = _u64(cd, q);
            }
            break;
          }
          e += 4 + size;
        }
      }
      if (!name.endsWith('/')) {
        // Like OfficePackage.decode, a later duplicate wins.
        entries[name] = ZipEntry(
          name: name,
          method: method,
          flags: flags,
          compressedSize: csize,
          size: usize,
          offset: offset,
        );
      }
      p += 46 + nameLen + extraLen + commentLen;
    }
    return entries;
  }

  /// Reads and inflates [e] from an open file. Null for encrypted entries,
  /// unsupported compression, a bad local header, or (with [checkName]) a
  /// local header naming another entry.
  static Uint8List? readEntry(
    RandomAccessFile f,
    ZipEntry e, {
    bool checkName = false,
  }) {
    if (e.encrypted) return null;
    final head = _readAt(f, e.offset, 30);
    if (head.length < 30 || _u32(head, 0) != 0x04034b50) return null;
    final nameLen = _u16(head, 26), extraLen = _u16(head, 28);
    if (checkName) {
      final name = _readAt(f, e.offset + 30, nameLen);
      if (utf8.decode(name, allowMalformed: true).replaceAll('\\', '/') !=
          e.name) {
        return null;
      }
    }
    final raw = _readAt(
      f,
      e.offset + 30 + nameLen + extraLen,
      e.compressedSize,
    );
    if (raw.length < e.compressedSize) return null;
    switch (e.method) {
      case 0:
        return raw;
      case 8:
        final out = ZLibDecoder(raw: true).convert(raw);
        return out is Uint8List ? out : Uint8List.fromList(out);
    }
    return null;
  }
}
