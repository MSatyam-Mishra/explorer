part of 'file_explorer_bloc.dart';

@immutable
abstract class FileExplorerState {}

class FileExplorerInitial extends FileExplorerState {}

class FileExplorerLoading extends FileExplorerState {
  /// The folder being opened, when known.
  final String? path;

  FileExplorerLoading({this.path});
}

class FileExplorerLoaded extends FileExplorerState {
  final List<FileSystemEntity> entities;
  final String path;
  final bool isSelectionMode;
  final Set<FileSystemEntity> selectedItems;
  final ViewMode viewMode;
  final SortOption sortOption;
  final SortOrder sortOrder;

  /// Optional display names (e.g. Windows drives / libraries on This PC).
  final Map<String, String> pathLabels;

  FileExplorerLoaded({
    required this.entities,
    required this.path,
    this.isSelectionMode = false,
    this.selectedItems = const {},
    this.viewMode = ViewMode.list,
    this.sortOption = SortOption.name,
    this.sortOrder = SortOrder.ascending,
    this.pathLabels = const {},
  });

  String labelFor(FileSystemEntity entity) {
    return pathLabels[entity.path] ??
        ExplorerPaths.displayNameForEntity(entity.path);
  }

  FileExplorerLoaded copyWith({
    List<FileSystemEntity>? entities,
    String? path,
    bool? isSelectionMode,
    Set<FileSystemEntity>? selectedItems,
    ViewMode? viewMode,
    SortOption? sortOption,
    SortOrder? sortOrder,
    Map<String, String>? pathLabels,
  }) {
    return FileExplorerLoaded(
      entities: entities ?? this.entities,
      path: path ?? this.path,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      selectedItems: selectedItems ?? this.selectedItems,
      viewMode: viewMode ?? this.viewMode,
      sortOption: sortOption ?? this.sortOption,
      sortOrder: sortOrder ?? this.sortOrder,
      pathLabels: pathLabels ?? this.pathLabels,
    );
  }
}

class FileExplorerError extends FileExplorerState {
  final String message;

  /// The folder that failed to open, when known.
  final String? path;

  FileExplorerError(this.message, {this.path});
}
