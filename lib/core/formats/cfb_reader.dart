import 'dart:convert';
import 'dart:typed_data';

/// Reader for Microsoft Compound File Binary (OLE2) containers.
///
/// Legacy Office files (`.doc`, `.xls`, `.ppt`) are CFB containers holding
/// named streams such as `WordDocument`, `Workbook` or `PowerPoint Document`.
/// This reader only reads; it never writes.
class CfbReader {
  CfbReader._(this._data, this._sectorSize, this._miniSectorSize,
      this._miniCutoff);

  static const _signature = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  static const _endOfChain = 0xFFFFFFFE;
  static const _freeSect = 0xFFFFFFFF;

  final Uint8List _data;
  final int _sectorSize;
  final int _miniSectorSize;
  final int _miniCutoff;
  late final List<int> _fat;
  late final List<int> _miniFat;
  late final Uint8List _miniStream;
  final List<CfbEntry> entries = [];

  static bool isCfb(Uint8List bytes) {
    if (bytes.length < 512) return false;
    for (var i = 0; i < _signature.length; i++) {
      if (bytes[i] != _signature[i]) return false;
    }
    return true;
  }

  /// Parses [bytes]; throws [FormatException] when it isn't a CFB file.
  factory CfbReader(Uint8List bytes) {
    if (!isCfb(bytes)) {
      throw const FormatException('Not an OLE2 compound file');
    }
    final header = ByteData.sublistView(bytes, 0, 512);
    final sectorShift = header.getUint16(0x1E, Endian.little);
    final miniShift = header.getUint16(0x20, Endian.little);
    if (sectorShift < 7 || sectorShift > 16 || miniShift > sectorShift) {
      throw const FormatException('Corrupt compound file header');
    }
    final reader = CfbReader._(
      bytes,
      1 << sectorShift,
      1 << miniShift,
      header.getUint32(0x38, Endian.little),
    );
    reader._load(header);
    return reader;
  }

  late final ByteData _view = ByteData.sublistView(_data);

  int _u32(int offset) => _view.getUint32(offset, Endian.little);

  int _sectorOffset(int sector) => (sector + 1) * _sectorSize;

  void _load(ByteData header) {
    final numFatSectors = header.getUint32(0x2C, Endian.little);
    final firstDirSector = header.getUint32(0x30, Endian.little);
    final firstMiniFat = header.getUint32(0x3C, Endian.little);
    final numMiniFat = header.getUint32(0x40, Endian.little);
    var difatSector = header.getUint32(0x44, Endian.little);
    final numDifat = header.getUint32(0x48, Endian.little);

    // Header counts are untrusted (up to 2^32). Every real sector lies inside
    // the file, so bound all loops and tables by the number of whole sectors
    // after the header; a corrupt or hostile file then costs at most time and
    // memory linear in its own size.
    final maxSectors = _data.length ~/ _sectorSize - 1;
    final fatLimit = numFatSectors < maxSectors ? numFatSectors : maxSectors;

    // DIFAT: 109 entries in the header, the rest chained through sectors.
    // Out-of-range or repeated FAT sectors keep their slot (so later FAT
    // indices don't shift) but contribute only free entries.
    final fatSectors = <int>[];
    for (var i = 0; i < 109 && fatSectors.length < fatLimit; i++) {
      final s = header.getUint32(0x4C + i * 4, Endian.little);
      if (s == _freeSect) break;
      fatSectors.add(s);
    }
    final perSector = _sectorSize ~/ 4;
    final difatSeen = <int>{};
    for (var n = 0;
        n < numDifat &&
            difatSector < maxSectors &&
            fatSectors.length < fatLimit &&
            difatSeen.add(difatSector);
        n++) {
      final base = _sectorOffset(difatSector);
      for (var i = 0; i < perSector - 1 && fatSectors.length < fatLimit; i++) {
        final s = _u32(base + i * 4);
        if (s == _freeSect) continue;
        fatSectors.add(s);
      }
      difatSector = _u32(base + (perSector - 1) * 4);
    }

    // Only the first maxSectors FAT entries can describe sectors that exist.
    final fatLength = fatSectors.length * perSector < maxSectors
        ? fatSectors.length * perSector
        : (maxSectors < 0 ? 0 : maxSectors);
    final fat = Uint32List(fatLength)..fillRange(0, fatLength, _freeSect);
    final fatSeen = <int>{};
    for (var k = 0; k < fatSectors.length && k * perSector < fatLength; k++) {
      final s = fatSectors[k];
      if (s >= maxSectors || !fatSeen.add(s)) continue;
      final base = _sectorOffset(s);
      for (var i = 0; i < perSector && k * perSector + i < fatLength; i++) {
        fat[k * perSector + i] = _u32(base + i * 4);
      }
    }
    _fat = fat;

    final dirBytes = _readChain(firstDirSector, _fat, _sectorSize, null);
    final dir = ByteData.sublistView(dirBytes);
    for (var off = 0; off + 128 <= dirBytes.length; off += 128) {
      final nameLen = dir.getUint16(off + 0x40, Endian.little);
      final type = dir.getUint8(off + 0x42);
      if (type == 0) {
        entries.add(CfbEntry._empty(entries.length));
        continue;
      }
      final chars = <int>[];
      for (var i = 0; i + 1 < nameLen - 2 && i < 64; i += 2) {
        chars.add(dir.getUint16(off + i, Endian.little));
      }
      entries.add(CfbEntry._(
        index: entries.length,
        name: String.fromCharCodes(chars),
        type: type,
        left: dir.getUint32(off + 0x44, Endian.little),
        right: dir.getUint32(off + 0x48, Endian.little),
        child: dir.getUint32(off + 0x4C, Endian.little),
        startSector: dir.getUint32(off + 0x74, Endian.little),
        size: dir.getUint32(off + 0x78, Endian.little),
      ));
    }

    final miniFatBytes = numMiniFat == 0
        ? Uint8List(0)
        : _readChain(
            firstMiniFat,
            _fat,
            _sectorSize,
            numMiniFat < maxSectors ? numMiniFat * _sectorSize : null,
          );
    final mf = ByteData.sublistView(miniFatBytes);
    _miniFat = [
      for (var i = 0; i + 4 <= miniFatBytes.length; i += 4)
        mf.getUint32(i, Endian.little),
    ];

    final root = entries.isEmpty ? null : entries.first;
    _miniStream = root == null || root.type != 5
        ? Uint8List(0)
        : _readChain(root.startSector, _fat, _sectorSize, root.size);
  }

