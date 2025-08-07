import 'package:flutter/material.dart';

class MainDrawer extends StatelessWidget {
  const MainDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor,
            ),
            child: const Text(
              'Storage',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('Internal Storage'),
            onTap: () {
              // Logic to switch to internal storage
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.sd_card),
            title: const Text('SD Card'),
            onTap: () {
              // Logic to switch to SD card
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}