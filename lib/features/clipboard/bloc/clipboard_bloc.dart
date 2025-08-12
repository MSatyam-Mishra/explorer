import 'dart:io';
import 'dart:isolate';
import 'package:bloc/bloc.dart';
import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

part 'clipboard_event.dart';
part 'clipboard_state.dart';

// 1. These are now PUBLIC and TOP-LEVEL, so the Isolate can find them.
class CopyTaskParams {
  final SendPort sendPort;
  final String sourcePath;
  final String destinationPath;

  CopyTaskParams({
    required this.sendPort,
    required this.sourcePath,
    required this.destinationPath,
  });
}

void copyTask(CopyTaskParams params) async {
  try {
    final sourceEntity = Directory(params.sourcePath).existsSync()
        ? Directory(params.sourcePath)
        : File(params.sourcePath);
    
    // First, calculate the total size for accurate progress
    int totalBytes = 0;
    if (sourceEntity is Directory) {
      await for (final file in sourceEntity.list(recursive: true)) {
        if (file is File) {
          totalBytes += await file.length();
        }
      }
    } else if (sourceEntity is File) {
      totalBytes = await sourceEntity.length();
    }

    int copiedBytes = 0;
    final startTime = DateTime.now();

    // Now, perform the copy and report progress
    if (sourceEntity is Directory) {
      final newDir = Directory(params.destinationPath);
      await newDir.create(recursive: true);

      await for (final entity in sourceEntity.list(recursive: true, followLinks: false)) {
        final newPath = p.join(params.destinationPath, p.relative(entity.path, from: sourceEntity.path));
        if (entity is Directory) {
          await Directory(newPath).create(recursive: true);
        } else if (entity is File) {
          final fileBytes = await entity.readAsBytes();
          await File(newPath).writeAsBytes(fileBytes);
          copiedBytes += fileBytes.length;

          // Send progress back to the main app
          final progress = totalBytes > 0 ? copiedBytes / totalBytes : 1.0;
          final elapsedTime = DateTime.now().difference(startTime);
          final speed = copiedBytes / (elapsedTime.inSeconds + 1);
          final remainingBytes = totalBytes - copiedBytes;
          final timeLeftInSeconds = (remainingBytes / (speed > 0 ? speed : 1)).round();
          final timeLeft = Duration(seconds: timeLeftInSeconds).toString().split('.').first.substring(2);
          
          params.sendPort.send({'progress': progress, 'timeLeft': timeLeft, 'message': 'Copying "${p.basename(entity.path)}"'});
        }
      }
    } else if (sourceEntity is File) {
      // Single file copy logic
      final destinationFile = File(params.destinationPath);
      final sink = destinationFile.openWrite();
      await for (final chunk in sourceEntity.openRead()) {
        sink.add(chunk);
        copiedBytes += chunk.length;
        final progress = copiedBytes / totalBytes;
        final elapsedTime = DateTime.now().difference(startTime);
        final speed = copiedBytes / (elapsedTime.inSeconds + 1);
        final remainingBytes = totalBytes - copiedBytes;
        final timeLeftInSeconds = (remainingBytes / (speed > 0 ? speed : 1)).round();
        final timeLeft = Duration(seconds: timeLeftInSeconds).toString().split('.').first.substring(2);
        params.sendPort.send({'progress': progress, 'timeLeft': timeLeft, 'message': 'Copying "${p.basename(sourceEntity.path)}"'});
      }
      await sink.close();
    }

    params.sendPort.send('done');
  } catch (e) {
    params.sendPort.send({'error': e.toString()});
  }
}


class ClipboardBloc extends Bloc<ClipboardEvent, ClipboardState> {
  final TaskProgressBloc taskProgressBloc;

  ClipboardBloc({required this.taskProgressBloc}) : super(ClipboardEmpty()) {
    on<CopyToClipboard>((event, emit) {
      emit(ClipboardReadyToPaste(
        sourceEntity: event.entity,
        operation: ClipboardOperation.copy,
      ));
    });

    on<CutToClipboard>((event, emit) {
      emit(ClipboardReadyToPaste(
        sourceEntity: event.entity,
        operation: ClipboardOperation.cut,
      ));
    });

    on<ClearClipboard>((event, emit) {
      emit(ClipboardEmpty());
    });

    on<PasteFromClipboard>((event, emit) async {
      final currentState = state;
      if (currentState is! ClipboardReadyToPaste) return;

      final source = currentState.sourceEntity;
      final operationName = currentState.operation == ClipboardOperation.copy ? 'Copying' : 'Moving';
      taskProgressBloc.add(TaskStarted(title: 'File Operation', initialMessage: '$operationName "${p.basename(source.path)}"'));

      try {
        final destination = p.join(event.destinationPath, p.basename(source.path));
        if (source.path == event.destinationPath) throw Exception("Cannot paste a folder into itself.");

        if (currentState.operation == ClipboardOperation.cut) {
          // Move is fast, no Isolate needed
          await source.rename(destination);
          taskProgressBloc.add(TaskEnded());
          emit(ClipboardPasteSuccess());
          emit(ClipboardEmpty());
        } else { // Handle Copy with Isolate
          final receivePort = ReceivePort();
          final params = CopyTaskParams(
            sendPort: receivePort.sendPort,
            sourcePath: source.path,
            destinationPath: destination,
          );

          await Isolate.spawn(copyTask, params);

          await for (final message in receivePort) {
            if (message is Map) {
              if (message.containsKey('error')) {
                throw Exception(message['error']);
              }
              taskProgressBloc.add(TaskProgressUpdated(
                progress: message['progress'],
                message: message['message'],
              ));
            } else if (message == 'done') {
              taskProgressBloc.add(TaskEnded());
              emit(ClipboardPasteSuccess());
              emit(ClipboardEmpty());
              receivePort.close();
              break;
            }
          }
        }
      } catch (e) {
        taskProgressBloc.add(TaskEnded());
        // Handle error state by emitting a failure
        emit(ClipboardPasteFailure(
          error: e.toString(),
          previousState: currentState,
        ));
      }
    });
  }
}