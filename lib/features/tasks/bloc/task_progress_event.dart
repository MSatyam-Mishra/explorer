part of 'task_progress_bloc.dart';

@immutable
abstract class TaskProgressEvent {}

class TaskStarted extends TaskProgressEvent {
  final String title;
  final String initialMessage;
  TaskStarted({required this.title, required this.initialMessage});
}

class TaskProgressUpdated extends TaskProgressEvent {
  final String message;
  final double progress;
  TaskProgressUpdated({required this.message, required this.progress});
}

class TaskEnded extends TaskProgressEvent {}