// File name handling for received files (untrusted, peer-supplied names) and
// MIME types for sent files.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

abstract final class LsNames {
  static const _illegal = r'<>:"/\|?*';
  static const _reserved = {
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };

  /// Maximum folder depth kept from a peer-supplied relative path.
  static const maxDepth = 32;

  /// Sanitises one path segment so it is legal on Windows, macOS, Linux and
  /// FAT/exFAT (Android external storage). Returns null for segments that
  /// must be dropped entirely (empty, `.`, `..`).
  static String? sanitizeSegment(String segment) {
    final sb = StringBuffer();
    for (final rune in segment.runes) {
      if (rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune < 0xa0)) {
        continue;
      }
      final ch = String.fromCharCode(rune);
      sb.write(_illegal.contains(ch) ? '_' : ch);
    }
    var name = sb.toString().trim();
    // Trailing dots and spaces are stripped by Windows.
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty || name == '.' || name == '..') return null;
    final stem = name.split('.').first.toLowerCase();
    if (_reserved.contains(stem)) name = '_$name';
    return _truncateUtf8(name, 255);
  }

  static String _truncateUtf8(String name, int maxBytes) {
    if (utf8.encode(name).length <= maxBytes) return name;
    final ext = p.extension(name);
    var stem = name.substring(0, name.length - ext.length);
    final extBytes = utf8.encode(ext).length;
    final keepExt = extBytes < 32;
    final budget = maxBytes - (keepExt ? extBytes : 0);
    while (stem.isNotEmpty && utf8.encode(stem).length > budget) {
      final runes = stem.runes.toList()..removeLast();
      stem = String.fromCharCodes(runes);
    }
    return keepExt ? '$stem$ext' : stem;
  }

  /// Splits a peer-supplied `fileName` (which may use `/` or `\` and contain
  /// relative folders) into safe segments. Absolute paths, drive letters and
  /// `..` can never escape the destination folder.
  static List<String> safeSegments(String fileName) {
    final segments = <String>[];
    for (final raw in fileName.split(RegExp(r'[/\\]'))) {
      final s = sanitizeSegment(raw);
      if (s != null) segments.add(s);
    }
    if (segments.isEmpty) return ['file'];
    if (segments.length > maxDepth) {
      return [...segments.take(maxDepth - 1), segments.last];
    }
    return segments;
  }

  /// `name (n).ext` variants: `report.pdf` -> `report (1).pdf`.
  static String numbered(String name, int n) {
    final ext = p.extension(name);
    final stem = ext.isEmpty || ext == name
        ? name
        : name.substring(0, name.length - ext.length);
    return ext == name ? '$name ($n)' : '$stem ($n)$ext';
  }

  /// Picks a destination path for [segments] under [root] that does not exist
  /// yet and is not in [reserved] (paths claimed by parallel uploads of the
  /// same session). Folders are merged; a file name conflict gets a number.
  static String resolveTarget(
    String root,
    List<String> segments,
    Set<String> reserved,
  ) {
    var dir = root;
    for (final folder in segments.take(segments.length - 1)) {
      var candidate = p.join(dir, folder);
      var n = 1;
      // A file (not a folder) with the folder's name is in the way.
      while (FileSystemEntity.typeSync(candidate, followLinks: false) !=
              FileSystemEntityType.notFound &&
          FileSystemEntity.typeSync(candidate, followLinks: false) !=
              FileSystemEntityType.directory) {
        candidate = p.join(dir, numbered(folder, n++));
      }
      dir = candidate;
    }
    final name = segments.last;
    var candidate = p.join(dir, name);
    var n = 1;
    while (reserved.contains(_key(candidate)) ||
        FileSystemEntity.typeSync(candidate, followLinks: false) !=
            FileSystemEntityType.notFound) {
      candidate = p.join(dir, numbered(name, n++));
    }
    reserved.add(_key(candidate));
    return candidate;
  }

  static String _key(String path) =>
      Platform.isWindows || Platform.isMacOS ? path.toLowerCase() : path;

  static const _mime = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'svg': 'image/svg+xml',
    'ico': 'image/x-icon',
    'tif': 'image/tiff',
    'tiff': 'image/tiff',
    'avif': 'image/avif',
    'mp4': 'video/mp4',
    'm4v': 'video/x-m4v',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'avi': 'video/x-msvideo',
    '3gp': 'video/3gpp',
    'wmv': 'video/x-ms-wmv',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'wav': 'audio/wav',
    'flac': 'audio/flac',
    'ogg': 'audio/ogg',
    'opus': 'audio/opus',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'html': 'text/html',
    'htm': 'text/html',
    'css': 'text/css',
    'csv': 'text/csv',
    'json': 'application/json',
    'xml': 'application/xml',
    'js': 'text/javascript',
    'zip': 'application/zip',
    'rar': 'application/vnd.rar',
    '7z': 'application/x-7z-compressed',
    'tar': 'application/x-tar',
    'gz': 'application/gzip',
    'apk': 'application/vnd.android.package-archive',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'epub': 'application/epub+zip',
  };

  static String mimeTypeOf(String name) {
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    return _mime[ext] ?? 'application/octet-stream';
  }
}
