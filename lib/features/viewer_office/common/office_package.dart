import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'office_xml.dart';

/// One relationship from a `.rels` part.
class OfficeRel {
  const OfficeRel({
    required this.id,
    required this.type,
    required this.target,
    required this.external,
  });

  final String id;
  final String type;
  final String target;
  final bool external;

  /// Last path segment of the relationship type URI (e.g. `image`, `slide`).
  String get kind {
    final i = type.lastIndexOf('/');
    return i < 0 ? type : type.substring(i + 1);
  }
}

/// An OPC/ODF zip package held fully in memory, preserving part order so a
/// rewritten package keeps every part it didn't touch byte-for-byte.
class OfficePackage {
  OfficePackage._(this.order, this.parts);

  /// Part names in original zip order.
  final List<String> order;
  final Map<String, Uint8List> parts;

  static bool isZip(Uint8List bytes) =>
      bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;

  /// Decodes a zip; throws [FormatException] when it isn't one.
  factory OfficePackage.decode(Uint8List bytes) {
    if (!isZip(bytes)) {
      throw const FormatException('Not a zip package');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('The file is damaged or not a valid package ($e)');
    }
    final order = <String>[];
    final parts = <String, Uint8List>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      final content = f.content;
      final Uint8List data = content is Uint8List
          ? content
          : Uint8List.fromList((content as List).cast<int>());
      if (!parts.containsKey(name)) order.add(name);
      parts[name] = data;
    }
    return OfficePackage._(order, parts);
  }

  factory OfficePackage.empty() => OfficePackage._([], {});

  OfficePackage clone() => OfficePackage._(List.of(order), Map.of(parts));

  bool has(String name) => parts.containsKey(name);

  Uint8List? bytes(String name) => parts[name];

  String? text(String name) {
    final b = parts[name];
    if (b == null) return null;
    return decodeXmlBytes(b);
  }

  XmlDocument? xml(String name) {
    final t = text(name);
    if (t == null) return null;
    try {
      return XmlDocument.parse(t);
    } catch (_) {
      return null;
    }
  }

  void put(String name, Uint8List data) {
    if (!parts.containsKey(name)) order.add(name);
    parts[name] = data;
  }

  void putText(String name, String text) =>
      put(name, Uint8List.fromList(utf8.encode(text)));

  void remove(String name) {
    parts.remove(name);
    order.remove(name);
  }

  Uint8List encode() {
    final archive = Archive();
    for (final name in order) {
      final data = parts[name];
      if (data == null) continue;
      final f = ArchiveFile(name, data.length, data);
      // ODF requires an uncompressed `mimetype` first entry.
      if (name == 'mimetype') f.compress = false;
      archive.addFile(f);
    }
    final out = ZipEncoder().encode(archive);
    if (out == null) throw StateError('Could not write the package');
    return Uint8List.fromList(out);
  }

  /// `.rels` part for [partName] (`word/document.xml` →
  /// `word/_rels/document.xml.rels`).
  static String relsPathFor(String partName) {
    final i = partName.lastIndexOf('/');
    final dir = i < 0 ? '' : partName.substring(0, i + 1);
    final file = i < 0 ? partName : partName.substring(i + 1);
    return '${dir}_rels/$file.rels';
  }

  /// Relationships of [partName] (empty string for the package rels).
  List<OfficeRel> rels(String partName) {
    final path = partName.isEmpty ? '_rels/.rels' : relsPathFor(partName);
    final doc = xml(path);
    if (doc == null) return const [];
    final out = <OfficeRel>[];
    for (final r in Ox.elements(doc.rootElement)) {
      if (r.name.local != 'Relationship') continue;
      final id = Ox.attr(r, 'Id');
      final target = Ox.attr(r, 'Target');
      if (id == null || target == null) continue;
      out.add(
        OfficeRel(
          id: id,
          type: Ox.attr(r, 'Type') ?? '',
          target: target,
          external:
              (Ox.attr(r, 'TargetMode') ?? '').toLowerCase() == 'external',
        ),
      );
    }
    return out;
  }

  Map<String, OfficeRel> relMap(String partName) => {
    for (final r in rels(partName)) r.id: r,
  };

  /// Resolves a relationship target relative to its source part.
  static String resolve(String sourcePart, String target) {
    if (target.startsWith('/')) return _normalize(target.substring(1));
    final i = sourcePart.lastIndexOf('/');
    final dir = i < 0 ? '' : sourcePart.substring(0, i + 1);
    return _normalize('$dir$target');
  }

  static String _normalize(String path) {
    final segs = <String>[];
    for (final s in Uri.decodeFull(path).split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (segs.isNotEmpty) segs.removeLast();
        continue;
      }
      segs.add(s);
    }
    return segs.join('/');
  }

  /// Relative target from [sourcePart]'s folder to [targetPart].
  static String relativeTarget(String sourcePart, String targetPart) {
    final src = sourcePart.split('/')..removeLast();
    final dst = targetPart.split('/');
    var common = 0;
    while (common < src.length &&
        common < dst.length - 1 &&
        src[common] == dst[common]) {
      common++;
    }
    final ups = List.filled(src.length - common, '..');
    return [...ups, ...dst.sublist(common)].join('/');
  }

  /// Main part from the package relationships (officeDocument).
  String? mainPart() {
    for (final r in rels('')) {
      if (r.kind == 'officeDocument') {
        return resolve('', r.target);
      }
    }
    return null;
  }
}

