part of 'clipboard_bloc.dart';

enum ClipboardOperation { copy, cut }

@immutable
abstract class ClipboardState {}

class ClipboardEmpty extends ClipboardState {}

class ClipboardReadyToPaste extends ClipboardState {
  /// What was copied or cut, in any window (or another app).
  final List<FileSystemEntity> entities;
  final ClipboardOperation operation;

  /// Already pasted here once: still on the clipboard (Ctrl+V, Paste in
  /// the menu), but the paste bar is put away.
  final bool pasted;

  ClipboardReadyToPaste({
    required this.entities,
    required this.operation,
    this.pasted = false,
  });
}

class ClipboardPasteSuccess extends ClipboardState {
  /// Where the pasted items ended up.
  final List<String> targets;
  ClipboardPasteSuccess([this.targets = const []]);
}

class ClipboardPasteFailure extends ClipboardState {
  final String error;

  /// What was on the clipboard (null for a drop).
  final ClipboardReadyToPaste? previousState;
  ClipboardPasteFailure({required this.error, this.previousState});
}
