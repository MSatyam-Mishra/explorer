import 'dart:io';
import 'package:bloc/bloc.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

part 'file_explorer_event.dart';
part 'file_explorer_state.dart';

class FileExplorerBloc extends Bloc<FileExplorerEvent, FileExplorerState> {
  final FileRepository repository;

  FileExplorerBloc({FileRepository? repository})
    : repository = repository ?? LocalFileRepository(),
      super(FileExplorerInitial()) {
    on<LoadDirectory>(_onLoadDirectory);

    on<ToggleSelectionMode>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(
          currentState.copyWith(
            isSelectionMode: event.enable,
            selectedItems: {}, // Clear selection when toggling mode
          ),
        );
      }
    });

    on<SelectItem>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        // Create a new, modifiable set from the current selection
        final newSelectedItems = Set<FileSystemEntity>.from(
          currentState.selectedItems,
        );
        if (newSelectedItems.contains(event.entity)) {
          newSelectedItems.remove(event.entity); // Deselect if already selected
        } else {
          newSelectedItems.add(event.entity); // Select if not selected
        }
        emit(currentState.copyWith(selectedItems: newSelectedItems));
      }
    });

    on<ClearSelection>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(currentState.copyWith(selectedItems: {}));
      }
    });
    on<ChangeViewMode>((event, emit) async {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        await FolderPrefsService().setViewMode(currentState.path, event.mode);
        emit(currentState.copyWith(viewMode: event.mode));
      }
    });

    on<ChangeSortOrder>((event, emit) async {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        await FolderPrefsService().setSort(
          currentState.path,
          event.option,
          event.order,
        );
        final sortedEntities = await _sortEntities(
          currentState.entities,
          event.option,
          event.order,
          pathLabels: currentState.pathLabels,
        );
        emit(
          currentState.copyWith(
            sortOption: event.option,
            sortOrder: event.order,
            entities: sortedEntities,
          ),
        );
      }
    });
  }

  Future<void> _onLoadDirectory(
    LoadDirectory event,
    Emitter<FileExplorerState> emit,
  ) async {
    try {
      // Refreshing the folder already on screen (e.g. after a viewer saved a
      // copy) keeps the list and its scroll position instead of flashing a
      // spinner.
      final current = state;
      final refreshing =
          current is FileExplorerLoaded && current.path == event.path;
      if (!refreshing) emit(FileExplorerLoading());

      if (!await repository.exists(event.path)) {
        emit(FileExplorerError("Directory not found or access denied."));
        return;
      }

      await FolderPrefsService().init();
      final viewMode = FolderPrefsService().getViewMode(event.path);
      final sortOption = FolderPrefsService().getSortOption(event.path);
      final sortOrder = FolderPrefsService().getSortOrder(event.path);

      Map<String, String> pathLabels = {};
      if (ExplorerPaths.isWindowsRoots(event.path) &&
          repository is LocalFileRepository) {
        pathLabels =
            await (repository as LocalFileRepository).windowsRootLabels();
      }

      final List<FileSystemEntity> entities = await repository.listEntities(
        event.path,
      );
      final sortedEntities = await _sortEntities(
        entities,
        sortOption,
        sortOrder,
        pathLabels: pathLabels,
      );

      emit(
        FileExplorerLoaded(
          entities: sortedEntities,
          path: event.path,
          viewMode: viewMode,
          sortOption: sortOption,
          sortOrder: sortOrder,
          pathLabels: pathLabels,
        ),
      );
    } catch (e) {
      emit(FileExplorerError("Failed to read directory: ${e.toString()}"));
    }
  }

  String _sortKey(FileSystemEntity entity, Map<String, String> pathLabels) {
    return (pathLabels[entity.path] ?? p.basename(entity.path)).toLowerCase();
  }

  static Future<FileStat?> _statOrNull(FileSystemEntity entity) async {
    try {
      return await entity.stat();
    } catch (_) {
      return null;
    }
  }

  /// Sorts with folders first. Each entry's key is computed once (size/date
  /// via async stat calls) instead of inside the comparator, which used to
  /// make O(n log n) synchronous stat calls on the UI isolate.
  Future<List<FileSystemEntity>> _sortEntities(
    List<FileSystemEntity> entities,
    SortOption option,
    SortOrder order, {
    Map<String, String> pathLabels = const {},
  }) async {
    final List<Comparable<Object>> keys;
    switch (option) {
      case SortOption.name:
        keys = [for (final e in entities) _sortKey(e, pathLabels)];
      case SortOption.size:
        // Folder sizes would need a full traversal; they sort as 0.
        final stats = await Future.wait([
          for (final e in entities)
            e is File ? _statOrNull(e) : Future<FileStat?>.value(null),
        ]);
        keys = [for (final s in stats) s?.size ?? 0];
      case SortOption.date:
        final stats = await Future.wait(entities.map(_statOrNull));
        keys = [for (final s in stats) s?.modified.millisecondsSinceEpoch ?? 0];
      case SortOption.type:
        keys = [
          for (final e in entities) e is Directory ? 'dir' : p.extension(e.path),
        ];
    }
    final indices = List<int>.generate(entities.length, (i) => i);
    indices.sort((i, j) {
      final aIsDir = entities[i] is Directory;
      final bIsDir = entities[j] is Directory;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      final comparison = keys[i].compareTo(keys[j]);
      return order == SortOrder.ascending ? comparison : -comparison;
    });
    return [for (final i in indices) entities[i]];
  }
}
