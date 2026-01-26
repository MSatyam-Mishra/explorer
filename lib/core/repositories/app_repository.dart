import 'dart:io';
import 'package:device_apps/device_apps.dart';

class AppRepository {
  Future<List<Application>> getInstalledApps() async {
    return await DeviceApps.getInstalledApplications(
      includeAppIcons: true,
      includeSystemApps: true,
      onlyAppsWithLaunchIntent: false,
    );
  }

  Future<void> exportApk(ApplicationWithIcon app, Directory destination) async {
    // Check if apkFilePath is available
    if (app.apkFilePath.isEmpty) {
      throw Exception('APK path not available for ${app.appName}');
    }

    final sourceFile = File(app.apkFilePath);
    if (!await sourceFile.exists()) {
      throw Exception('APK file not found at ${app.apkFilePath}');
    }

    final destPath = '${destination.path}/${app.packageName}.apk';
    await sourceFile.copy(destPath);
  }

  Future<void> uninstallApp(String packageName) async {
    await DeviceApps.uninstallApp(packageName);
  }

  Future<void> openApp(String packageName) async {
    await DeviceApps.openApp(packageName);
  }

  Future<void> openAppSettings(String packageName) async {
    await DeviceApps.openAppSettings(packageName);
  }
}
