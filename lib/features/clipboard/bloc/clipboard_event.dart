part of 'clipboard_bloc.dart';

@immutable
abstract class ClipboardEvent {}

class CopyToClipboard extends ClipboardEvent {
  final List<FileSystemEntity> entities;
  CopyToClipboard(this.entities);
}

class CutToClipboard extends ClipboardEvent {
  final List<FileSystemEntity> entities;
  CutToClipboard(this.entities);
}

class ClearClipboard extends ClipboardEvent {}

class PasteFromClipboard extends ClipboardEvent {
  final String destinationPath;
  PasteFromClipboard(this.destinationPath);
}

/// Moves or copies [sources] into [destination] without the clipboard, as
/// a drag and drop does.
class TransferFiles extends ClipboardEvent {
  final List<String> sources;
  final String destination;
  final bool move;
  TransferFiles(this.sources, this.destination, {required this.move});
}

/// The shared clipboard changed (another window, or another app).
class _ClipboardChanged extends ClipboardEvent {}
