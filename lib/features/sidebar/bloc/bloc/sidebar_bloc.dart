import 'dart:io';
import 'package:bloc/bloc.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/core/services/directory_services.dart';
import 'package:explorer/features/sidebar/model/category_model.dart';

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';


part 'sidebar_event.dart'; 
part 'sidebar_state.dart'; 

class SidebarBloc extends Bloc<SidebarEvent, SidebarState> { // Renamed
  SidebarBloc() : super(SidebarLoading()) { // Renamed
    on<LoadSidebarData>(_onLoadSidebarData); // Renamed
  }

  // In lib/features/sidebar/bloc/sidebar_bloc.dart

// In lib/features/sidebar/bloc/sidebar_bloc.dart

  Future<void> _onLoadSidebarData(
    LoadSidebarData event,
    Emitter<SidebarState> emit,
  ) async {
    emit(SidebarLoading());
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        emit(SidebarError('Storage permission is required to list categories.'));
        return;
      }

      // Media counts are the same
      final photoCount = await PhotoManager.getAssetCount(type: RequestType.image);
      final videoCount = await PhotoManager.getAssetCount(type: RequestType.video);
      final audioCount = await PhotoManager.getAssetCount(type: RequestType.audio);

      // --- THIS IS THE CORRECTED DOWNLOADS LOGIC ---
     int downloadCount = 0;
      // Use our new smart function instead of the default
      final Directory? downloadsDir = await DirectoryService.findDownloadsDirectory();
      if (downloadsDir != null && await downloadsDir.exists()) {
        downloadCount = await downloadsDir.list(recursive: true).where((e) => e is File).length;
      }
      // ---------------------------------------------
      
      final List<Category> categories = [
        Category(icon: BootstrapIcons.image_fill, name: 'Photos', fileCount: photoCount, color: Colors.purple.shade300),
        Category(icon: BootstrapIcons.play_circle_fill, name: 'Video', fileCount: videoCount, color: Colors.red.shade300),
        Category(icon: BootstrapIcons.music_note_beamed, name: 'Audio', fileCount: audioCount, color: Colors.orange.shade300),
        Category(icon: BootstrapIcons.file_earmark_text_fill, name: 'Documents', fileCount: 0, color: Colors.blue.shade300),
        Category(icon: BootstrapIcons.safe_fill, name: 'Vault', fileCount: 0, color: Colors.teal.shade300),
        Category(icon: BootstrapIcons.archive_fill, name: 'Archives', fileCount: 0, color: Colors.brown.shade300),
        Category(icon: BootstrapIcons.download, name: 'Downloads', fileCount: downloadCount, color: Colors.green.shade300),
        Category(icon: BootstrapIcons.cloud_fill, name: 'Cloud Drive', fileCount: 0, color: Colors.indigo.shade300),
      ];

      emit(SidebarLoaded(categories));
    } catch (e) {
      emit(SidebarError(e.toString()));
    }
  }
}