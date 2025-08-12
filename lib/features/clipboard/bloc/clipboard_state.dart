part of 'clipboard_bloc.dart';

enum ClipboardOperation { copy, cut }

@immutable
abstract class ClipboardState {}

class ClipboardEmpty extends ClipboardState {}

class ClipboardReadyToPaste extends ClipboardState {
  final FileSystemEntity sourceEntity;
  final ClipboardOperation operation;

  ClipboardReadyToPaste({required this.sourceEntity, required this.operation});
}
// ... existing states

class ClipboardPasting extends ClipboardState {
  final double progress; // 0.0 to 1.0
  final String timeLeft;

  ClipboardPasting({required this.progress, required this.timeLeft});
}

class ClipboardPasteSuccess extends ClipboardState {}

class ClipboardPasteFailure extends ClipboardState {
  final String error;
  final ClipboardReadyToPaste previousState;
  ClipboardPasteFailure({required this.error, required this.previousState});
}