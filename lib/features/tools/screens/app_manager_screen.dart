import 'dart:io';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:device_apps/device_apps.dart';
import 'package:explorer/core/repositories/app_repository.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:flutter/material.dart';

class AppManagerScreen extends StatefulWidget {
  const AppManagerScreen({super.key});

  @override
  State<AppManagerScreen> createState() => _AppManagerScreenState();
}

class _AppManagerScreenState extends State<AppManagerScreen> {
  final AppRepository _repository = AppRepository();
  List<Application> _apps = [];
  bool _isLoading = true;
  bool _showSystemApps = false;

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

  List<Application> get _filteredApps {
    if (_showSystemApps) return _apps;
    return _apps.where((app) => !app.systemApp).toList();
  }

  Future<void> _exportApk(Application app) async {
    if (app is! ApplicationWithIcon) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot export this app (No valid info)')),
      );
      return;
    }

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
  }

  @override
  Widget build(BuildContext context) {
    final displayApps = _filteredApps;

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Manager'),
        actions: [
          IconButton(
            icon: Icon(
              _showSystemApps
                  ? BootstrapIcons.eye_slash_fill
                  : BootstrapIcons.eye_fill,
            ),
            tooltip: _showSystemApps ? 'Hide System Apps' : 'Show System Apps',
            onPressed: () {
              setState(() {
                _showSystemApps = !_showSystemApps;
              });
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: displayApps.length,
              itemBuilder: (context, index) {
                final app = displayApps[index];
                return ListTile(
                  leading: app is ApplicationWithIcon
                      ? Image.memory(app.icon, width: 40, height: 40)
                      : const Icon(BootstrapIcons.android2, size: 40),
                  title: Text(app.appName),
                  subtitle: Text(app.packageName),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'open') _repository.openApp(app.packageName);
                      if (value == 'settings')
                        _repository.openAppSettings(app.packageName);
                      if (value == 'export') _exportApk(app);
                      if (value == 'uninstall')
                        _repository.uninstallApp(app.packageName);
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'open', child: Text('Open')),
                      const PopupMenuItem(
                        value: 'settings',
                        child: Text('App Settings'),
                      ),
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('Export APK'),
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
