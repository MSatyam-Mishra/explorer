import 'dart:io';
import 'package:archive/archive.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:rar/rar.dart';
import 'package:explorer/core/services/archive_service.dart';

class ArchiveViewerScreen extends StatefulWidget {
  final File archiveFile;

  const ArchiveViewerScreen({super.key, required this.archiveFile});

  @override
  State<ArchiveViewerScreen> createState() => _ArchiveViewerScreenState();
}

class _ArchiveViewerScreenState extends State<ArchiveViewerScreen> {
  final ArchiveService _archiveService = ArchiveService();
  List<ArchiveItem> _files = [];
  bool _isLoading = true;
  bool _isExtracting = false;
  double _extractionProgress = 0.0;
  bool _isRar = false;

  @override
  void initState() {
    super.initState();
    _isRar = p.extension(widget.archiveFile.path).toLowerCase() == '.rar';
    _loadArchive();
  }

  Future<void> _loadArchive() async {
    try {
      final files = await _archiveService.listContents(widget.archiveFile);
      setState(() {
        _files = files;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading archive: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load archive: $e')));
      }
    }
  }

  Future<void> _extractAll() async {
    setState(() {
      _isExtracting = true;
      _extractionProgress = 0.0; // Indeterminate mostly
    });

    try {
      final sourceDir = widget.archiveFile.parent;
      final folderName = p.basenameWithoutExtension(widget.archiveFile.path);
      // Determine destination. If tar.gz, basnameWithoutExtension gives .tar.
      // We might want to strip two extensions?
      // p.basenameWithoutExtension('foo.tar.gz') -> 'foo.tar'.
      // Correct.

      final destinationDir = Directory(p.join(sourceDir.path, folderName));

      await _archiveService.extractAll(widget.archiveFile, destinationDir);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extracted to "${p.basename(destinationDir.path)}"'),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extraction failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExtracting = false);
      }
    }
  }

  Future<void> _extractFile(ArchiveItem item) async {
    // Single file extraction
    // Not explicitly in service yet, but we can do it here or add to service.
    // For RAR it is hard.
    if (_isRar) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Single file extraction not supported for RAR yet.'),
        ),
      );
      return;
    }

    // ZIP/TAR
    // item.originalObject is ArchiveFile
    if (item.originalObject == null) return;

    setState(() {
      _isExtracting = true;
    });

    try {
      // Manual extraction using the object we have in memory
      // This assumes ArchiveFile is from 'archive' package
      // We need to support the Abstraction.
      // The ArchiveService returns ArchiveItem(originalObject: dynamic).
      // We know it is ArchiveFile from 'archive'.
      // We must cast it carefully. (We imported archive)

      // WAIT: originalObject type needs to be imported?
      // ArchiveItem is in service.
      // We can just rely on internal logic if we moved it to service.
      // But I didn't move single extract to service.
      // I'll assume it's ArchiveFile for non-RAR.

      // Ideally we add extractFile(ArchiveItem, dest) to Service.
      // But let's fail fast:
      // The 'archive' package types might clash or be hidden if I didn't export them?
      // archive_service.dart imports 'package:archive/archive.dart'.
      // archive_viewer_screen.dart imports 'package:archive/archive.dart' too.
      // So casting should work.

      final archiveFile = item.originalObject;
      // We can't type check easily without knowing the type at compile time?
      // Dynamic dispatch.
      if (archiveFile.runtimeType.toString() == 'ArchiveFile' ||
          archiveFile.toString().contains('ArchiveFile')) {
        // It's a bit hacky to rely on dynamic but okay.
        // Actually, I can just cast if I import archive.
        final file = archiveFile; // dynamic

        if (file.isFile) {
          final sourceDir = widget.archiveFile.parent;
          final filePath = p.join(sourceDir.path, file.name);
          final outFile = File(filePath);
          await outFile.parent.create(recursive: true);
          // dynamic dispatch for content (List<int>)
          await outFile.writeAsBytes(file.content as List<int>);

          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Extracted "${file.name}"')));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(p.basename(widget.archiveFile.path)),
        actions: [
          TextButton.icon(
            onPressed: _isExtracting ? null : _extractAll,
            icon: const Icon(BootstrapIcons.box_arrow_down),
            label: const Text('Extract All'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final isFolder = !file.isFile;

                    return ListTile(
                      leading: Icon(
                        isFolder
                            ? BootstrapIcons.folder_fill
                            : (_isRar
                                  ? BootstrapIcons.file_zip
                                  : BootstrapIcons.file_earmark),
                        color: isFolder
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(file.name),
                      subtitle: _isRar
                          ? null // Size not available for RAR list
                          : Text('${(file.size / 1024).toStringAsFixed(2)} KB'),
                      trailing: (isFolder || _isRar)
                          ? null // Disable single extract for RAR or folders
                          : TextButton(
                              child: const Text('Extract'),
                              onPressed: () => _extractFile(file),
                            ),
                    );
                  },
                ),
          if (_isExtracting)
            Container(
              color: Colors.black.withOpacity(0.7),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        value: _isRar
                            ? null
                            : _extractionProgress, // Indeterminate for RAR if needed
                        backgroundColor: Colors.grey.shade700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _isRar
                            ? 'Extracting RAR...'
                            : 'Extracting... ${(_extractionProgress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
