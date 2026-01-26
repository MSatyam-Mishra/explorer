import 'dart:io';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:rar/rar.dart';

class ArchiveItem {
  final String name;
  final int size;
  final bool isFile;
  final dynamic originalObject; // ArchiveFile (zip/tar) or String (rar path)

  ArchiveItem({
    required this.name,
    required this.size,
    required this.isFile,
    this.originalObject,
  });
}

class ArchiveService {
  /// Lists contents of an archive file.
  /// Supports: .zip, .tar, .tar.gz, .tgz, .tar.bz2, .tar.xz, .rar
  Future<List<ArchiveItem>> listContents(File file) async {
    final extension = p.extension(file.path).toLowerCase();

    // Check for double extension for tar.gz, tar.xz etc if the main extension is .gz or .xz
    // Actually path.extension only gives last part.
    // We handle logic inside.

    if (extension == '.rar') {
      return _listRar(file);
    }

    final bytes = await file.readAsBytes();
    Archive? archive;

    try {
      if (extension == '.zip' || extension == '.cbz' || extension == '.jar') {
        archive = ZipDecoder().decodeBytes(bytes);
      } else if (extension == '.tar') {
        archive = TarDecoder().decodeBytes(bytes);
      } else if (extension == '.gz' || extension == '.tgz') {
        // GZip -> Tar?
        final decoded = GZipDecoder().decodeBytes(bytes);
        // If it's a tar.gz, the decoded bytes are a TAR file.
        // We usually check if it is a tar.
        // Simple check: try decoding as tar.
        try {
          archive = TarDecoder().decodeBytes(decoded);
        } catch (_) {
          // Not a tar, just a single GZipped file?
          // For file manager, we might just show the "content" file.
          // But usually .tgz implies tar.
        }
      } else if (extension == '.bz2') {
        final decoded = BZip2Decoder().decodeBytes(bytes);
        try {
          archive = TarDecoder().decodeBytes(decoded);
        } catch (_) {}
      } else if (extension == '.xz') {
        final decoded = XZDecoder().decodeBytes(bytes);
        try {
          archive = TarDecoder().decodeBytes(decoded);
        } catch (_) {}
      }
    } catch (e) {
      throw Exception("Failed to decode archive: $e");
    }

    if (archive != null) {
      return archive.files
          .map(
            (f) => ArchiveItem(
              name: f.name,
              size: f.size,
              isFile: f.isFile,
              originalObject: f,
            ),
          )
          .toList();
    }

    throw Exception("Unsupported or invalid archive format");
  }

  Future<List<ArchiveItem>> _listRar(File file) async {
    final result = await Rar.listRarContents(rarFilePath: file.path);
    if (result['success'] == true && result['files'] != null) {
      final fileList = result['files'] as List;
      return fileList.map((f) {
        final path = f.toString();
        // Rar package doesn't give isFile/size info in list easily without parsing
        // We assume file for now.
        return ArchiveItem(
          name: path,
          size: 0,
          isFile: true,
          originalObject: path,
        );
      }).toList();
    }
    throw Exception(result['message'] ?? 'Failed to list RAR contents');
  }

  /// Extracts the entire archive to destination
  Future<void> extractAll(File archiveFile, Directory destination) async {
    final extension = p.extension(archiveFile.path).toLowerCase();

    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    if (extension == '.rar') {
      final result = await Rar.extractRarFile(
        rarFilePath: archiveFile.path,
        destinationPath: destination.path,
      );
      if (result['success'] != true) {
        throw Exception(result['message']);
      }
      return;
    }

    // Reuse logic: decode archive then write files
    // But listContents reads bytes into memory. For extraction of huge files,
    // we might want streams (InputFileStream), but 'archive' package
    // usage details: ZipDecoder().decodeBuffer(InputFileStream...)

    // For now, simpler implementation matching existing memory-based approach
    // but refactored.

    // Load Items first (this loads into memory... efficient?)
    // Archive package generally loads into memory unless using InputFileStream.
    // Let's use InputFileStream for cleaner handling if possible, or just bytes for now since we did that before.

    final items = await listContents(archiveFile);

    for (final item in items) {
      if (item.originalObject is ArchiveFile) {
        final file = item.originalObject as ArchiveFile;
        final filePath = p.join(destination.path, file.name);
        if (file.isFile) {
          final outFile = File(filePath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }
    }
  }

  /// Compresses a list of files into a destination .zip file
  Future<void> compressFiles(List<File> files, File destinationZip) async {
    final encoder = ZipFileEncoder();
    encoder.create(destinationZip.path);

    for (final file in files) {
      final filename = p.basename(file.path);
      await encoder.addFile(file, filename);
    }

    encoder.close();
  }
}
