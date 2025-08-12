part of 'task_progress_bloc.dart';

@immutable
abstract class TaskProgressState {}

class TaskIdle extends TaskProgressState {}

class TaskInProgress extends TaskProgressState {
  final String title;
  final String message;
  final double progress; // 0.0 to 1.0

  TaskInProgress({
    required this.title,
    required this.message,
    required this.progress,
  });
}