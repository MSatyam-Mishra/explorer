import 'dart:io';

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:permission_handler/permission_handler.dart';

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

  // In the FileExplorerScreen class build method...
@override
Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
            title: const Text('Files'),
            // Make the AppBar flat and match the background for a modern look
            backgroundColor: Theme.of(context).colorScheme.surface,
            elevation: 0,
        ),
        drawer: const MainDrawer(),
        // REMOVED the background image Container. Just call _buildBody() directly.
        body: _buildBody(),
    );
}

  @override
  void initState() {
    super.initState();
    _checkPermissionStatus();
  }

  Widget _buildBody() {
    if (_isCheckingPermission) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isPermissionGranted) {

      return BlocProvider(
        create: (context) => FileExplorerBloc()
          ..add(LoadDirectory('/storage/emulated/0')), 
        child: const _FileExplorerView(), 
      );
      // -----------------------
    } else {
      // The permission denied UI doesn't need the BLoC, so it's separate.
      return _buildPermissionDeniedUI();
    }
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
}

// We've moved the BLoC logic into its own private widget.
// This widget is ONLY built AFTER we confirm permission is granted.
class _FileExplorerView extends StatelessWidget {
  const _FileExplorerView();

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
                      entity: entity,
                      onTap: () {
                        if (entity is Directory) {
                          context.read<FileExplorerBloc>().add(LoadDirectory(entity.path));
                        } else {
                          FileOpener.open(context, entity as File);
                        }
                      },
                    ).animate().slide(
      delay: (10 * index).ms, // Staggered delay for each item
      duration: 400.ms,
      begin: const Offset(0, 0.5),
      curve: Curves.easeOutCubic,
    ).fade(duration: 400.ms, curve: Curves.easeOutCubic); 
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