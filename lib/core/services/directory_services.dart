import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class DirectoryService {
  static Future<Directory?> findDownloadsDirectory() async {
    try {
      // Get the root of external storage
      final Directory? externalDir = await getExternalStorageDirectory();
      if (externalDir == null) return null;

      // Check for the common names
      final List<String> commonNames = ['Download', 'Downloads'];
      
      for (final name in commonNames) {
        final dir = Directory(p.join(externalDir.path, name));
        if (await dir.exists()) {
          print('Found downloads directory at: ${dir.path}');
          return dir;
        }
      }
    } catch (e) {
      print('Error finding downloads directory: $e');
    }
    // Fallback to the default if our check fails
    return await getDownloadsDirectory();
  }
}