import 'dart:io';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/widgets/explorer_options_sheet.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/core/services/file_action_service.dart';

import 'package:explorer/core/services/archive_service.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/services/http_server_service.dart';
import 'package:explorer/features/network/widgets/server_status_dialog.dart';
import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';

import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:explorer/features/file_explorere/widgets/file_type_icon.dart';
import 'package:explorer/features/file_explorere/widgets/gradient_folder_icon.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';

import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/main_drawer.dart';
import 'package:explorer/shared/widgets/progress_card.dart';
import 'package:flutter/material.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

FileActionsService fileActionsService = FileActionsService();

class FileExplorerScreen extends StatelessWidget {
  const FileExplorerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // We use a FutureBuilder to handle the initial permission check.
    return FutureBuilder<PermissionStatus>(
      future: _checkAndRequestPermission(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final status = snapshot.data!;
        // Handle both standard usage and "manage external storage" scenarios
        if (status.isGranted) {
          return const _FileExplorerWithProviders();
        } else {
          return const _PermissionDeniedScreen();
        }
      },
    );
  }

  Future<PermissionStatus> _checkAndRequestPermission() async {
    if (ExplorerPaths.isDesktop) {
      return PermissionStatus.granted;
    }

    var status = await Permission.manageExternalStorage.status;

    // If not granted, request it immediately
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }

    // Fallback for older Android versions (SDK < 30) if needed,
    // strictly speaking should check SDK version, but checking Permission.storage
    // is a common pattern if manageExternalStorage is not applicable.
    // However, keeping consistent with existing logic which only used manageExternalStorage.

    return status;
  }
}

// This widget holds all our BLoCs at the very top.
class _FileExplorerWithProviders extends StatelessWidget {
  const _FileExplorerWithProviders();

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) =>
              FileExplorerBloc(repository: LocalFileRepository())
                ..add(LoadDirectory(ExplorerPaths.initialPath)),
        ),
        BlocProvider(
          create: (context) => SidebarBloc()..add(LoadSidebarData()),
        ),
        BlocProvider(create: (context) => TaskProgressBloc()),
        BlocProvider(
          create: (context) =>
              ClipboardBloc(taskProgressBloc: context.read<TaskProgressBloc>()),
        ),
      ],
      child: _FileExplorerUI(),
    );
  }
}

// This is the actual UI, which is now guaranteed to be under all the providers.
class _FileExplorerUI extends StatelessWidget {
  _FileExplorerUI();

