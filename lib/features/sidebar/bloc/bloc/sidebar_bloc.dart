import 'dart:io';
import 'package:bloc/bloc.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:explorer/features/sidebar/model/category_model.dart';

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';


part 'sidebar_event.dart'; // Renamed
part 'sidebar_state.dart'; // Renamed

class SidebarBloc extends Bloc<SidebarEvent, SidebarState> { // Renamed
  SidebarBloc() : super(SidebarLoading()) { // Renamed
    on<LoadSidebarData>(_onLoadSidebarData); // Renamed
  }

  // In lib/features/sidebar/bloc/sidebar_bloc.dart

  Future<void> _onLoadSidebarData(
    LoadSidebarData event,
    Emitter<SidebarState> emit,
  ) async {
    emit(SidebarLoading());
    print('[SidebarBloc] Starting to load sidebar data...');
    try {
      print('[SidebarBloc] Requesting photo manager permissions...');
      final ps = await PhotoManager.requestPermissionExtend();
      print('[SidebarBloc] Permission status: ${ps.name}');
      if (!ps.hasAccess) {
        emit(SidebarError('Storage permission is required to list categories.'));
        return;
      }

      print('[SidebarBloc] Getting photo count...');
      final photoCount = await PhotoManager.getAssetCount(type: RequestType.image);
      print('[SidebarBloc] Photo count: $photoCount');

      print('[SidebarBloc] Getting video count...');
      final videoCount = await PhotoManager.getAssetCount(type: RequestType.video);
      print('[SidebarBloc] Video count: $videoCount');

      print('[SidebarBloc] Getting audio count...');
      final audioCount = await PhotoManager.getAssetCount(type: RequestType.audio);
      print('[SidebarBloc] Audio count: $audioCount');

      print('[SidebarBloc] Getting downloads count...');
      final downloadsDir = await getDownloadsDirectory();
      int downloadCount = 0;
      if (downloadsDir != null) {
        downloadCount = await downloadsDir.list().length;
      }
      print('[SidebarBloc] Downloads count: $downloadCount');

      final List<Category> categories = [
        Category(icon: BootstrapIcons.image_fill, name: 'Photos', fileCount: photoCount, color: Colors.purple.shade300),
        Category(icon: BootstrapIcons.play_circle_fill, name: 'Video', fileCount: videoCount, color: Colors.red.shade300),
        Category(icon: BootstrapIcons.music_note_beamed, name: 'Audio', fileCount: audioCount, color: Colors.orange.shade300),
        Category(icon: BootstrapIcons.file_earmark_text_fill, name: 'Documents', fileCount: 0, color: Colors.blue.shade300), // Placeholder
        Category(icon: BootstrapIcons.safe_fill, name: 'Vault', fileCount: 0, color: Colors.teal.shade300), // Placeholder
        Category(icon: BootstrapIcons.archive_fill, name: 'Archives', fileCount: 0, color: Colors.brown.shade300), // Placeholder
        Category(icon: BootstrapIcons.download, name: 'Downloads', fileCount: downloadCount, color: Colors.green.shade300),
        Category(icon: BootstrapIcons.cloud_fill, name: 'Cloud Drive', fileCount: 0, color: Colors.indigo.shade300),
      ];

      print('[SidebarBloc] All data loaded. Emitting SidebarLoaded state.');
      emit(SidebarLoaded(categories));
    } catch (e, stackTrace) {
      print('[SidebarBloc] CRITICAL ERROR: $e');
      print('[SidebarBloc] Stack Trace: $stackTrace');
      emit(SidebarError(e.toString()));
    }
  }
}