part of 'file_explorer_bloc.dart';

@immutable
abstract class FileExplorerState {}

class FileExplorerInitial extends FileExplorerState {}

class FileExplorerLoading extends FileExplorerState {}

class FileExplorerLoaded extends FileExplorerState {
  final List<FileSystemEntity> entities;
  final String path;
  final bool isSelectionMode;
  final Set<FileSystemEntity> selectedItems;
  final ViewMode viewMode;
  final SortOption sortOption;
  final SortOrder sortOrder;

  FileExplorerLoaded({
    required this.entities,
    required this.path,
    this.isSelectionMode = false,
    this.selectedItems = const {},
    this.viewMode = ViewMode.list,
    this.sortOption = SortOption.name,
    this.sortOrder = SortOrder.ascending,
  });

  FileExplorerLoaded copyWith({
    List<FileSystemEntity>? entities,
    String? path,
    bool? isSelectionMode,
    Set<FileSystemEntity>? selectedItems,
    ViewMode? viewMode,
    SortOption? sortOption,
    SortOrder? sortOrder,
  }) {
    return FileExplorerLoaded(
      entities: entities ?? this.entities,
      path: path ?? this.path,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      selectedItems: selectedItems ?? this.selectedItems,
      viewMode: viewMode ?? this.viewMode,
      sortOption: sortOption ?? this.sortOption,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class FileExplorerError extends FileExplorerState {
  final String message;

  FileExplorerError(this.message);
}
