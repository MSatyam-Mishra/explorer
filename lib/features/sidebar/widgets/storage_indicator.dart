import 'package:disk_space_plus/disk_space_plus.dart'; // 1. Import the new package
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';

class StorageIndicator extends StatefulWidget {
  const StorageIndicator({super.key});

  @override
  State<StorageIndicator> createState() => _StorageIndicatorState();
}

class _StorageIndicatorState extends State<StorageIndicator> {
  double? _totalSpace;
  double? _usedSpace;

  @override
  void initState() {
    super.initState();
    _getDiskSpace();
  }

  Future<void> _getDiskSpace() async {
    DiskSpacePlus diskSpacePlus=DiskSpacePlus();
    // 2. Use the new DiskSpacePlus class
    final total = await diskSpacePlus.getTotalDiskSpace??0;
    final free = await diskSpacePlus.getFreeDiskSpace??0;
    
    if (mounted) {
      setState(() {
        _totalSpace = total;
        _usedSpace = total - free;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_totalSpace == null || _usedSpace == null) {
      return const SizedBox(height: 70); // Placeholder while loading
    }
    
    // 3. Convert GB to bytes for the filesize package
    final totalBytes = (_totalSpace! * 1024 * 1024 * 1024).toInt();
    final usedBytes = (_usedSpace! * 1024 * 1024 * 1024).toInt();
    final progress = _usedSpace! / _totalSpace!;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${filesize(usedBytes)} of ${filesize(totalBytes)} Used',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
      ),
    );
  }
}