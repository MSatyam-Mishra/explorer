part of 'file_explorer_bloc.dart';



@immutable
abstract class FileExplorerEvent {}

class LoadDirectory extends FileExplorerEvent {
  final String path;

  LoadDirectory(this.path);
}