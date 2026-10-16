/// Folder tree over an archive's flat entry list, with implied folders
/// (paths whose parent has no entry of its own) filled in.
library;

import 'archive_backend.dart';

class ArcFolder {
  ArcFolder(this.path);

  /// Folder path ('' for the root).
  final String path;

  /// Index of the folder's own directory entry, if the archive has one.
  int? entryIndex;

  /// File (and link) entries directly inside.
  final List<int> files = [];

  /// Direct subfolder paths.
  final List<String> folders = [];

  /// Recursive totals.
  int totalSize = 0;
  int totalPacked = 0;
  int fileCount = 0;
  bool anyEncrypted = false;
  DateTime? modified;

  String get name {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

class ArcIndex {
  ArcIndex._(this.entries, this.folders);

  final List<ArcEntry> entries;
  final Map<String, ArcFolder> folders;

  ArcFolder get root => folders['']!;

  int get fileCount => root.fileCount;
  int get totalSize => root.totalSize;
  bool get anyEncrypted => root.anyEncrypted;

  static ArcIndex build(List<ArcEntry> entries) {
    final folders = <String, ArcFolder>{'': ArcFolder('')};

    ArcFolder folderFor(String path) {
      final existing = folders[path];
      if (existing != null) return existing;
      final f = ArcFolder(path);
      folders[path] = f;
      final slash = path.lastIndexOf('/');
      final parent = folderFor(slash < 0 ? '' : path.substring(0, slash));
      parent.folders.add(path);
      return f;
    }

    // Duplicate paths (appended ZIP entries, TAR updates): the last wins.
    final lastByPath = <String, int>{};
    for (final e in entries) {
      if (!e.isDirectory) lastByPath[e.path] = e.index;
    }
    for (final e in entries) {
      if (e.path.isEmpty) continue;
      if (e.isDirectory) {
        folderFor(e.path)
          ..entryIndex = e.index
          ..modified ??= e.modified;
        continue;
      }
      if (lastByPath[e.path] != e.index) continue;
      final slash = e.path.lastIndexOf('/');
      final parent = folderFor(slash < 0 ? '' : e.path.substring(0, slash));
      parent.files.add(e.index);
    }
    // Recursive totals, deepest folders first.
    final ordered = folders.values.toList()
      ..sort((a, b) => _depth(b.path) - _depth(a.path));
    for (final f in ordered) {
      for (final i in f.files) {
        final e = entries[i];
        if (e.size > 0) f.totalSize += e.size;
        f.totalPacked += e.packedSize ?? 0;
        f.fileCount++;
        if (e.isEncrypted) f.anyEncrypted = true;
        final m = e.modified;
        if (m != null && (f.modified == null || m.isAfter(f.modified!))) {
          f.modified = m;
        }
      }
      if (f.path.isEmpty) continue;
      final slash = f.path.lastIndexOf('/');
      final parent = folders[slash < 0 ? '' : f.path.substring(0, slash)]!;
      parent.totalSize += f.totalSize;
      parent.totalPacked += f.totalPacked;
      parent.fileCount += f.fileCount;
      if (f.anyEncrypted) parent.anyEncrypted = true;
    }
    return ArcIndex._(entries, folders);
  }

  static int _depth(String path) {
    if (path.isEmpty) return 0;
    var d = 1;
    for (var i = 0; i < path.length; i++) {
      if (path.codeUnitAt(i) == 0x2F) d++;
    }
    return d;
  }

  /// Entries under [paths] (files or folders), in archive order.
  List<ArcEntry> select(Iterable<String> paths) {
    final exact = <String>{};
    final prefixes = <String>[];
    for (final p in paths) {
      if (p.isEmpty) return List.of(entries);
      exact.add(p);
      prefixes.add('$p/');
    }
    final out = <ArcEntry>[];
    for (final e in entries) {
      if (exact.contains(e.path) || prefixes.any(e.path.startsWith)) {
        out.add(e);
      }
    }
    return out;
  }
}
