import 'dart:io';

import 'package:path/path.dart' as p;

/// Sends files over Bluetooth with the system's own tool: the Bluetooth
/// File Transfer wizard on Windows (what File Explorer's Send to uses), or
/// bluetooth-sendto (GNOME) / blueman-sendto on Linux. Phones send through
/// the share sheet.
abstract final class BluetoothShare {
  static String? _tool;
  static bool _looked = false;

  /// The tool, if this computer has one.
  static String? get tool {
    if (_looked) return _tool;
    _looked = true;
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final wizard = p.join(root, 'System32', 'fsquirt.exe');
      if (File(wizard).existsSync()) _tool = wizard;
    } else if (Platform.isLinux) {
      final path = (Platform.environment['PATH'] ?? '').split(':');
      for (final name in const ['bluetooth-sendto', 'blueman-sendto']) {
        for (final dir in path) {
          if (dir.isNotEmpty && File(p.join(dir, name)).existsSync()) {
            return _tool = p.join(dir, name);
          }
        }
      }
    }
    return _tool;
  }

  static bool get available => tool != null;

  /// Opens the tool with [files] chosen; it asks for the device.
  static Future<void> send(List<String> files) async {
    await Process.start(tool!, files, mode: ProcessStartMode.detached);
  }
}
