import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:explorer/features/sidebar/model/category_model.dart';
import 'package:explorer/core/repositories/file_repository.dart';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

part 'sidebar_event.dart';
part 'sidebar_state.dart';

class SidebarBloc extends Bloc<SidebarEvent, SidebarState> {
  SidebarBloc() : super(SidebarLoading()) {
    on<LoadSidebarData>(_onLoadSidebarData);
  }

  Future<void> _onLoadSidebarData(
    LoadSidebarData event,
    Emitter<SidebarState> emit,
  ) async {
    emit(SidebarLoading());
    try {
      int photoCount = 0;
      int videoCount = 0;
      int audioCount = 0;

      if (!Platform.isWindows) {
        final ps = await PhotoManager.requestPermissionExtend();
        if (!ps.hasAccess) {
          emit(
            SidebarError('Storage permission is required to list categories.'),
          );
          return;
        }

        photoCount = await PhotoManager.getAssetCount(
          type: RequestType.image,
        );
        videoCount = await PhotoManager.getAssetCount(
          type: RequestType.video,
        );
        audioCount = await PhotoManager.getAssetCount(
          type: RequestType.audio,
        );
      }

      // Downloads Logic
      int downloadCount = 0;
      final Directory? downloadsDir =
          await DirectoryService.findDownloadsDirectory();
      if (downloadsDir != null && await downloadsDir.exists()) {
        downloadCount = await downloadsDir
            .list(recursive: true)
            .where((e) => e is File)
            .length;
      }

      final List<Category> categories = [
        Category(
          icon: LucideIcons.image,
          name: 'Photos',
          fileCount: photoCount,
          color: Colors.purple.shade300,
        ),
        Category(
          icon: LucideIcons.clapperboard,
          name: 'Video',
          fileCount: videoCount,
          color: Colors.red.shade300,
        ),
        Category(
          icon: LucideIcons.music,
          name: 'Audio',
          fileCount: audioCount,
          color: Colors.orange.shade300,
        ),
        Category(
          icon: LucideIcons.fileText,
          name: 'Documents',
          fileCount: 0,
          color: Colors.blue.shade300,
        ),
        Category(
          icon: LucideIcons.lock,
          name: 'Vault',
          fileCount: 0,
          color: Colors.teal.shade300,
        ),
        Category(
          icon: LucideIcons.archive,
          name: 'Archives',
          fileCount: 0,
          color: Colors.brown.shade300,
        ),
        Category(
          icon: LucideIcons.download,
          name: 'Downloads',
          fileCount: downloadCount,
          color: Colors.green.shade300,
        ),
        Category(
          icon: LucideIcons.cloud,
          name: 'Cloud Drive',
          fileCount: 0,
          color: Colors.indigo.shade300,
        ),
        Category(
          icon: LucideIcons.layoutGrid,
          name: 'Apps',
          fileCount: 0,
          color: Colors.tealAccent.shade700,
        ),
      ];

      // Fetch external storage volumes
      final externalVolumes = await LocalFileRepository().getStorageVolumes();

      emit(SidebarLoaded(categories, externalStorage: externalVolumes));
    } catch (e) {
      emit(SidebarError(e.toString()));
    }
  }
}
