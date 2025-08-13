import 'dart:io';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/file_action_service.dart';

import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';

import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';

import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:explorer/shared/widgets/main_drawer.dart';
import 'package:explorer/shared/widgets/progress_card.dart';
import 'package:flutter/material.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
FileActionsService fileActionsService=  FileActionsService();
class FileExplorerScreen extends StatelessWidget {
  const FileExplorerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // We use a FutureBuilder to handle the initial permission check.
    return FutureBuilder<PermissionStatus>(
      future: Permission.manageExternalStorage.status,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final status = snapshot.data!;
        if (status.isGranted) {
          // If permission is granted, we build the main app UI with all the providers.
          return const _FileExplorerWithProviders();
        } else {
          // If permission is not granted, we show a dedicated screen.
          return const _PermissionDeniedScreen();
        }
      },
    );
  }
}

// This widget holds all our BLoCs at the very top.
class _FileExplorerWithProviders extends StatelessWidget {
  const _FileExplorerWithProviders();

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (context) => FileExplorerBloc()..add(LoadDirectory('/storage/emulated/0'))),
        BlocProvider(create: (context) => SidebarBloc()..add(LoadSidebarData())),
        BlocProvider(create: (context) => TaskProgressBloc()),
        BlocProvider(
          create: (context) => ClipboardBloc(
            taskProgressBloc: context.read<TaskProgressBloc>(),
          ),
        ),
      ],
      child: const _FileExplorerUI(),
    );
  }
}

// This is the actual UI, which is now guaranteed to be under all the providers.
class _FileExplorerUI extends StatelessWidget {
  const _FileExplorerUI();

  @override
  Widget build(BuildContext context) {
    // We listen to multiple BLoCs to build the final UI
    final fileExplorerState = context.watch<FileExplorerBloc>().state;
    final clipboardState = context.watch<ClipboardBloc>().state;
    final taskState = context.watch<TaskProgressBloc>().state;

    final bool canPop = fileExplorerState is FileExplorerLoaded
        ? fileExplorerState.path == '/storage/emulated/0'
        : true;
final bool isSelectionMode = fileExplorerState is FileExplorerLoaded ? fileExplorerState.isSelectionMode : false;
final int selectionCount = fileExplorerState is FileExplorerLoaded ? fileExplorerState.selectedItems.length : 0;

    return PopScope(
      canPop: canPop,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (fileExplorerState is FileExplorerLoaded) {
          final parentPath = p.dirname(fileExplorerState.path);
          context.read<FileExplorerBloc>().add(LoadDirectory(parentPath));
        }
      },
      child: Scaffold(
        appBar: AppBar(
           backgroundColor: isSelectionMode ? Theme.of(context).colorScheme.surface : Colors.black,
          title: Text(
            fileExplorerState is FileExplorerLoaded
                ? (fileExplorerState.path == '/storage/emulated/0' ? 'Files' : p.basename(fileExplorerState.path))
                : 'Files',
          ),
          leading: isSelectionMode
          ? IconButton(
              icon: const Icon(BootstrapIcons.x_lg),
              onPressed: () {
                context.read<FileExplorerBloc>().add(ToggleSelectionMode(enable: false));
              },
            )
          : null, 
        ),
        
        // The drawer can now correctly find the SidebarBloc!
        drawer: const MainDrawer(),
        body: Stack(
          children: [
            _buildFileList(context, fileExplorerState),
            if (taskState is TaskInProgress)
              ProgressCard(
                title: taskState.title,
                message: taskState.message,
                progress: taskState.progress,
              ),
          ],
        ),
        floatingActionButton: (clipboardState is ClipboardReadyToPaste)
            ? FloatingActionButton.extended(
                onPressed: () {
                  if (fileExplorerState is FileExplorerLoaded) {
                    context.read<ClipboardBloc>().add(PasteFromClipboard(fileExplorerState.path));
                  }
                },
                label: const Text('Paste'),
                icon: const Icon(BootstrapIcons.clipboard_check),
              )
            : null,
      ),
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
     
      return ListView.separated(
        itemCount: state.entities.length,
        itemBuilder: (context, index) {
          final entity = state.entities[index];
           final isSelected = state.selectedItems.contains(entity);
          return FileListItem(
             entity: entity,
  isSelectionMode: state.isSelectionMode,
  isSelected: isSelected,
            onTap: () async {

 if (state.isSelectionMode) {
      // In selection mode, a tap toggles the item
      context.read<FileExplorerBloc>().add(SelectItem(entity));
    } else {
      // Normal mode, a tap opens the file/folder
    if (entity is Directory) {
                context.read<FileExplorerBloc>().add(LoadDirectory(entity.path));
              } else {
                final result = await FileOpener.open(context, entity as File);
                if (result == true) {
                  context.read<FileExplorerBloc>().add(LoadDirectory(state.path));
                }
              }
    }

              
            },
            onLongPress: () {
              if (!state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(ToggleSelectionMode(enable: true));
    }
    context.read<FileExplorerBloc>().add(SelectItem(entity));
            },
          );
        },
        separatorBuilder: (context, index) => const Divider(height: 1, indent: 74),
      );
    }
    return const Center(child: Text('Something went wrong.'));
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
              Text('Permission Required', style: Theme.of(context).textTheme.headlineSmall),
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