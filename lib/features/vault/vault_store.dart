import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A file kept in the vault.
@immutable
class VaultItem {
  const VaultItem({
    required this.id,
    required this.file,
    required this.originalPath,
    required this.added,
    this.size = 0,
  });

  final String id;

  /// The file inside the vault (keeps its name, so viewers know its type).
  final File file;

  /// Where it was before it was moved in, for Restore.
  final String originalPath;
  final DateTime added;
  final int size;

  String get name => p.basename(file.path);
}

/// Files moved into the app's private storage, where other apps and the
/// file explorer can't see them.
class VaultStore {
  VaultStore({Directory? root}) : _root = root;

  /// The vault opens with the fingerprint, face or screen lock (local_auth),
  /// which Linux doesn't have.
  static bool get supported => !Platform.isLinux;

  Directory? _root;

  Future<Directory> _dir() async => _root ??= Directory(
    p.join((await getApplicationSupportDirectory()).path, 'vault'),
  );

  Future<File> _index() async =>
      File(p.join((await _dir()).path, 'index.json'));

  Future<Map<String, Map<String, Object?>>> _readIndex() async {
    final index = await _index();
    if (!await index.exists()) return {};
    try {
      final data =
          jsonDecode(await index.readAsString()) as Map<String, Object?>;
      return {
        for (final e in data.entries)
          e.key: (e.value! as Map).cast<String, Object?>(),
      };
    } catch (e) {
      debugPrint('Vault index unreadable: $e');
      return {};
    }
  }

  Future<void> _writeIndex(Map<String, Map<String, Object?>> index) async {
    final file = await _index();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(index), flush: true);
    await temp.rename(file.path);
  }

  /// Everything in the vault, newest first.
  Future<List<VaultItem>> list() async {
    final dir = await _dir();
    final index = await _readIndex();
    final items = <VaultItem>[];
    for (final MapEntry(key: id, value: meta) in index.entries) {
      final file = File(p.join(dir.path, 'files', id, meta['name']! as String));
      final FileStat stat;
      try {
        stat = await file.stat();
      } on FileSystemException {
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue;
      items.add(
        VaultItem(
          id: id,
          file: file,
          originalPath: meta['originalPath'] as String? ?? '',
          added: DateTime.fromMillisecondsSinceEpoch(
            (meta['added'] as num?)?.toInt() ?? 0,
          ),
          size: stat.size,
        ),
      );
    }
    items.sort((a, b) => b.added.compareTo(a.added));
    return items;
  }

  /// Moves [source] into the vault. With [keepOriginal] it's copied instead
  /// (files picked from other apps, whose original we can't delete).
  Future<VaultItem> add(File source, {bool keepOriginal = false}) async {
    final dir = await _dir();
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final name = p.basename(source.path);
    final target = File(p.join(dir.path, 'files', id, name));
    await target.parent.create(recursive: true);
    if (keepOriginal) {
      await source.copy(target.path);
    } else {
      await _move(source, target);
    }
    final added = DateTime.now();
    final index = await _readIndex();
    index[id] = {
      'name': name,
      'originalPath': source.path,
      'added': added.millisecondsSinceEpoch,
    };
    await _writeIndex(index);
    return VaultItem(
      id: id,
      file: target,
      originalPath: source.path,
      added: added,
      size: await target.length(),
    );
  }

  /// Moves [item] back to where it came from (or [fallbackDir] when that
  /// folder is gone), without overwriting anything. Returns the new path.
  Future<String> restore(VaultItem item, {required String fallbackDir}) async {
    var folder = p.dirname(item.originalPath);
    if (item.originalPath.isEmpty || !await Directory(folder).exists()) {
      folder = fallbackDir;
    }
    final target = await _unusedPath(folder, item.name);
    await _move(item.file, File(target));
    await _forget(item);
    return target;
  }

  /// Deletes [item] for good.
  Future<void> delete(VaultItem item) async {
    try {
      await item.file.delete();
    } on FileSystemException {
      // Already gone.
    }
    await _forget(item);
  }

  Future<void> _forget(VaultItem item) async {
    final index = await _readIndex()
      ..remove(item.id);
    await _writeIndex(index);
    try {
      await item.file.parent.delete(recursive: true);
    } on FileSystemException {
      // Nothing left to clean up.
    }
  }

  static Future<void> _move(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      // Different storage (app data vs shared storage): copy, then delete.
      await source.copy(target.path);
      await source.delete();
    }
  }

  static Future<String> _unusedPath(String dir, String name) async {
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var candidate = p.join(dir, name);
    for (
      var i = 1;
      await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.notFound;
      i++
    ) {
      candidate = p.join(dir, '$stem ($i)$ext');
    }
    return candidate;
  }
}
