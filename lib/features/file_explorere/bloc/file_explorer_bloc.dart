import 'dart:io';
import 'package:bloc/bloc.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

part 'file_explorer_event.dart';
part 'file_explorer_state.dart';

class FileExplorerBloc extends Bloc<FileExplorerEvent, FileExplorerState> {
  FileExplorerBloc() : super(FileExplorerInitial()) {
    on<LoadDirectory>(_onLoadDirectory);

 on<ToggleSelectionMode>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(currentState.copyWith(
          isSelectionMode: event.enable,
          selectedItems: {}, // Clear selection when toggling mode
        ));
      }
    });

    on<SelectItem>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        // Create a new, modifiable set from the current selection
        final newSelectedItems = Set<FileSystemEntity>.from(currentState.selectedItems);
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


  }

  Future<void> _onLoadDirectory(
    LoadDirectory event,
    Emitter<FileExplorerState> emit,
  ) async {
    try {
      emit(FileExplorerLoading());
      final directory = Directory(event.path);
      
      // Check if directory exists and we have permission
      if (!await directory.exists()) {
        emit(FileExplorerError("Directory not found or access denied."));
        return;
      }
      
      final List<FileSystemEntity> entities = await directory.list().toList();
      
      // Sort the list: folders first, then files, all alphabetically
      entities.sort((a, b) {
        if (a is Directory && b is File) {
          return -1; // a (directory) comes before b (file)
        }
        if (a is File && b is Directory) {
          return 1; // b (directory) comes before a (file)
        }
        // Both are files or both are directories, sort by path
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });

      emit(FileExplorerLoaded(entities: entities, path: event.path));

    } catch (e) {
      emit(FileExplorerError("Failed to read directory: ${e.toString()}"));
    }
  }
}