  @override
  Widget build(BuildContext context) {
    // We listen to multiple BLoCs to build the final UI
    final fileExplorerState = context.watch<FileExplorerBloc>().state;
    final clipboardState = context.watch<ClipboardBloc>().state;
    final taskState = context.watch<TaskProgressBloc>().state;

    final bool canPop = fileExplorerState is FileExplorerLoaded
        ? ExplorerPaths.isAppRoot(fileExplorerState.path)
        : true;
    final bool isSelectionMode = fileExplorerState is FileExplorerLoaded
        ? fileExplorerState.isSelectionMode
        : false;
    // Tablets, unfolded foldables and desktops keep navigation docked.
    final bool docked = AdaptiveSplitView.isSplit(context);
    final content = Stack(
      children: [
        _buildFileList(context, fileExplorerState),
        if (taskState is TaskInProgress)
          ProgressCard(
            title: taskState.title,
            message: taskState.message,
            progress: taskState.progress,
          ),
      ],
    );
    // final int selectionCount = fileExplorerState is FileExplorerLoaded
    //     ? fileExplorerState.selectedItems.length
    //     : 0;

    return PopScope(
      canPop: canPop,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (fileExplorerState is FileExplorerLoaded) {
          final parentPath =
              ExplorerPaths.parentOf(fileExplorerState.path);
          if (parentPath != null) {
            context.read<FileExplorerBloc>().add(LoadDirectory(parentPath));
          }
        }
      },
      child: DockedTopBarScaffold(
        drawer: docked ? null : const MainDrawer(),
        topBarBuilder: (scaffoldContext) => _buildDockedTopBar(
          scaffoldContext,
          fileExplorerState: fileExplorerState,
          isSelectionMode: isSelectionMode,
          docked: docked,
        ),
        body: docked
            ? AdaptiveSplitView(
                divider: false,
                secondaryWidth: 300,
                primary: content,
                secondary: ClearGlassPanel(
                  borderRadius: 24,
                  margin: EdgeInsets.fromLTRB(
                    12,
                    DockedGlossyTopBar.contentTopInset(context),
                    0,
                    12 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: const MainDrawerContent(
                    padding: EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              )
            : content,
        floatingActionButton: (clipboardState is ClipboardReadyToPaste)
            ? FloatingActionButton.extended(
                onPressed: () {
                  if (fileExplorerState is FileExplorerLoaded) {
                    context.read<ClipboardBloc>().add(
                      PasteFromClipboard(fileExplorerState.path),
                    );
                  }
                },
                label: const Text('Paste'),
                icon: AppIcons.clipboard(),
              )
            : null,
      ),
    );
  }

  Widget _buildDockedTopBar(
    BuildContext context, {
    required FileExplorerState fileExplorerState,
    required bool isSelectionMode,
    required bool docked,
  }) {
    final title = fileExplorerState is FileExplorerLoaded
        ? ExplorerPaths.titleForPath(fileExplorerState.path)
        : 'Files';

    if (isSelectionMode && fileExplorerState is FileExplorerLoaded) {
      return DockedGlossyTopBar(
        title: title,
        leading: IconButton(
          icon: AppIcons.cancel(),
          tooltip: 'Cancel selection',
          onPressed: () {
            context.read<FileExplorerBloc>().add(
                  ToggleSelectionMode(enable: false),
                );
          },
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (fileExplorerState.selectedItems.length == 1)
              IconButton(
                icon: AppIcons.optionsMenu(),
                tooltip: 'More actions',
                onPressed: () {
                  final entity = fileExplorerState.selectedItems.first;
                  context.read<FileExplorerBloc>().add(
                        ToggleSelectionMode(enable: false),
                      );
                  fileActionsService.showFileOptionsMenu(context, entity);
                },
              ),
            IconButton(
              icon: AppIcons.archive(),
              tooltip: 'Compress',
              onPressed: () => _handleCompress(context, fileExplorerState),
            ),
            IconButton(
              icon: AppIcons.delete(),
              tooltip: 'Delete',
              onPressed: () {
                FileActionsService().deleteFiles(
                  context,
                  fileExplorerState.selectedItems
                      .map((e) => e as File)
                      .toList(),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Delete not implemented yet here'),
                  ),
                );
              },
            ),
          ],
        ),
      );
    }

    return DockedGlossyTopBar(
      title: title,
      leading: docked ? const SizedBox(width: 12) : null,
      onMenuPressed: () => Scaffold.of(context).openDrawer(),
      onMorePressed: fileExplorerState is FileExplorerLoaded
          ? () {
              ExplorerOptionsSheet.show(
                context,
                fileState: fileExplorerState,
                onHttpShare: () =>
                    _handleHttpShare(context, fileExplorerState),
                onSortChanged: (SortOption option, SortOrder order) {
                  context.read<FileExplorerBloc>().add(
                        ChangeSortOrder(option, order),
                      );
                },
                onViewModeChanged: (ViewMode mode) {
                  context.read<FileExplorerBloc>().add(
                        ChangeViewMode(mode),
                      );
                },
              );
            }
          : null,
    );
  }

