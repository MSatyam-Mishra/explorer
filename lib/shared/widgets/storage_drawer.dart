import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class StorageDrawerItem extends StatefulWidget {
  final IconData icon;
  final String title;
  final String path;

  const StorageDrawerItem({
    super.key,
    required this.icon,
    required this.title,
    required this.path,
  });

  @override
  State<StorageDrawerItem> createState() => _StorageDrawerItemState();
}

class _StorageDrawerItemState extends State<StorageDrawerItem> {
  double? _totalSpace;
  double? _usedSpace;
  DiskSpacePlus diskSpacePlus = DiskSpacePlus();

  @override
  void initState() {
    super.initState();
    _getDiskSpace();
  }

  Future<void> _getDiskSpace() async {
    // Attempt to get space for specific path
    double? total;
    double? free;

    if (widget.path == ExplorerPaths.androidInternalStorage) {
      try {
        total = await diskSpacePlus.getTotalDiskSpace;
        free = await diskSpacePlus.getFreeDiskSpace;
      } catch (e) {
        // debugPrint(e.toString());
      }
    } else {
      // For external storage paths, plugins vary.
      // We'll leave it simple for now and rely on Internal only showing space
      // unless we find a plugin that reliably takes paths.
      // disk_space_plus usually only returns for internal.
    }

    if (mounted) {
      if (total != null && free != null) {
        setState(() {
          _totalSpace = total;
          _usedSpace = total! - free!;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: ListTile(
        leading: Icon(widget.icon),
        title: Text(widget.title),
        subtitle: _totalSpace == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: _totalSpace! > 0 ? _usedSpace! / _totalSpace! : 0,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${filesize(((_totalSpace! - _usedSpace!) * 1024 * 1024).toInt())} free of ${filesize((_totalSpace! * 1024 * 1024).toInt())}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
        onTap: () {
          Navigator.pop(context);
          context.read<FileExplorerBloc>().add(LoadDirectory(widget.path));
        },
      ),
    );
  }
}
