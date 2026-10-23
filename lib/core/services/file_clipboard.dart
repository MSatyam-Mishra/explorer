import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

/// Files on the clipboard, copied or cut.
@immutable
class ClipboardFiles {
  const ClipboardFiles(this.paths, {required this.cut});

  final List<String> paths;
  final bool cut;

  @override
  bool operator ==(Object other) =>
      other is ClipboardFiles && other.cut == cut && listEquals(other.paths, paths);

  @override
  int get hashCode => Object.hash(cut, Object.hashAll(paths));
}

/// The clipboard every Explorer window shares, so files copied or cut in
/// one window paste in another. On Windows it's the system clipboard: files
/// also copy and paste to and from File Explorer and other apps. Linux and
/// macOS use a small file in the app's data folder; phones have one window.
abstract class FileClipboard {
  static FileClipboard? _instance;

  static FileClipboard get instance => _instance ??= _forPlatform();

  @visibleForTesting
  static set instance(FileClipboard value) => _instance = value;

  static FileClipboard _forPlatform() {
    // Tests don't touch the computer's clipboard.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return MemoryFileClipboard();
    if (Platform.isWindows) return WindowsFileClipboard();
    if (Platform.isLinux || Platform.isMacOS) {
      return SharedFileClipboard(
        getApplicationSupportDirectory().then((d) => p.join(d.path, 'clipboard.json')),
      );
    }
    return MemoryFileClipboard();
  }

  /// What's on the clipboard; null when it holds no files.
  Future<ClipboardFiles?> read();

  Future<void> write(ClipboardFiles files);

  Future<void> clear();

  /// Fires when the clipboard may have changed (in this window or another).
  Stream<void> get changes;
}

/// Checks something every [interval] while anyone listens to [changes].
abstract class _PolledClipboard extends FileClipboard {
  _PolledClipboard(this.interval);

  final Duration interval;
  Timer? _timer;
  late final _changes = StreamController<void>.broadcast(
    onListen: () => _timer = Timer.periodic(interval, (_) => _poll()),
    onCancel: () => _timer?.cancel(),
  );
  Object? _last;

  /// Something that changes with the clipboard's content.
  Future<Object?> stamp();

  Future<void> _poll() async {
    final now = await stamp();
    if (now == _last) return;
    _last = now;
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;
}

/// The Windows clipboard, in the format File Explorer uses: a file list
/// (CF_HDROP) and whether it's a copy or a move ("Preferred DropEffect").
class WindowsFileClipboard extends _PolledClipboard {
  WindowsFileClipboard() : super(const Duration(milliseconds: 600));

  static const _copy = 5; // DROPEFFECT_COPY | DROPEFFECT_LINK, as Explorer sets.
  static const _move = 2; // DROPEFFECT_MOVE

  static final int _dropEffect = using(
    (arena) => RegisterClipboardFormat('Preferred DropEffect'.toNativeUtf16(allocator: arena)),
  );

  @override
  Future<Object?> stamp() async => GetClipboardSequenceNumber();

  @override
  Future<ClipboardFiles?> read() async {
    if (IsClipboardFormatAvailable(CF_HDROP) == 0) return null;
    if (!await _open()) return null;
    try {
      final drop = GetClipboardData(CF_HDROP);
      if (drop == 0) return null;
      final paths = <String>[];
      final count = DragQueryFile(drop, 0xFFFFFFFF, nullptr, 0);
      for (var i = 0; i < count; i++) {
        final length = DragQueryFile(drop, i, nullptr, 0);
        final buffer = wsalloc(length + 1);
        try {
          DragQueryFile(drop, i, buffer, length + 1);
          paths.add(buffer.toDartString());
        } finally {
          free(buffer);
        }
      }
      var cut = false;
      final effect = GetClipboardData(_dropEffect);
      if (effect != 0) {
        final handle = Pointer<Void>.fromAddress(effect);
        final data = GlobalLock(handle);
        if (data != nullptr) {
          cut = data.cast<Uint32>().value & _move != 0;
          GlobalUnlock(handle);
        }
      }
      return paths.isEmpty ? null : ClipboardFiles(paths, cut: cut);
    } finally {
      CloseClipboard();
    }
  }

