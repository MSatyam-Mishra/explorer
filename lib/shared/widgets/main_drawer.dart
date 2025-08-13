import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/services/auth_service.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:explorer/features/category_view/bloc/bloc/screens/category_viewer_screen.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';
import 'package:explorer/features/vault/screens/vault_screen.dart';

import 'package:explorer/shared/widgets/storage_drawer.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

class MainDrawer extends StatelessWidget {
  const MainDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Storage', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const StorageDrawerItem(
              icon: BootstrapIcons.phone_fill,
              title: 'Internal Storage',
            ),
        

            const Divider(height: 24),
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Categories', style: TextStyle(fontWeight: FontWeight.bold)),
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
                        onTap: () async{
                          
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
      final downloadsDir = await DirectoryService.findDownloadsDirectory();
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
  final isAuthenticated = await authService.authenticate();

  if (isAuthenticated && context.mounted) {
    // If authentication succeeds, open the vault
    Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultScreen()));
  } else {
    // If it fails, show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Authentication Failed'), backgroundColor: Colors.red),
    );
  }
}
      }
                      );
                    }).toList(),
                  );
                }
if (state is SidebarError) {
      return ListTile(
        leading: Icon(BootstrapIcons.exclamation_triangle_fill, color: Colors.redAccent),
        title: Text('Error loading categories'),
        subtitle: Text(state.message, maxLines: 2, overflow: TextOverflow.ellipsis),
      );
    }

                // Show a simple loader while categories are being counted
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ],
        ),
      ),
    );
  }
}