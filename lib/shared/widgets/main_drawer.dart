import 'dart:io';

import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/platform/windows_locations.dart';
import 'package:explorer/core/services/auth_service.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:explorer/features/category_view/bloc/bloc/screens/category_viewer_screen.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/vault/screens/vault_screen.dart';
import 'package:explorer/features/tools/screens/app_manager_screen.dart';
import 'package:explorer/features/tools/screens/usb_boot_screen.dart';

import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/glossy_drawer.dart';
import 'package:explorer/shared/widgets/storage_drawer.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;

/// Closes the navigation drawer if [context] is inside an open one. When the
/// menu is docked as a side pane (tablets, foldables) this does nothing.
void dismissDrawer(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
}

/// Modal navigation drawer for phones.
class MainDrawer extends StatelessWidget {
  const MainDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlossyDrawer(child: MainDrawerContent());
  }
}

/// Storage, category and tool navigation; shown in [MainDrawer] on phones and
/// as a docked side pane on wide screens.
class MainDrawerContent extends StatelessWidget {
  const MainDrawerContent({super.key, this.padding});

  /// Padding around the list; defaults to the safe area.
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final sectionStyle = ClearGlassForeground.title(
      context,
    ).copyWith(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.4);
    final itemColor = ClearGlassForeground.icon(context);

    final list = Theme(
      data: Theme.of(context).copyWith(
        listTileTheme: ListTileThemeData(
          textColor: itemColor,
          iconColor: itemColor,
        ),
      ),
      child: ListView(
        padding: padding ?? EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Storage', style: sectionStyle),
          ),
          if (Platform.isWindows)
            _WindowsStorageSection()
          else
            BlocBuilder<SidebarBloc, SidebarState>(
              builder: (context, state) {
                return Column(
                  children: [
                    const StorageDrawerItem(
                      icon: BootstrapIcons.phone_fill,
                      title: 'Internal Storage',
                      path: ExplorerPaths.androidInternalStorage,
                    ),
                    if (state is SidebarLoaded)
                      ...state.externalStorage.map(
                        (volume) => StorageDrawerItem(
                          icon: BootstrapIcons.usb_drive_fill,
                          title: 'External (${p.basename(volume.path)})',
                          path: volume.path,
                        ),
                      ),
                  ],
                );
              },
            ),
          Divider(height: 24, color: Colors.white.withValues(alpha: 0.18)),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Categories', style: sectionStyle),
          ),
          BlocBuilder<SidebarBloc, SidebarState>(
            builder: (context, state) {
              if (state is SidebarLoaded) {
                return Column(
                  children: state.categories.map((category) {
                    return ListTile(
                      leading: Icon(category.icon, color: category.color),
                      title: Text(category.name),
                      trailing: Text(category.fileCount.toString()),
                      onTap: () async {
                        dismissDrawer(context);

                        RequestType? type;
                        switch (category.name) {
                          case 'Photos':
                            type = RequestType.image;
                            break;
                          case 'Video':
                            type = RequestType.video;
                            break;
                          case 'Audio':
                            type = RequestType.audio;
                            break;
                        }
                        if (type != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CategoryViewerScreen(
                                categoryType: type!,
                                title: category.name,
                              ),
                            ),
                          );
                        }
                        if (category.name == 'Downloads') {
                          final downloadsDir =
                              await DirectoryService.findDownloadsDirectory();
                          if (downloadsDir != null && context.mounted) {
                            context.read<FileExplorerBloc>().add(
                              LoadDirectory(downloadsDir.path),
                            );
                          }
                        }
                        if (category.name == 'Vault') {
                          final isAuthenticated = await AuthService()
                              .authenticate();
                          if (isAuthenticated && context.mounted) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const VaultScreen(),
                              ),
                            );
                          }
                        }
                      },
                    );
                  }).toList(),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Divider(height: 24, color: Colors.white.withValues(alpha: 0.18)),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Tools', style: sectionStyle),
          ),
          ListTile(
            leading: const Icon(BootstrapIcons.grid_fill),
            title: const Text('App Manager'),
            onTap: () {
              dismissDrawer(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AppManagerScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(BootstrapIcons.usb_drive),
            title: const Text('USB Boot'),
            onTap: () {
              dismissDrawer(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UsbBootScreen()),
              );
            },
          ),
        ],
      ),
    );
    return padding == null ? SafeArea(child: list) : list;
  }
}

class _WindowsStorageSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WindowsStorageLocation>>(
      future: WindowsLocations.listAll(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final drives = snapshot.data!
            .where((e) => e.kind == WindowsStorageKind.drive)
            .toList();
        final libraries = snapshot.data!
            .where((e) => e.kind == WindowsStorageKind.library)
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (drives.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 16, 4),
                child: Text(
                  'DRIVES',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 0.08,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ...drives.map(
                (d) => StorageDrawerItem(
                  icon: d.icon,
                  title: d.displayName,
                  path: d.path,
                ),
              ),
            ],
            if (libraries.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
                child: Text(
                  'LIBRARIES',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 0.08,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              StorageDrawerItem(
                icon: BootstrapIcons.pc_display,
                title: 'This PC',
                path: ExplorerPaths.windowsRoots,
              ),
              ...libraries.map(
                (lib) => StorageDrawerItem(
                  icon: lib.icon,
                  title: lib.displayName,
                  path: lib.path,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
