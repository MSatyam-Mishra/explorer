import 'dart:io';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';

class AppRepository {
  Future<List<AppInfo>> getInstalledApps() async {
    return await InstalledApps.getInstalledApps(
      withIcon: true,
      excludeSystemApps: false,
      excludeNonLaunchableApps: false,
    );
  }

  Future<void> exportApk(AppInfo app, Directory destination) async {
    throw UnimplementedError("Export APK not yet verified with installed_apps");
  }

  Future<void> uninstallApp(String packageName) async {
    InstalledApps.uninstallApp(packageName);
  }

  Future<void> openApp(String packageName) async {
    InstalledApps.startApp(packageName);
  }

  Future<void> openAppSettings(String packageName) async {
    InstalledApps.openSettings(packageName);
  }
}
