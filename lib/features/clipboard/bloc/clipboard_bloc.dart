import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:bloc/bloc.dart';
import 'package:explorer/core/services/background_tasks.dart';
import 'package:explorer/core/services/file_clipboard.dart';
import 'package:explorer/features/clipboard/paste_task.dart';
import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

part 'clipboard_event.dart';
part 'clipboard_state.dart';

/// Copy, cut and paste of files. The clipboard is shared with the other
/// Explorer windows (and on Windows with File Explorer), see
/// [FileClipboard].
class ClipboardBloc extends Bloc<ClipboardEvent, ClipboardState> {
  ClipboardBloc({required this.taskProgressBloc, FileClipboard? store})
      : clipboard = store ?? FileClipboard.instance,
        super(ClipboardEmpty()) {
    on<CopyToClipboard>((event, emit) => _put(event.entities, ClipboardOperation.copy, emit));
    on<CutToClipboard>((event, emit) => _put(event.entities, ClipboardOperation.cut, emit));
    on<ClearClipboard>((event, emit) async {
      emit(ClipboardEmpty());
      await _quietly(clipboard.clear);
    });
    on<_ClipboardChanged>(_onChanged);
    on<PasteFromClipboard>(_onPaste);
    on<TransferFiles>(_onTransfer);
    _changes = clipboard.changes.listen((_) => add(_ClipboardChanged()));
    // What another window copied before this one opened.
    add(_ClipboardChanged());
  }

  final TaskProgressBloc taskProgressBloc;
  final FileClipboard clipboard;
  late final StreamSubscription<void> _changes;
  bool _pasting = false;

  Future<void> _put(
    List<FileSystemEntity> entities,
    ClipboardOperation operation,
    Emitter<ClipboardState> emit,
  ) async {
    if (entities.isEmpty) return;
    emit(ClipboardReadyToPaste(entities: entities, operation: operation));
    await _quietly(() => clipboard.write(ClipboardFiles(
          [for (final e in entities) e.path],
          cut: operation == ClipboardOperation.cut,
        )));
  }

  Future<void> _onChanged(_ClipboardChanged event, Emitter<ClipboardState> emit) async {
    if (_pasting) return;
    ClipboardFiles? files;
    try {
      files = await clipboard.read();
    } catch (_) {
      return;
    }
    final entities = [
      for (final path in files?.paths ?? const <String>[])
        if (FileSystemEntity.isDirectorySync(path))
          Directory(path)
        else if (FileSystemEntity.isFileSync(path))
          File(path),
    ];
    final current = state;
    if (entities.isEmpty) {
      if (current is ClipboardReadyToPaste) emit(ClipboardEmpty());
      return;
    }
    final operation = files!.cut ? ClipboardOperation.cut : ClipboardOperation.copy;
    if (current is ClipboardReadyToPaste &&
        current.operation == operation &&
        listEquals([for (final e in current.entities) e.path], [for (final e in entities) e.path])) {
      return; // Ours, or unchanged.
    }
    emit(ClipboardReadyToPaste(entities: entities, operation: operation));
  }

  Future<void> _onPaste(PasteFromClipboard event, Emitter<ClipboardState> emit) async {
    final current = state;
    if (current is! ClipboardReadyToPaste || _pasting) return;
    final move = current.operation == ClipboardOperation.cut;
    final sources = [for (final e in current.entities) e.path];
    _pasting = true;
    try {
      final targets = await _transfer(sources, event.destinationPath, move);
      emit(ClipboardPasteSuccess(targets));
      if (move) {
        // Moved: nothing left to paste, in any window.
        emit(ClipboardEmpty());
        await _quietly(clipboard.clear);
      } else {
        emit(ClipboardReadyToPaste(entities: current.entities, operation: current.operation, pasted: true));
      }
    } catch (e) {
      emit(ClipboardPasteFailure(
        error: e is FileSystemException ? _describe(e) : '$e',
        previousState: current,
      ));
      emit(current);
    } finally {
      _pasting = false;
    }
  }

  Future<void> _onTransfer(TransferFiles event, Emitter<ClipboardState> emit) async {
    if (event.sources.isEmpty) return;
    final before = state;
    try {
      final targets = await _transfer(event.sources, event.destination, event.move);
      emit(ClipboardPasteSuccess(targets));
    } catch (e) {
      emit(ClipboardPasteFailure(error: e is FileSystemException ? _describe(e) : '$e'));
    }
    // What's on the clipboard stays.
    if (before is ClipboardReadyToPaste || before is ClipboardEmpty) emit(before);
  }

  /// Copies or moves with a progress card; returns where things went.
  Future<List<String>> _transfer(List<String> sources, String destination, bool move) async {
    final verb = move ? 'Moving' : 'Copying';
    final title = sources.length == 1
        ? '$verb "${p.basename(sources.single)}"'
        : '$verb ${sources.length} items';
    taskProgressBloc.add(TaskStarted(title: title, initialMessage: 'Getting ready…'));
    _task = BackgroundTasks.instance.start(title, message: 'Getting ready…');
    try {
      final targets = await _pasteInIsolate(sources, destination, move);
      _task!.outputs.addAll(targets);
      BackgroundTasks.instance.finish(_task!, message: 'Done: ${p.basename(destination)}');
      return targets;
    } catch (e) {
      BackgroundTasks.instance.fail(_task!, e is FileSystemException ? _describe(e) : '$e');
      rethrow;
    } finally {
      taskProgressBloc.add(TaskEnded());
      _task = null;
    }
  }

  BackgroundTask? _task;

  Future<List<String>> _pasteInIsolate(List<String> sources, String destination, bool move) async {
    final port = ReceivePort();
    final errors = ReceivePort();
    await Isolate.spawn(_paste, (port.sendPort, sources, destination, move), onError: errors.sendPort);
    final result = Completer<List<String>>();
    errors.listen((message) {
      if (!result.isCompleted) result.completeError(FileSystemException('${(message as List).first}'));
    });
    port.listen((message) {
      switch (message) {
        case PasteProgress(:final done, :final total, :final name):
          taskProgressBloc.add(TaskProgressUpdated(
            progress: total > 0 ? done / total : 1,
            message: name.isEmpty ? 'Finishing…' : name,
          ));
          _task?.update(progress: total > 0 ? done / total : 1, message: name.isEmpty ? 'Finishing…' : name);
        case List<String> targets:
          result.complete(targets);
        case (String message, String? path):
          result.completeError(FileSystemException(message, path));
      }
    });
    try {
      return await result.future;
    } finally {
      port.close();
      errors.close();
    }
  }

  static Future<void> _paste((SendPort, List<String>, String, bool) args) async {
    final (port, sources, destination, move) = args;
    try {
      port.send(await pasteEntities(sources, destination, move: move, onProgress: port.send));
    } on FileSystemException catch (e) {
      port.send((e.osError?.message.trim().isNotEmpty ?? false) ? ('${e.message}: ${e.osError!.message.trim()}', e.path) : (e.message, e.path));
    } catch (e) {
      port.send(('$e', null));
    }
  }

  static String _describe(FileSystemException e) =>
      e.path == null ? e.message : '${e.message} (${p.basename(e.path!)})';

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // The clipboard is busy or unavailable: this window still works.
    }
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    return super.close();
  }
}