/// Decodes XML bytes honouring a UTF-16 BOM, defaulting to UTF-8.
String decodeXmlBytes(Uint8List b) {
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
    final units = <int>[];
    for (var i = 2; i + 1 < b.length; i += 2) {
      units.add(b[i] | (b[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < b.length; i += 2) {
      units.add((b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  var start = 0;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) start = 3;
  return utf8.decode(Uint8List.sublistView(b, start), allowMalformed: true);
}

/// Content-type helpers for `[Content_Types].xml`.
abstract final class ContentTypes {
  static const path = '[Content_Types].xml';

  static String? mimeForExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'tif':
      case 'tiff':
        return 'image/tiff';
      case 'emf':
        return 'image/x-emf';
      case 'wmf':
        return 'image/x-wmf';
      case 'svg':
        return 'image/svg+xml';
      case 'xml':
        return 'application/xml';
      case 'rels':
        return 'application/vnd.openxmlformats-package.relationships+xml';
    }
    return null;
  }

  /// Ensures a `Default` entry exists for [ext].
  static void ensureDefault(OfficePackage pkg, String ext, String mime) {
    final doc = pkg.xml(path);
    if (doc == null) return;
    final root = doc.rootElement;
    for (final d in Ox.children(root, 'Default')) {
      if ((Ox.attr(d, 'Extension') ?? '').toLowerCase() == ext.toLowerCase()) {
        return;
      }
    }
    root.children.insert(
      0,
      XmlElement(XmlName('Default'), [
        XmlAttribute(XmlName('Extension'), ext),
        XmlAttribute(XmlName('ContentType'), mime),
      ]),
    );
    pkg.putText(path, doc.toXmlString());
  }

  static void ensureOverride(OfficePackage pkg, String partName, String mime) {
    final doc = pkg.xml(path);
    if (doc == null) return;
    final root = doc.rootElement;
    final pn = '/$partName';
    for (final o in Ox.children(root, 'Override')) {
      if (Ox.attr(o, 'PartName') == pn) return;
    }
    root.children.add(
      XmlElement(XmlName('Override'), [
        XmlAttribute(XmlName('PartName'), pn),
        XmlAttribute(XmlName('ContentType'), mime),
      ]),
    );
    pkg.putText(path, doc.toXmlString());
  }

  static void removeOverride(OfficePackage pkg, String partName) {
    final doc = pkg.xml(path);
    if (doc == null) return;
    final pn = '/$partName';
    doc.rootElement.children.removeWhere(
      (n) =>
          n is XmlElement &&
          n.name.local == 'Override' &&
          Ox.attr(n, 'PartName') == pn,
    );
    pkg.putText(path, doc.toXmlString());
  }

  static String? overrideFor(OfficePackage pkg, String partName) {
    final doc = pkg.xml(path);
    if (doc == null) return null;
    final pn = '/$partName';
    for (final o in Ox.children(doc.rootElement, 'Override')) {
      if (Ox.attr(o, 'PartName') == pn) return Ox.attr(o, 'ContentType');
    }
    return null;
  }
}

/// Sniffed image type from magic bytes.
String? sniffImageExtension(Uint8List b) {
  if (b.length < 4) return null;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'png';
  }
  if (b[0] == 0xFF && b[1] == 0xD8) return 'jpeg';
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
  if (b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
  if (b.length > 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'webp';
  }
  if ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) ||
      (b[0] == 0x4D && b[1] == 0x4D && b[3] == 0x2A)) {
    return 'tiff';
  }
  if (b[0] == 0x01 && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00) {
    return 'emf';
  }
  if (b[0] == 0xD7 && b[1] == 0xCD && b[2] == 0xC6 && b[3] == 0x9A) {
    return 'wmf';
  }
  return null;
}

/// Whether Flutter's engine can decode the image natively.
bool isDisplayableImage(String? ext) =>
    const {'png', 'jpeg', 'jpg', 'gif', 'bmp', 'webp'}.contains(ext);

/// Pixel dimensions from PNG/JPEG/GIF/BMP headers, or null.
(int, int)? imagePixelSize(Uint8List b) {
  try {
    final ext = sniffImageExtension(b);
    final bd = ByteData.sublistView(b);
    switch (ext) {
      case 'png':
        if (b.length < 24) return null;
        return (bd.getUint32(16), bd.getUint32(20));
      case 'gif':
        if (b.length < 10) return null;
        return (bd.getUint16(6, Endian.little), bd.getUint16(8, Endian.little));
      case 'bmp':
        if (b.length < 26) return null;
        return (
          bd.getInt32(18, Endian.little).abs(),
          bd.getInt32(22, Endian.little).abs(),
        );
      case 'jpeg':
        var i = 2;
        while (i + 9 < b.length) {
          if (b[i] != 0xFF) {
            i++;
            continue;
          }
          final marker = b[i + 1];
          if (marker == 0xD8 ||
              marker == 0x01 ||
              (marker >= 0xD0 && marker <= 0xD7)) {
            i += 2;
            continue;
          }
          final len = bd.getUint16(i + 2);
          if ((marker >= 0xC0 && marker <= 0xC3) ||
              (marker >= 0xC5 && marker <= 0xC7) ||
              (marker >= 0xC9 && marker <= 0xCB) ||
              (marker >= 0xCD && marker <= 0xCF)) {
            return (bd.getUint16(i + 7), bd.getUint16(i + 5));
          }
          i += 2 + len;
        }
        return null;
    }
  } catch (_) {}
  return null;
}