  Uint8List _readChain(int start, List<int> fat, int unit, int? size) {
    final out = BytesBuilder(copy: false);
    final seen = <int>{};
    var sector = start;
    final isMini = !identical(fat, _fat);
    while (sector < _endOfChain - 3 && seen.add(sector)) {
      final Uint8List chunk;
      if (isMini) {
        final off = sector * unit;
        if (off + unit > _miniStream.length) break;
        chunk = Uint8List.sublistView(_miniStream, off, off + unit);
      } else {
        final off = _sectorOffset(sector);
        if (off >= _data.length) break;
        final end = off + unit > _data.length ? _data.length : off + unit;
        chunk = Uint8List.sublistView(_data, off, end);
      }
      out.add(chunk);
      if (size != null && out.length >= size) break;
      if (sector >= fat.length) break;
      sector = fat[sector];
    }
    final bytes = out.takeBytes();
    if (size != null && bytes.length > size) {
      return Uint8List.sublistView(bytes, 0, size);
    }
    return bytes;
  }

  /// Stream entries (type 2) in directory order.
  Iterable<CfbEntry> get streams => entries.where((e) => e.type == 2);

  CfbEntry? find(String name) {
    final lower = name.toLowerCase();
    for (final e in entries) {
      if (e.type != 0 && e.name.toLowerCase() == lower) return e;
    }
    return null;
  }

  /// Reads the stream called [name], or null when it doesn't exist.
  Uint8List? readStream(String name) {
    final entry = find(name);
    return entry == null ? null : read(entry);
  }

  Uint8List read(CfbEntry entry) {
    if (entry.size == 0) return Uint8List(0);
    if (entry.type != 5 && entry.size < _miniCutoff) {
      return _readChain(entry.startSector, _miniFat, _miniSectorSize, entry.size);
    }
    return _readChain(entry.startSector, _fat, _sectorSize, entry.size);
  }
}

class CfbEntry {
  CfbEntry._({
    required this.index,
    required this.name,
    required this.type,
    required this.left,
    required this.right,
    required this.child,
    required this.startSector,
    required this.size,
  });

  CfbEntry._empty(this.index)
      : name = '',
        type = 0,
        left = 0xFFFFFFFF,
        right = 0xFFFFFFFF,
        child = 0xFFFFFFFF,
        startSector = 0,
        size = 0;

  final int index;
  final String name;

  /// 1 = storage, 2 = stream, 5 = root.
  final int type;
  final int left;
  final int right;
  final int child;
  final int startSector;
  final int size;

  @override
  String toString() => 'CfbEntry($name, type $type, $size bytes)';
}

/// Code points of Windows-1252 bytes 0x80–0x9F. The five undefined slots
/// (0x81, 0x8D, 0x8F, 0x90, 0x9D) map to themselves so every byte value
/// round-trips through [decodeCp1252] and [encodeCp1252].
const _cp1252High = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

final Map<int, int> _cp1252Reverse = {
  for (var i = 0; i < _cp1252High.length; i++) _cp1252High[i]: 0x80 + i,
};

/// Decodes Windows-1252 bytes (the "compressed" 8-bit text used by legacy
/// Office formats). Bytes 0x80–0x9F map to their cp1252 code points.
String decodeCp1252(List<int> bytes) {
  final codes = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    codes[i] = b >= 0x80 && b < 0xA0 ? _cp1252High[b - 0x80] : b;
  }
  return String.fromCharCodes(codes);
}

/// Encodes [text] as Windows-1252, the exact inverse of [decodeCp1252].
///
/// Returns null when [text] contains a character cp1252 can't represent;
/// use [isCp1252Encodable] to find which ones.
Uint8List? encodeCp1252(String text) {
  final out = Uint8List(text.length);
  for (var i = 0; i < text.length; i++) {
    final u = text.codeUnitAt(i);
    if (u < 0x80 || (u >= 0xA0 && u <= 0xFF)) {
      out[i] = u;
      continue;
    }
    final b = _cp1252Reverse[u];
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

/// Whether the UTF-16 code unit [unit] has a Windows-1252 byte.
bool isCp1252Encodable(int unit) =>
    unit < 0x80 || (unit >= 0xA0 && unit <= 0xFF) || _cp1252Reverse.containsKey(unit);

/// Decodes UTF-16LE bytes.
String decodeUtf16le(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// Best-effort text decoding: UTF-8 when valid, otherwise Windows-1252.
String decodeTextBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return decodeUtf16le(bytes.sublist(2));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final swapped = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      swapped..add(bytes[i + 1])..add(bytes[i]);
    }
    return decodeUtf16le(swapped);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return decodeCp1252(bytes);
  }
}