  Widget _buildFileList(BuildContext context, FileExplorerState state) {
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

      if (state.viewMode == ViewMode.grid ||
          state.viewMode == ViewMode.gallery) {
        return GridView.builder(
          physics: const BouncingScrollPhysics(),
          // Column count follows the window width (phones ≈3, tablets 6+).
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 128,
            childAspectRatio: 0.8,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          padding: EdgeInsets.fromLTRB(
            8,
            DockedGlossyTopBar.contentTopInset(context) + 8,
            8,
            8,
          ),
          itemCount: state.entities.length,
          itemBuilder: (context, index) {
            final entity = state.entities[index];
            final isSelected = state.selectedItems.contains(entity);
            final isDirectory = entity is Directory;

            return InkWell(
              onTap: () => _handleTap(context, state, entity),
              onLongPress: () => _handleLongPress(context, state, entity),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: isSelected
                    ? BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).primaryColor.withOpacity(0.5),
                          width: 2,
                        ),
                      )
                    : null,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    isDirectory
                        ? const GradientFolderIcon(size: 56)
                        : FileTypeIcon(filePath: entity.path, size: 56),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4.0),
                      child: Text(
                        state.labelFor(entity),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }

      // Default to List View (Compact or List)
      return ListView.separated(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.only(
          top: DockedGlossyTopBar.contentTopInset(context),
        ),
        itemCount: state.entities.length,
        itemBuilder: (context, index) {
          final entity = state.entities[index];
          final isSelected = state.selectedItems.contains(entity);
          return FileListItem(
            entity: entity,
            displayName: state.labelFor(entity),
            isSelectionMode: state.isSelectionMode,
            isSelected: isSelected,
            onTap: () => _handleTap(context, state, entity),
            onLongPress: () => _handleLongPress(context, state, entity),
          );
        },
        separatorBuilder: (context, index) =>
            const Divider(height: 1, indent: 74),
      );
    }
    return const Center(child: Text('Something went wrong.'));
  }

  void _handleTap(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) async {
    if (state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(SelectItem(entity));
    } else {
      if (entity is Directory) {
        context.read<FileExplorerBloc>().add(LoadDirectory(entity.path));
      } else {
        final result = await FileOpener.open(context, entity as File);
        if (result == true) {
          context.read<FileExplorerBloc>().add(LoadDirectory(state.path));
        }
      }
    }
  }

  void _handleLongPress(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) {
    if (!state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(ToggleSelectionMode(enable: true));
    }
    context.read<FileExplorerBloc>().add(SelectItem(entity));
  }

  Future<void> _handleCompress(
    BuildContext context,
    FileExplorerLoaded state,
  ) async {
    if (state.selectedItems.isEmpty) return;

    final TextEditingController nameController = TextEditingController(
      text: 'archive.zip',
    );

    final String? fileName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Compress to ZIP'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'Archive Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Compress'),
          ),
        ],
      ),
    );

    if (fileName != null && fileName.isNotEmpty && context.mounted) {
      // Filter only files for now, directories need recursive add logic in ArchiveService
      // My ArchiveService.compressFiles only takes List<File>.
      // So we filter:
      final filesOnly = state.selectedItems.whereType<File>().toList();

      if (filesOnly.length != state.selectedItems.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Warning: Folders skipped (not supported yet)'),
          ),
        );
      }

      if (filesOnly.isEmpty) return;

      try {
        final destPath = p.join(
          state.path,
          fileName.endsWith('.zip') ? fileName : '$fileName.zip',
        );
        await ArchiveService().compressFiles(filesOnly, File(destPath));

        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Compressed to $fileName')));
          // Refresh
          context.read<FileExplorerBloc>().add(LoadDirectory(state.path));
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Compression failed: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  final HttpServerService _httpService = HttpServerService();

  Future<void> _handleHttpShare(
    BuildContext context,
    FileExplorerState state,
  ) async {
    if (state is! FileExplorerLoaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot share: Directory not loaded')),
        );
      }
      return;
    }

    // Start Server
    try {
      final url = await _httpService.startServer(state.path);

      if (context.mounted) {
        await showDialog(
          context: context,
          barrierDismissible:
              false, // Force use of Stop button or explicit cancel
          builder: (context) => ServerStatusDialog(
            url: url,
            onStop: () async {
              // Dialog closes by itself in logic or we close it here?
              // The dialog calls onStop then pops.
              // So we just stop here.
              await _httpService.stopServer();
            },
          ),
        );
        // Ensure stopped if dialog closed otherwise
        if (_httpService.isRunning) {
          await _httpService.stopServer();
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to start server: $e')));
      }
    }
  }
}

// A simple, clean screen for handling the permission request.
class _PermissionDeniedScreen extends StatelessWidget {
  const _PermissionDeniedScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Permission Required',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              const Text(
                'To browse and manage your files, this app needs access to your device\'s storage. Please grant the permission in your device settings.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () async {
                  await Permission.manageExternalStorage.request();
                  // NOTE: The user will have to restart the app after granting permission
                  // for the FutureBuilder to re-run. This is a simple approach.
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
