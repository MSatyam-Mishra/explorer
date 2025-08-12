part of 'clipboard_bloc.dart';

@immutable
abstract class ClipboardEvent {}

class CopyToClipboard extends ClipboardEvent {
  final FileSystemEntity entity;
  CopyToClipboard(this.entity);
}

class CutToClipboard extends ClipboardEvent {
  final FileSystemEntity entity;
  CutToClipboard(this.entity);
}

class ClearClipboard extends ClipboardEvent {}

class PasteFromClipboard extends ClipboardEvent {
  final String destinationPath;
  PasteFromClipboard(this.destinationPath);
}