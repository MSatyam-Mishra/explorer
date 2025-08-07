import 'dart:io';

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
        title: const Text('File Explorer'),
        backgroundColor: Colors.black.withOpacity(
          0.5,
        ), // Make appbar translucent
        elevation: 0,
      ),
      drawer: const MainDrawer(),
      // THIS IS THE NEW PART
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/background.jpg'), // Your image
            fit: BoxFit.cover,
          ),
        ),
        child: _buildBody(),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _checkPermissionStatus();
  }

  Widget _buildBody() {
    if (_isCheckingPermission) {
      // Show a loader while we check for permission initially
      return const Center(child: CircularProgressIndicator());
    }

    if (_isPermissionGranted) {
      // If permission is granted, show the actual file explorer view
      return const _FileExplorerView();
    } else {
      // If permission is denied, show the UI to request it
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
    return BlocProvider(
      create: (context) =>
          FileExplorerBloc()..add(LoadDirectory('/storage/emulated/0')),
      child: BlocBuilder<FileExplorerBloc, FileExplorerState>(
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
            return ListView.builder(
              itemCount: state.entities.length,
              // In the _FileExplorerView class build method...
              // ... inside the ListView.builder
              itemBuilder: (context, index) {
                final entity = state.entities[index];
                // Replace the old ListTile with our new custom widget
                // In the _FileExplorerView's ListView.builder...
                return FileListItem(
                  entity: entity,
                  onTap: () {
                    // This onTap is now for both files and folders
                    if (entity is Directory) {
                      context.read<FileExplorerBloc>().add(
                        LoadDirectory(entity.path),
                      );
                    } else {
                      FileOpener.open(context, entity as File);
                    }
                  },
                );
              },
            );
          }
          return const Center(child: Text('Something went wrong.'));
        },
      ),
    );
  }
}
