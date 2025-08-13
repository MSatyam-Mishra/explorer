import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart'; // Add this package to pubspec.yaml
import 'package:meta/meta.dart';
import 'package:photo_manager/photo_manager.dart';

part 'category_event.dart';
part 'category_state.dart';

class CategoryBloc extends Bloc<CategoryEvent, CategoryState> {
  CategoryBloc() : super(CategoryLoading()) {
    on<LoadCategoryAssets>(_onLoadCategoryAssets);
  }

  // Inside CategoryBloc

 // In lib/features/category_view/bloc/category_bloc.dart

// In lib/features/category_view/bloc/category_bloc.dart

  Future<void> _onLoadCategoryAssets(
    LoadCategoryAssets event,
    Emitter<CategoryState> emit,
  ) async {
    emit(CategoryLoading());
    try {
      // --- THIS IS THE CORRECTED LOGIC FOR FOLDERS ---
      if (event.type == RequestType.common) {
        final dir = Directory(event.path!);
        if (await dir.exists()) {
          // Get a flat list of all FILES recursively
          final files = await dir.list(recursive: true).where((e) => e is File).toList();
          
          // Sort the files by their modified date
          files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

          final groupedFiles = groupBy(
            files,
            (FileSystemEntity file) => DateTime(
              file.statSync().modified.year,
              file.statSync().modified.month,
              file.statSync().modified.day,
            ),
          );
          emit(CategoryLoaded(groupedFiles));
        } else {
          emit(CategoryError('Folder not found: ${event.path}'));
        }
        return; // Exit after handling this case
      }
      // ---------------------------------------------

      // Media logic remains the same
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(type: event.type);
      final List<AssetEntity> allAssets = [];

      for (final album in albums) {
        final assets = await album.getAssetListRange(start: 0, end: await album.assetCountAsync);
        allAssets.addAll(assets);
      }
      allAssets.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      final groupedAssets = groupBy(
        allAssets,
        (AssetEntity asset) => DateTime(asset.createDateTime.year, asset.createDateTime.month, asset.createDateTime.day),
      );

      emit(CategoryLoaded(groupedAssets));
    } catch (e) {
      emit(CategoryError(e.toString()));
    }
  }
}