  @override
  Future<void> write(ClipboardFiles files) async {
    final drop = _global(dropFilesBytes(files.paths));
    final effect = _global(Uint8List(4)..buffer.asByteData().setUint32(0, files.cut ? _move : _copy, Endian.little));
    if (!await _open()) {
      GlobalFree(drop);
      GlobalFree(effect);
      throw const FileSystemException("Couldn't open the clipboard");
    }
    try {
      EmptyClipboard();
      // The clipboard owns the memory once it's set.
      if (SetClipboardData(CF_HDROP, drop.address) == 0) GlobalFree(drop);
      if (SetClipboardData(_dropEffect, effect.address) == 0) GlobalFree(effect);
    } finally {
      CloseClipboard();
    }
    _last = GetClipboardSequenceNumber();
  }

  @override
  Future<void> clear() async {
    if (IsClipboardFormatAvailable(CF_HDROP) == 0) return;
    if (!await _open()) return;
    try {
      EmptyClipboard();
    } finally {
      CloseClipboard();
    }
  }

  /// A DROPFILES header and the paths, UTF-16, each ending in a null and
  /// the list in another.
  @visibleForTesting
  static Uint8List dropFilesBytes(List<String> paths) {
    const header = 20;
    final units = [
      for (final path in paths) ...[...path.codeUnits, 0],
      0,
      if (paths.isEmpty) 0,
    ];
    final bytes = Uint8List(header + units.length * 2);
    final data = bytes.buffer.asByteData()
      ..setUint32(0, header, Endian.little) // pFiles: where the paths start
      ..setUint32(16, 1, Endian.little); // fWide: UTF-16
    for (var i = 0; i < units.length; i++) {
      data.setUint16(header + i * 2, units[i], Endian.little);
    }
    return bytes;
  }

  static Pointer _global(Uint8List bytes) {
    final handle = GlobalAlloc(GHND, bytes.length);
    final data = GlobalLock(handle).cast<Uint8>();
    data.asTypedList(bytes.length).setAll(0, bytes);
    GlobalUnlock(handle);
    return handle;
  }

  /// Opens the clipboard for one of this app's windows; another app may
  /// hold it for a moment.
  static Future<bool> _open() async {
    final window = _ownWindow();
    for (var attempt = 0; attempt < 10; attempt++) {
      if (OpenClipboard(window) != 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    return false;
  }

  static int _ownWindow() {
    final pid = GetCurrentProcessId();
    return using((arena) {
      final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
      final owner = arena<Uint32>();
      var window = 0;
      while ((window = FindWindowEx(0, window, className, nullptr)) != 0) {
        GetWindowThreadProcessId(window, owner);
        if (owner.value == pid) return window;
      }
      return 0;
    });
  }
}

/// A JSON file all windows read and write (Linux, macOS).
class SharedFileClipboard extends _PolledClipboard {
  SharedFileClipboard(this._path) : super(const Duration(milliseconds: 700));

  final Future<String> _path;

  @override
  Future<Object?> stamp() async {
    try {
      return (await File(await _path).stat()).modified;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ClipboardFiles?> read() async {
    try {
      final json = jsonDecode(await File(await _path).readAsString()) as Map;
      final paths = (json['paths'] as List).cast<String>();
      return paths.isEmpty ? null : ClipboardFiles(paths, cut: json['cut'] == true);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(ClipboardFiles files) async {
    final path = await _path;
    await Directory(p.dirname(path)).create(recursive: true);
    // Written next to it and renamed, so no window reads half a file.
    final temp = File('$path.$pid.tmp');
    await temp.writeAsString(jsonEncode({'paths': files.paths, 'cut': files.cut}));
    await temp.rename(path);
  }

  @override
  Future<void> clear() async {
    try {
      await File(await _path).delete();
    } on FileSystemException {
      // Already empty.
    }
  }
}

/// One window (phones): nothing to share.
class MemoryFileClipboard extends FileClipboard {
  ClipboardFiles? _files;
  final _changes = StreamController<void>.broadcast();

  @override
  Future<ClipboardFiles?> read() async => _files;

  @override
  Future<void> write(ClipboardFiles files) async {
    _files = files;
    _changes.add(null);
  }

  @override
  Future<void> clear() async {
    _files = null;
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;
}
