import 'dart:io';
import 'package:archive/archive.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
double _extractionProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadArchive();
  }

 Future<void> _loadArchive() async {
    // ... (This method remains the same as before)
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
    }
  }
Future<void> _extractAll() async {
    setState(() {
      _isExtracting = true;
      _extractionProgress = 0.0;
    });
    
    try {
      // CHANGE 1: Extract to the SAME folder as the ZIP file
      final sourceDir = widget.archiveFile.parent;
      final zipFileName = p.basenameWithoutExtension(widget.archiveFile.path);
      final destinationDir = Directory(p.join(sourceDir.path, zipFileName));

      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
      }

      for (int i = 0; i < _files.length; i++) {
        final file = _files[i];
        final filePath = p.join(destinationDir.path, file.name);

        if (file.isFile) {
          final outFile = File(filePath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filePath).create(recursive: true);
        }

        // CHANGE 2: Update progress percentage after each file
        setState(() {
          _extractionProgress = (i + 1) / _files.length;
        });
      }

      // CHANGE 3: Show only the folder name in the success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Extracted successfully to "${p.basename(destinationDir.path)}"')),
      );

 Navigator.pop(context, true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Extraction failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isExtracting = false);
    }
  }

  // The single file extraction will also be updated to the new location logic
  Future<void> _extractFile(ArchiveFile file) async {
    setState(() {
      _isExtracting = true;
      _extractionProgress = 0.0; // Show a generic spinner for single files
    });
    try {
      final sourceDir = widget.archiveFile.parent;
      final filePath = p.join(sourceDir.path, file.name);
      final outFile = File(filePath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Extracted "${file.name}" to the current folder')),
      );

    } catch (e) {
       ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Extraction failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isExtracting = false);
    }
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
      body: Stack(children: [
        _isLoading
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
                        value: _extractionProgress,
                        backgroundColor: Colors.grey.shade700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Extracting... ${(_extractionProgress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],)
    );
  }
}