import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:explorer/features/file_explorere/widgets/info_row.dart';
import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:explorer/shared/widgets/progress_card.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/widgets/main_drawer.dart';
import '../bloc/file_explorer_bloc.dart';
// Change 'explorer' to your app name

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({super.key});

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  bool _isPermissionGranted = false;
  bool _isCheckingPermission =
      true; // Start with a loading state for the permission check itself

  @override
  Widget build(BuildContext context) {
    // Determine if we are at the root folder

    return _buildBody();
  }

  @override
  void initState() {
    super.initState();
    _checkPermissionStatus();
  }
  // In _FileExplorerScreenState

  // In _FileExplorerScreenState...

  Widget _buildBody() {
    if (_isCheckingPermission) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isPermissionGranted) {
      return Scaffold(body: _buildPermissionDeniedUI());
    }

    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) =>
              FileExplorerBloc()..add(LoadDirectory('/storage/emulated/0')),
        ),
        BlocProvider(create: (context) => TaskProgressBloc()),

        BlocProvider(
          create: (context) =>
              ClipboardBloc(taskProgressBloc: context.read<TaskProgressBloc>()),
        ),
      ],
      // 1. We now have a top-level listener AND builder for the ClipboardBloc
      child: BlocListener<ClipboardBloc, ClipboardState>(
        listener: (context, state) {
          if (state is ClipboardPasteSuccess) {
            final fileExplorerState = context.read<FileExplorerBloc>().state;
            if (fileExplorerState is FileExplorerLoaded) {
              context.read<FileExplorerBloc>().add(
                LoadDirectory(fileExplorerState.path),
              );
            }
          }
          if (state is ClipboardPasteFailure) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(state.error), backgroundColor: Colors.red),
            );
          }
        },
        child: BlocBuilder<ClipboardBloc, ClipboardState>(
          builder: (context, clipboardState) {
            // 2. We build the rest of the UI based on the clipboardState
            return BlocBuilder<FileExplorerBloc, FileExplorerState>(
              builder: (context, fileExplorerState) {
                final bool canPop = fileExplorerState is FileExplorerLoaded
                    ? fileExplorerState.path == '/storage/emulated/0'
                    : true;

                return PopScope(
                  canPop: canPop,
                  onPopInvoked: (didPop) {
                    if (didPop) return;
                    if (fileExplorerState is FileExplorerLoaded) {
                      final parentPath = p.dirname(fileExplorerState.path);
                      context.read<FileExplorerBloc>().add(
                        LoadDirectory(parentPath),
                      );
                    }
                  },
                  child: Scaffold(
                    appBar: AppBar(
                      title: Text(
                        fileExplorerState is FileExplorerLoaded
                            ? (fileExplorerState.path == '/storage/emulated/0'
                                  ? 'Files'
                                  : p.basename(fileExplorerState.path))
                            : 'Files',
                      ),
                    ),
                    drawer: const MainDrawer(),
                    body: Stack(
                      children: [
                        _FileExplorerView(
                          onFileLongPress: _showFileOptionsMenu,
                        ),
                        // 3. The pasting overlay is now built conditionally here
                         BlocBuilder<TaskProgressBloc, TaskProgressState>(
                            builder: (context, state) {
                              if (state is TaskInProgress) {
                                return Center(
                                  child: ProgressCard(
                                    title: state.title,
                                    message: state.message,
                                    progress: state.progress,
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          
                        ),
                      ],
                    ),
                    // 4. The FAB is also built conditionally using the same clipboardState
                    floatingActionButton:
                        (clipboardState is ClipboardReadyToPaste)
                        ? FloatingActionButton.extended(
                            onPressed: () {
                              if (fileExplorerState is FileExplorerLoaded) {
                                context.read<ClipboardBloc>().add(
                                  PasteFromClipboard(fileExplorerState.path),
                                );
                              }
                            },
                            label: const Text('Paste'),
                            icon: const Icon(BootstrapIcons.clipboard_check),
                          )
                        : null, // Use null for the FAB when it shouldn't be shown
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildPermissionDeniedUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Permission Required',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            const Text(
              'To browse and manage your files, this app needs access to your device\'s storage. Please grant the permission in your device settings.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                await Permission.manageExternalStorage.request();
                // After requesting, re-check the status
                _checkPermissionStatus();
              },
              child: const Text('Open Settings to Grant Permission'),
            ),
          ],
        ),
      ),
    );
  }

  // In the FileExplorerScreen class build method...

  Future<int> _calculateDirectorySize(Directory dir) async {
    int totalSize = 0;
    if (await dir.exists()) {
      await for (final FileSystemEntity entity in dir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
    }
    return totalSize;
  }

  Future<void> _checkPermissionStatus() async {
    final status = await Permission.manageExternalStorage.status;
    if (mounted) {
      // Check if the widget is still in the tree
      setState(() {
        _isPermissionGranted = status.isGranted;
        _isCheckingPermission = false;
      });
    }
  }

  // Add this helper method inside the _FileExplorerScreenState class

  Future<void> _shareZippedFolder(Directory directory) async {
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
      await Share.shareXFiles([
        XFile(zipPath),
      ], text: 'Sharing folder: ${p.basename(directory.path)}');
    } catch (e) {
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

  Future<void> _showDeleteConfirmationDialog(
    BuildContext blocContext,
    FileSystemEntity entity,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
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
        await entity.delete(recursive: true);
        // Use the passed-in blocContext
        final currentState = blocContext.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          blocContext.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
        }
      } catch (e) {
        // ... error handling
      }
    }
  }

  void _showFileOptionsMenu(BuildContext context, FileSystemEntity entity) {
    // Get the BLoC from the context to use in the actions
    final bloc = context.read<FileExplorerBloc>();

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return Wrap(
          children: <Widget>[
            ListTile(
              leading: const Icon(BootstrapIcons.share_fill),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (entity is File) {
                  Share.shareXFiles([XFile(entity.path)]);
                } else if (entity is Directory) {
                  _shareZippedFolder(entity); // Call our new zipping function
                }
              },
            ),
            ListTile(
              leading: const Icon(BootstrapIcons.pencil_square),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenameDialog(context, entity);
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
                _showDeleteConfirmationDialog(context, entity);
              },
            ),
            ListTile(
              leading: const Icon(BootstrapIcons.info_circle_fill),
              title: const Text('Info'),
              onTap: () {
                Navigator.pop(sheetContext);
                // Call our new info sheet method
                _showInfoSheet(entity);
              },
            ),
            // Stubs for more complex features
            const Divider(),
            ListTile(
              leading: const Icon(BootstrapIcons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(sheetContext);
                // Use the context from the list to find the BLoC
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

  void _showInfoSheet(FileSystemEntity entity) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            Future<int>? sizeFuture;
            if (entity is Directory) {
              // If it's a directory, start the calculation
              sizeFuture = _calculateDirectorySize(entity);
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

  Future<void> _showRenameDialog(
    BuildContext blocContext,
    FileSystemEntity entity,
  ) async {
    final textController = TextEditingController(text: p.basename(entity.path));
    final newName = await showDialog<String>(
      context: context, // Use the main context to show the dialog
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
        await entity.rename(newPath);
        // Use the passed-in blocContext, which is guaranteed to have the BLoC
        final currentState = blocContext.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          blocContext.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
        }
      } catch (e) {
        // ... error handling
      }
    }
  }
}

// We've moved the BLoC logic into its own private widget.
// This widget is ONLY built AFTER we confirm permission is granted.
class _FileExplorerView extends StatelessWidget {
  final void Function(BuildContext, FileSystemEntity) onFileLongPress;
  const _FileExplorerView({required this.onFileLongPress});

  @override
  Widget build(BuildContext context) {
    // We need the size of the screen for the liquid background
    final screenSize = MediaQuery.of(context).size;

    return BlocBuilder<FileExplorerBloc, FileExplorerState>(
      builder: (context, state) {
        if (state is FileExplorerLoading || state is FileExplorerInitial) {
          return const Center(child: CircularProgressIndicator());
        }

        if (state is FileExplorerError) {
          return Center(child: Text('Error: ${state.message}'));
        }

        if (state is FileExplorerLoaded) {
          if (state.entities.isEmpty) {
            return const Center(child: Text('This folder is empty.'));
          }

          // Use a Stack to layer the background and the list
          return
          // Layer 2: The scrollable list of frosted glass cards
          Animate(
            child: ListView.separated(
              itemCount: state.entities.length,
              itemBuilder: (context, index) {
                final entity = state.entities[index];

                return FileListItem(
                      onLongPress: () {
                        onFileLongPress(context, entity);
                        // We get the parent state's context to call the method
                      },
                      entity: entity,
                      // 1. Make the onTap callback async
                      onTap: () async {
                        if (entity is Directory) {
                          context.read<FileExplorerBloc>().add(
                            LoadDirectory(entity.path),
                          );
                        } else {
                          // 2. Await the result from the FileOpener
                          final result = await FileOpener.open(
                            context,
                            entity as File,
                          );

                          // 3. Check the result and refresh if needed
                          if (result == true) {
                            // Get the current path from the BLoC's state and reload it
                            final currentState = context
                                .read<FileExplorerBloc>()
                                .state;
                            if (currentState is FileExplorerLoaded) {
                              context.read<FileExplorerBloc>().add(
                                LoadDirectory(currentState.path),
                              );
                            }
                          }
                        }
                      },
                    )
                    .animate()
                    .slide(
                      delay: (5 * index).ms, // Staggered delay for each item
                      duration: 400.ms,
                      begin: const Offset(0, 0.5),
                      curve: Curves.easeOutCubic,
                    )
                    .fade(duration: 10.ms, curve: Curves.easeOutCubic);
              },
              // This adds the clean separator line between items
              separatorBuilder: (context, index) {
                return const Divider(
                  height: 1,

                  indent: 74, // Indent to align with the text
                );
              },
            ),
          );
        }
        return const Center(child: Text('Something went wrong.'));
      },
    );
  }
}
