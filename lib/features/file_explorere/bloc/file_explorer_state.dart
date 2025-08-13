part of 'file_explorer_bloc.dart';



@immutable
abstract class FileExplorerState {}

class FileExplorerInitial extends FileExplorerState {}

class FileExplorerLoading extends FileExplorerState {}


class FileExplorerLoaded extends FileExplorerState {
  final List<FileSystemEntity> entities;
  final String path;
  // NEW PROPERTIES
  final bool isSelectionMode;
  final Set<FileSystemEntity> selectedItems;

  FileExplorerLoaded({
    required this.entities,
    required this.path,
    this.isSelectionMode = false, // Default to off
    this.selectedItems = const {},   // Default to an empty set
  });

  // NEW: A copyWith method to make updating the state easier
  FileExplorerLoaded copyWith({
    List<FileSystemEntity>? entities,
    String? path,
    bool? isSelectionMode,
    Set<FileSystemEntity>? selectedItems,
  }) {
    return FileExplorerLoaded(
      entities: entities ?? this.entities,
      path: path ?? this.path,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      selectedItems: selectedItems ?? this.selectedItems,
    );
  }
}


class FileExplorerError extends FileExplorerState {
  final String message;

  FileExplorerError(this.message);
}