import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/info_row.dart';

import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/core/router/file_opener.dart';

class FileActionsService {
  final FileRepository repository;

  FileActionsService({FileRepository? repository})
    : repository = repository ?? LocalFileRepository();

  // Method to show the main options menu
  void showFileOptionsMenu(BuildContext context, FileSystemEntity entity) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return Wrap(
          children: <Widget>[
            if (entity is File)
              ListTile(
                leading: const Icon(BootstrapIcons.box_arrow_up_right),
                title: const Text('Open with…'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  FileOpener.showOpenWith(context, entity);
                },
              ),
            ListTile(
              leading: const Icon(BootstrapIcons.share_fill),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(sheetContext);
                share(context, entity);
              },
            ),
            ListTile(
              leading: const Icon(BootstrapIcons.pencil_square),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(sheetContext);
                showRenameDialog(context, entity);
              },
            ),
            ListTile(
              leading: const Icon(
                BootstrapIcons.trash_fill,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                showDeleteConfirmationDialog(context, entity);
              },
            ),
            ListTile(
              leading: const Icon(BootstrapIcons.info_circle_fill),
              title: const Text('Info'),
              onTap: () {
                Navigator.pop(sheetContext);
                showInfoSheet(entity, context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(BootstrapIcons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.read<ClipboardBloc>().add(CopyToClipboard(entity));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard!')),
                );
              },
            ),
            ListTile(
              leading: const Icon(BootstrapIcons.scissors),
              title: const Text('Cut'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.read<ClipboardBloc>().add(CutToClipboard(entity));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cut to clipboard!')),
                );
              },
            ),
          ],
        );
      },
    );
  }

  // --- All our helper methods are now static here ---

  Future<void> showRenameDialog(
    BuildContext blocContext,
    FileSystemEntity entity,
  ) async {
    final textController = TextEditingController(text: p.basename(entity.path));
    final newName = await showDialog<String>(
      context: blocContext, // Use the main context to show the dialog
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename'),
          content: TextField(controller: textController, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, textController.text),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty) {
      try {
        final newPath = p.join(entity.parent.path, newName);
        await repository.rename(entity.path, newPath);
        // Use the passed-in blocContext, which is guaranteed to have the BLoC
        final currentState = blocContext.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          blocContext.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
        }
      } catch (e) {
        // ... error handling
        print("Error renaming: $e");
      }
    }
  }

  Future<void> showDeleteConfirmationDialog(
    BuildContext blocContext,
    FileSystemEntity entity,
  ) async {
    final confirmed = await showDialog<bool>(
      context: blocContext,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete'),
          content: Text(
            'Are you sure you want to delete "${p.basename(entity.path)}"? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      try {
        await repository.delete(entity.path, recursive: true);
        final currentState = blocContext.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          blocContext.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
        }
      } catch (e) {
        print("Error deleting: $e");
      }
    }
  }

  Future<void> deleteFiles(
    BuildContext context,
    List<FileSystemEntity> files,
  ) async {
    if (files.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Delete ${files.length} items?'),
          content: const Text(
            'Are you sure you want to delete these items? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      int successCount = 0;
      for (final file in files) {
        try {
          await repository.delete(file.path, recursive: true);
          successCount++;
        } catch (e) {
          print("Error deleting ${file.path}: $e");
        }
      }

      if (context.mounted) {
        if (successCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted $successCount items')),
          );
        }

        final currentState = context.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          context.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
        }
      }
    }
  }

  void showInfoSheet(FileSystemEntity entity, BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            Future<int>? sizeFuture;
            if (entity is Directory) {
              // If it's a directory, start the calculation
              sizeFuture = calculateDirectorySize(entity);
            } else if (entity is File) {
              // If it's a file, get the size directly
              sizeFuture = entity.length();
            }

            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.basename(entity.path),
                    style: Theme.of(context).textTheme.headlineSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Divider(height: 24),
                  InfoRow(title: 'Path', content: entity.path),
                  const SizedBox(height: 12),
                  FutureBuilder<int>(
                    future: sizeFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return InfoRow(
                          title: 'Size',
                          content: 'Calculating...',
                        );
                      }
                      if (snapshot.hasError) {
                        return InfoRow(title: 'Size', content: 'Error');
                      }
                      // Use the 'filesize' package to format the bytes
                      return InfoRow(
                        title: 'Size',
                        content: filesize(snapshot.data ?? 0),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<FileStat>(
                    future: entity.stat(),
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        // Use the 'intl' package to format the date
                        final formattedDate = DateFormat.yMMMd()
                            .add_jms()
                            .format(snapshot.data!.modified);
                        return InfoRow(
                          title: 'Modified',
                          content: formattedDate,
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static Future<int> calculateDirectorySize(Directory dir) async {
    // ... same size calculation logic
    return 0; // Placeholder
  }

  /// Anchor for the iPad share popover: the widget that triggered the
  /// share, or the middle of the screen.
  static Rect _shareOrigin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
  }

  void share(BuildContext context, FileSystemEntity entity) {
    if (entity is File) {
      SharePlus.instance.share(ShareParams(
        files: [XFile(entity.path)],
        sharePositionOrigin: _shareOrigin(context),
      ));
    } else if (entity is Directory) {
      shareZippedFolder(context, entity);
    }
  }

  Future<void> shareZippedFolder(
    BuildContext context,
    Directory directory,
  ) async {
    final origin = _shareOrigin(context);
    // Show a loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Zipping folder for sharing...')),
    );

    final tempDir = await getTemporaryDirectory();
    final zipPath = p.join(tempDir.path, '${p.basename(directory.path)}.zip');
    final encoder = ZipFileEncoder();

    try {
      encoder.create(zipPath);
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: directory.path);
          encoder.addFile(entity, relativePath);
        }
      }
      encoder.close();

      // Share the created ZIP file
      await SharePlus.instance.share(ShareParams(
        files: [XFile(zipPath)],
        text: 'Sharing folder: ${p.basename(directory.path)}',
        sharePositionOrigin: origin,
      ));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to zip folder: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      // Clean up the temporary file
      final tempFile = File(zipPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }
}
