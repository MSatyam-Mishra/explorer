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

class ClearSelection extends FileExplorerEvent {}