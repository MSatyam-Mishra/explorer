import 'dart:io';

import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// A drive letter root or a known user library folder on Windows.
class WindowsStorageLocation {
  const WindowsStorageLocation({
    required this.displayName,
    required this.path,
    required this.kind,
    required this.icon,
  });

  final String displayName;
  final String path;
  final WindowsStorageKind kind;
  final IconData icon;
}

enum WindowsStorageKind { drive, library }

abstract final class WindowsLocations {
  WindowsLocations._();

  static Future<List<WindowsStorageLocation>> listDrives() async {
    if (!Platform.isWindows) return [];

    final drives = <WindowsStorageLocation>[];
    for (var code = 65; code <= 90; code++) {
      final letter = String.fromCharCode(code);
      final root = '$letter:\\';
      if (await Directory(root).exists()) {
        drives.add(
          WindowsStorageLocation(
            displayName: 'Local Disk ($letter:)',
            path: root,
            kind: WindowsStorageKind.drive,
            icon: BootstrapIcons.hdd_stack_fill,
          ),
        );
      }
    }
    return drives;
  }

  static Future<List<WindowsStorageLocation>> listLibraries() async {
    if (!Platform.isWindows) return [];

    final profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) return [];

    const libraryDefs = <(String name, String segment, IconData icon)>[
      ('Desktop', 'Desktop', BootstrapIcons.window_desktop),
      ('Documents', 'Documents', BootstrapIcons.file_earmark_text_fill),
      ('Downloads', 'Downloads', BootstrapIcons.download),
      ('Pictures', 'Pictures', BootstrapIcons.image_fill),
      ('Music', 'Music', BootstrapIcons.music_note_beamed),
      ('Videos', 'Videos', BootstrapIcons.play_circle_fill),
    ];

    final libraries = <WindowsStorageLocation>[];
    for (final def in libraryDefs) {
      final dir = Directory(p.join(profile, def.$2));
      if (await dir.exists()) {
        libraries.add(
          WindowsStorageLocation(
            displayName: def.$1,
            path: dir.path,
            kind: WindowsStorageKind.library,
            icon: def.$3,
          ),
        );
      }
    }

    final home = Directory(profile);
    if (await home.exists()) {
      libraries.insert(
        0,
        WindowsStorageLocation(
          displayName: 'User folder',
          path: home.path,
          kind: WindowsStorageKind.library,
          icon: BootstrapIcons.person_fill,
        ),
      );
    }

    return libraries;
  }

  static Future<List<WindowsStorageLocation>> listAll() async {
    final drives = await listDrives();
    final libraries = await listLibraries();
    return [...drives, ...libraries];
  }
}
