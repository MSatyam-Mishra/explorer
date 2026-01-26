import 'dart:io';

/// Abstract repository to handle file system operations.
/// This allows us to swap implementations for Root or Network access later.
abstract class FileRepository {
  Future<List<FileSystemEntity>> listEntities(String path);
  Future<void> delete(String path, {bool recursive = false});
  Future<void> rename(String path, String newPath);
  Future<bool> exists(String path);
  Future<FileSystemEntityType> type(String path);
  Future<void> createDirectory(String path);
  Future<void> createFile(String path);
  Future<List<Directory>> getStorageVolumes();
}

class LocalFileRepository implements FileRepository {
  @override
  Future<List<FileSystemEntity>> listEntities(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      throw FileSystemException("Directory not found", path);
    }
    return dir.list().toList();
  }

  @override
  Future<List<Directory>> getStorageVolumes() async {
    // Only works on Android/Linux usually.
    // Scan /storage/
    if (!Platform.isAndroid) return [];

    final storageRoot = Directory('/storage');
    // We check detecting volumes
    try {
      if (!await storageRoot.exists()) return [];

      final entities = await storageRoot.list().toList();
      final volumes = <Directory>[];

      for (final entity in entities) {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          // Filter out emulated (internal) and self
          if (name != 'emulated' && name != 'self') {
            volumes.add(entity);
          }
        }
      }
      return volumes;
    } catch (e) {
      print("Error scanning storage: $e");
      return [];
    }
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    }
  }

  @override
  Future<void> rename(String path, String newPath) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      await File(path).rename(newPath);
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).rename(newPath);
    }
  }

  @override
  Future<bool> exists(String path) {
    return FileSystemEntity.type(
      path,
    ).then((type) => type != FileSystemEntityType.notFound);
  }

  @override
  Future<FileSystemEntityType> type(String path) {
    return FileSystemEntity.type(path);
  }

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> createFile(String path) async {
    await File(path).create(recursive: true);
  }
}
