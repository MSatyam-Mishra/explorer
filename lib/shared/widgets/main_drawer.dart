import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/services/auth_service.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:explorer/features/category_view/bloc/bloc/screens/category_viewer_screen.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';
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

class MainDrawer extends StatelessWidget {
  const MainDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final sectionStyle = ClearGlassForeground.title(context).copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        );
    final itemColor = ClearGlassForeground.icon(context);

    return GlossyDrawer(
      child: Theme(
        data: Theme.of(context).copyWith(
          listTileTheme: ListTileThemeData(
            textColor: itemColor,
            iconColor: itemColor,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('Storage', style: sectionStyle),
            ),
            BlocBuilder<SidebarBloc, SidebarState>(
              builder: (context, state) {
                return Column(
                  children: [
                    const StorageDrawerItem(
                      icon: BootstrapIcons.phone_fill,
                      title: 'Internal Storage',
                      path: '/storage/emulated/0',
                    ),
                    if (state is SidebarLoaded)
                      ...state.externalStorage.map(
                        (volume) => StorageDrawerItem(
                          icon:
                              BootstrapIcons.usb_drive_fill, // or sd_card_fill
                          title: 'External (${p.basename(volume.path)})',
                          path: volume.path,
                        ),
                      ),
                  ],
                );
              },
            ),

            Divider(
              height: 24,
              color: Colors.white.withValues(alpha: 0.18),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('Categories', style: sectionStyle),
            ),

            // Use a BlocBuilder to show the categories when they are loaded
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
                          Navigator.pop(context); // Close the drawer first

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
                            // Use our new smart function here as well
                            final downloadsDir =
                                await DirectoryService.findDownloadsDirectory();
                            if (downloadsDir != null) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CategoryViewerScreen(
                                    categoryType: RequestType.common,
                                    title: 'Downloads',
                                    path: downloadsDir.path,
                                  ),
                                ),
                              );
                            }
                          }
                          if (category.name == 'Vault') {
                            final authService = AuthService();
                            final isAuthenticated = await authService
                                .authenticate();

                            if (isAuthenticated && context.mounted) {
                              // If authentication succeeds, open the vault
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const VaultScreen(),
                                ),
                              );
                            } else {
                              // If it fails, show a message
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Authentication Failed'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                          if (category.name == 'Apps') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AppManagerScreen(),
                              ),
                            );
                          }
                        },
                      );
                    }).toList(),
                  );
                }
                if (state is SidebarError) {
                  return ListTile(
                    leading: Icon(
                      BootstrapIcons.exclamation_triangle_fill,
                      color: Colors.redAccent,
                    ),
                    title: Text('Error loading categories'),
                    subtitle: Text(
                      state.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }

                // Show a simple loader while categories are being counted
                return const Center(child: CircularProgressIndicator());
              },
            ),
            Divider(
              height: 24,
              color: Colors.white.withValues(alpha: 0.18),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('Tools', style: sectionStyle),
            ),
            ListTile(
              leading: const Icon(BootstrapIcons.usb_drive),
              title: const Text('Bootable USB Creator'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const UsbBootScreen()),
                );
              },
            ),
            ],
          ),
        ),
      ),
    );
  }
}
