import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:photo_manager/photo_manager.dart';

part 'category_event.dart';
part 'category_state.dart';

class CategoryBloc extends Bloc<CategoryEvent, CategoryState> {
  /// The last full list per media type, shown while it's refreshed.
  static final _mediaCache = <RequestType, Map<DateTime, List<dynamic>>>{};

  static Map<DateTime, List<dynamic>> _snapshot(
    Map<DateTime, List<dynamic>> groups,
  ) => {for (final e in groups.entries) e.key: List.unmodifiable(e.value)};

  static int _length(Map<DateTime, List<dynamic>> groups) =>
      groups.values.fold(0, (sum, list) => sum + list.length);

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
      // Photos, videos or audio from the media library, newest first.
      // The last list shows at once; the newest page then replaces it and
      // older pages follow in the background, so big libraries open fast.
      final cached = _mediaCache[event.type];
      if (cached != null) emit(CategoryLoaded(cached));

      // Only the "all" album: listing every album too would repeat each
      // photo once per album it's in.
      final albums = await PhotoManager.getAssetPathList(
        type: event.type,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (albums.isEmpty) {
        _mediaCache[event.type] = const {};
        emit(CategoryLoaded(const {}));
        return;
      }
      final album = albums.first;
      final total = await album.assetCountAsync;
      final groups = <DateTime, List<dynamic>>{};
      var start = 0;
      var pageSize = 120;
      while (start < total) {
        final end = start + pageSize > total ? total : start + pageSize;
        final page = await album.getAssetListRange(start: start, end: end);
        if (page.isEmpty || emit.isDone || isClosed) break;
        for (final asset in page) {
          final t = asset.createDateTime;
          (groups[DateTime(t.year, t.month, t.day)] ??= []).add(asset);
        }
        start = end;
        pageSize = 1000;
        // Keep the cached list until the new one has caught up with it.
        if (cached == null || start >= total || start >= _length(cached)) {
          emit(CategoryLoaded(_snapshot(groups)));
        }
      }
      if (!emit.isDone && !isClosed) {
        final result = _snapshot(groups);
        _mediaCache[event.type] = result;
        emit(CategoryLoaded(result));
      }
    } catch (e) {
      // Keep showing what's already loaded.
      if (state is! CategoryLoaded && !emit.isDone) {
        emit(CategoryError(e.toString()));
      }
    }
  }
}
