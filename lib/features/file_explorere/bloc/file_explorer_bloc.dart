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
        final sortedEntities = _sortEntities(
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
      emit(FileExplorerLoading());

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
      final sortedEntities = _sortEntities(
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

  List<FileSystemEntity> _sortEntities(
    List<FileSystemEntity> entities,
    SortOption option,
    SortOrder order, {
    Map<String, String> pathLabels = const {},
  }) {
    entities.sort((a, b) {
      int comparison = 0;
      switch (option) {
        case SortOption.name:
          comparison = _sortKey(a, pathLabels).compareTo(_sortKey(b, pathLabels));
          break;
        case SortOption.size:
          // For directories, we can't easily get size without traversing, so treat them as 0 or equal
          int sizeA = (a is File) ? a.lengthSync() : 0;
          int sizeB = (b is File) ? b.lengthSync() : 0;
          comparison = sizeA.compareTo(sizeB);
          break;
        case SortOption.date:
          comparison = a.statSync().modified.compareTo(b.statSync().modified);
          break;
        case SortOption.type:
          String typeA = (a is Directory) ? 'dir' : p.extension(a.path);
          String typeB = (b is Directory) ? 'dir' : p.extension(b.path);
          comparison = typeA.compareTo(typeB);
          break;
      }

      // Always keep folders on top regardless of sort option?
      // User requirements didn't strictly say "Folders on top", but it's standard convention.
      // However, for "Sort by Size/Date", mixing might be desired.
      // Let's implement strict sorting first, but keep folders-first as a secondary rule if names collide?
      // Actually, standard behavior is usually Folders First. Let's enforce Folders First.
      bool aIsDir = a is Directory;
      bool bIsDir = b is Directory;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;

      return order == SortOrder.ascending ? comparison : -comparison;
    });
    return entities;
  }
}
