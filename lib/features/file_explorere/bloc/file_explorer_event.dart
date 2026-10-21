part of 'file_explorer_bloc.dart';

@immutable
abstract class FileExplorerEvent {}

class LoadDirectory extends FileExplorerEvent {
  final String path;

  LoadDirectory(this.path);
}

class ToggleSelectionMode extends FileExplorerEvent {
  final bool enable;
  ToggleSelectionMode({required this.enable});
}

class SelectItem extends FileExplorerEvent {
  final FileSystemEntity entity;
  SelectItem(this.entity);
}

class ChangeViewMode extends FileExplorerEvent {
  final ViewMode mode;
  ChangeViewMode(this.mode);
}

class ChangeSortOrder extends FileExplorerEvent {
  final SortOption option;
  final SortOrder order;
  ChangeSortOrder(this.option, this.order);
}

class ClearSelection extends FileExplorerEvent {}

/// Selects every entry in the current folder.
class SelectAll extends FileExplorerEvent {}
