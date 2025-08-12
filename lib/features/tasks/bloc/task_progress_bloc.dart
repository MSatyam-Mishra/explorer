import 'package:bloc/bloc.dart';
import 'package:meta/meta.dart';

part 'task_progress_event.dart';
part 'task_progress_state.dart';

class TaskProgressBloc extends Bloc<TaskProgressEvent, TaskProgressState> {
  TaskProgressBloc() : super(TaskIdle()) {
    on<TaskStarted>((event, emit) {
      emit(TaskInProgress(
        title: event.title,
        message: event.initialMessage,
        progress: 0.0,
      ));
    });

    on<TaskProgressUpdated>((event, emit) {
      final currentState = state;
      if (currentState is TaskInProgress) {
        emit(TaskInProgress(
          title: currentState.title,
          message: event.message,
          progress: event.progress,
        ));
      }
    });

    on<TaskEnded>((event, emit) {
      emit(TaskIdle());
    });
  }
}