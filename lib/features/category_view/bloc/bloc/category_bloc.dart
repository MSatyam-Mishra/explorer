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

  Future<void> _onLoadCategoryAssets(
    LoadCategoryAssets event,
    Emitter<CategoryState> emit,
  ) async {
    emit(CategoryLoading());
    try {
      // --- NEW LOGIC ---
      if (event.type == RequestType.common) { // We'll use this for regular folders
        final dir = Directory(event.path!); // A path must be provided
        if (await dir.exists()) {
          final files = await dir.list(recursive: true).where((e) => e is File).toList();
          
          files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

          final groupedFiles = groupBy(
            files,
            (FileSystemEntity file) => DateTime(
              file.statSync().modified.year,
              file.statSync().modified.month,
              file.statSync().modified.day,
            ),
          );
          // Notice this state holds FileSystemEntity now
          emit(CategoryLoaded(groupedFiles)); 
        } else {
          emit(CategoryError('Folder not found: ${event.path}'));
        }
        return;
      }
      // --- END OF NEW LOGIC ---

      // --- Existing photo_manager logic for media ---
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(type: event.type);
      // ... (rest of the photo_manager logic is the same)
      
      final groupedAssets = groupBy(
        allAssets,
        (AssetEntity asset) => DateTime(asset.createDateTime.year, /* ... */),
      );

      emit(CategoryLoaded(groupedAssets));
    } catch (e) {
      emit(CategoryError(e.toString()));
    }
  }
}