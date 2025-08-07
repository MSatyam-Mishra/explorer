part of 'file_explorer_bloc.dart';



@immutable
abstract class FileExplorerState {}

class FileExplorerInitial extends FileExplorerState {}

class FileExplorerLoading extends FileExplorerState {}

class FileExplorerLoaded extends FileExplorerState {
  final List<FileSystemEntity> entities;
  final String path;

  FileExplorerLoaded({required this.entities, required this.path});
}

class FileExplorerError extends FileExplorerState {
  final String message;

  FileExplorerError(this.message);
}