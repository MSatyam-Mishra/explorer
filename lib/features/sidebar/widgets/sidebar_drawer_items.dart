import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';

class StorageDrawerItem extends StatefulWidget {
  final IconData icon;
  final String title;

  const StorageDrawerItem({
    super.key,
    required this.icon,
    required this.title,
  });

  @override
  State<StorageDrawerItem> createState() => _StorageDrawerItemState();
}

class _StorageDrawerItemState extends State<StorageDrawerItem> {
  double? _totalSpace;
  double? _usedSpace;
DiskSpacePlus diskSpacePlus=DiskSpacePlus();
  @override
  void initState() {
    super.initState();
    _getDiskSpace();
  }

  Future<void> _getDiskSpace() async {
    final total = await diskSpacePlus.getTotalDiskSpace;
    final free = await diskSpacePlus.getFreeDiskSpace;
    if (mounted) {
      setState(() {
        _totalSpace = total;
        _usedSpace = total != null && free != null ? total - free : null;
      });
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
            ? const LinearProgressIndicator() // Show a simple loader
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: _usedSpace! / _totalSpace!,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${filesize((_totalSpace! - _usedSpace!) * 1024 * 1024 * 1024)} free of ${filesize(_totalSpace! * 1024 * 1024 * 1024)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
        onTap: () {
          // TODO: Navigate to the root of this storage device
        },
      ),
    );
  }
}