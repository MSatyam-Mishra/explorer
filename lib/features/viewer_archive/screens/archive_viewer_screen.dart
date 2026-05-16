import 'dart:io';
import 'package:archive/archive.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
// import 'package:rar/rar.dart';
import 'package:explorer/core/services/archive_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:explorer/core/router/file_opener.dart';

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
    // _isRar = p.extension(widget.archiveFile.path).toLowerCase() == '.rar';
    _isRar = false; // RAR support temporarily disabled
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

  Future<void> _openFile(ArchiveItem item) async {
    if (!item.isFile) return;

    if (_isRar) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Opening files from RAR not supported yet.'),
        ),
      );
      return;
    }

    if (item.originalObject == null) return;

    setState(() => _isExtracting = true);

    try {
      final archiveFile = item.originalObject; // ArchiveFile (dynamic cast)

      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(
        p.join(tempDir.path, 'explorer_archive_cache'),
      );
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      final fileName = p.basename(item.name);
      final outFile = File(p.join(cacheDir.path, fileName));

      // Check if we need to write?
      // Always write to ensure fresh content or overwrite.
      if (archiveFile.runtimeType.toString() == 'ArchiveFile' ||
          archiveFile.toString().contains('ArchiveFile')) {
        final file = archiveFile;
        // dynamic dispatch for content.
        // content can be List<int> or InputFileStream.
        // If InputFileStream, we need to read it.
        // The archive package handles this usually, but 'content' property access might be heavy if not decoded?
        // Since listContents used standard decoder, content should be List<int>.
        await outFile.writeAsBytes(file.content as List<int>);

        if (mounted) {
          setState(() => _isExtracting = false);
          FileOpener.open(context, outFile);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isExtracting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _extractFile(ArchiveItem item) async {
    // Single file extraction
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
      final archiveFile = item.originalObject;

      if (archiveFile.runtimeType.toString() == 'ArchiveFile' ||
          archiveFile.toString().contains('ArchiveFile')) {
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
    return ExplorerScaffold(
      title: p.basename(widget.archiveFile.path),
      trailing: TextButton.icon(
        onPressed: _isExtracting ? null : _extractAll,
        icon: Icon(
          BootstrapIcons.box_arrow_down,
          color: ClearGlassForeground.icon(context),
        ),
        label: Text(
          'Extract All',
          style: TextStyle(color: ClearGlassForeground.primaryText(context)),
        ),
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
                      onTap: () => _openFile(file),
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
