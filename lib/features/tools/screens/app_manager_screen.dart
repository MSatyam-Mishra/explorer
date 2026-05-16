import 'dart:io';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:installed_apps/app_info.dart';
import 'package:explorer/core/repositories/app_repository.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';

class AppManagerScreen extends StatefulWidget {
  const AppManagerScreen({super.key});

  @override
  State<AppManagerScreen> createState() => _AppManagerScreenState();
}

class _AppManagerScreenState extends State<AppManagerScreen> {
  final AppRepository _repository = AppRepository();
  List<AppInfo> _apps = [];
  bool _isLoading = true;
  bool _showSystemApps =
      true; // Default to all for now as we might not distinguish

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    setState(() => _isLoading = true);
    try {
      final apps = await _repository.getInstalledApps();
      setState(() {
        _apps = apps;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load apps: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  // Without explicit 'systemApp' flag in AppInfo (assumed missing),
  // filtering is hard. We'll just show all.
  List<AppInfo> get _filteredApps => _apps;

  Future<void> _exportApk(AppInfo app) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Export APK not supported with this update (Build fix)'),
      ),
    );
    /* 
    try {
      final downloadsDir = await DirectoryService.findDownloadsDirectory();
      if (downloadsDir == null) {
        throw Exception('Downloads directory not found');
      }

      final exportDir = Directory('${downloadsDir.path}/Explorere_Backups');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      await _repository.exportApk(app, exportDir);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to ${exportDir.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    */
  }

  @override
  Widget build(BuildContext context) {
    final displayApps = _filteredApps;

    return ExplorerScaffold(
      title: 'App Manager',
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: displayApps.length,
              itemBuilder: (context, index) {
                final app = displayApps[index];
                return ListTile(
                  leading: app.icon != null
                      ? Image.memory(app.icon!, width: 40, height: 40)
                      : const Icon(BootstrapIcons.android2, size: 40),
                  title: Text(app.name ?? 'Unknown'),
                  subtitle: Text(app.packageName ?? ''),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'open')
                        _repository.openApp(app.packageName!);
                      if (value == 'settings')
                        _repository.openAppSettings(app.packageName!);
                      // if (value == 'export') _exportApk(app); // Disabled
                      if (value == 'uninstall')
                        _repository.uninstallApp(app.packageName!);
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'open', child: Text('Open')),
                      const PopupMenuItem(
                        value: 'settings',
                        child: Text('App Settings'),
                      ),
                      const PopupMenuItem(
                        enabled: false,
                        value: 'export',
                        child: Text('Export APK (Disabled)'),
                      ),
                      const PopupMenuItem(
                        value: 'uninstall',
                        child: Text('Uninstall'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
