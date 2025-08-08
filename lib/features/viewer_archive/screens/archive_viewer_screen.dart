import 'dart:io';
import 'package:archive/archive.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class ArchiveViewerScreen extends StatefulWidget {
  final File archiveFile;

  const ArchiveViewerScreen({super.key, required this.archiveFile});

  @override
  State<ArchiveViewerScreen> createState() => _ArchiveViewerScreenState();
}

class _ArchiveViewerScreenState extends State<ArchiveViewerScreen> {
  List<ArchiveFile> _files = [];
  bool _isLoading = true;
 bool _isExtracting = false;

 
  @override
  void initState() {
    super.initState();
    _loadArchive();
  }

  Future<void> _loadArchive() async {
    try {
      final bytes = await widget.archiveFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      setState(() {
        _files = archive.files;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading archive: $e');
      setState(() {
        _isLoading = false;
      });
      // Optionally show an error dialog
    }
  }

  void _extractAll() {
    // TODO: Implement extraction logic here
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('"Extract All" logic will be implemented next!')),
    );
  }

  void _extractFile(ArchiveFile file) {
    // TODO: Implement single file extraction logic here
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Extracting "${file.name}" will be implemented next!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(p.basename(widget.archiveFile.path)),
        actions: [
          TextButton.icon(
            onPressed: _extractAll,
            icon: const Icon(BootstrapIcons.box_arrow_down),
            label: const Text('Extract All'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
          )
        ],
      ),
      body: _isLoading
    ? const Center(child: CircularProgressIndicator())
    : ListView.builder(
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];
          // THIS IS THE FIX: Check if it's NOT a file.
          final isFolder = !file.isFile; 
          return ListTile(
            leading: Icon(
              isFolder ? BootstrapIcons.folder_fill : BootstrapIcons.file_earmark,
              color: isFolder ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(file.name),
            subtitle: Text('${(file.size / 1024).toStringAsFixed(2)} KB'),
            trailing: isFolder // Don't show extract button for folders
              ? null
              : TextButton(
                  child: const Text('Extract'),
                  onPressed: () => _extractFile(file),
                ),
          );
        },
      ),
    );
  }
}