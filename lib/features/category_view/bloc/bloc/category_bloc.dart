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

  Future<void> _onLoadCategoryAssets(
    LoadCategoryAssets event,
    Emitter<CategoryState> emit,
  ) async {
    emit(CategoryLoading());
    try {
      // A folder: its files grouped by day.
      if (event.type == RequestType.common) {
        final dir = Directory(event.path!);
        if (await dir.exists()) {
          // All files under the folder, newest first. Each file is stat'ed
          // once (not inside the sort comparator).
          final files = await dir
              .list(recursive: true)
              .handleError((Object _) {})
              .where((e) => e is File)
              .toList();
          final modified = <FileSystemEntity, DateTime>{};
          for (final file in files) {
            try {
              modified[file] = (await file.stat()).modified;
            } catch (_) {
              modified[file] = DateTime.fromMillisecondsSinceEpoch(0);
            }
          }
          files.sort((a, b) => modified[b]!.compareTo(modified[a]!));

          final groupedFiles = groupBy(files, (FileSystemEntity file) {
            final m = modified[file]!;
            return DateTime(m.year, m.month, m.day);
          });
          emit(CategoryLoaded(groupedFiles));
        } else {
          emit(CategoryError('Folder not found: ${event.path}'));
        }
        return; // Exit after handling this case
      }
      // Photos, videos or audio from the media library.
      // Only the "all" album: listing every album too would repeat each
      // photo once per album it's in.
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: event.type,
        onlyAll: true,
      );
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