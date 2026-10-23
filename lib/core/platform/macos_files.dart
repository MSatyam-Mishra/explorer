import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// File details macOS keeps outside what dart:io reports, read through
/// libSystem: the volume a path is on, Finder's hidden flag, and copying a
/// file's permissions, extended attributes and ACLs. Every call returns
/// null or false off macOS, so callers need no platform check of their own.
/// Safe to use from any isolate.
abstract final class MacosFiles {
  static final bool _supported = Platform.isMacOS;

  /// The device id (st_dev) of the volume [path] is on, without following
  /// a final symlink; null if it can't be read.
  static int? volumeOf(String path) => _stat(path)?.dev;

  /// Whether [a] and [b] are on the same volume; null if either can't be
  /// read.
  static bool? sameVolume(String a, String b) {
    final da = volumeOf(a), db = volumeOf(b);
    if (da == null || db == null) return null;
    return da == db;
  }

  /// Whether Finder hides [path] (the UF_HIDDEN flag, as on ~/Library,
  /// /usr or /bin). Dot-files are not covered; check those by name.
  static bool isHidden(String path) {
    final flags = _stat(path)?.flags;
    return flags != null && flags & _ufHidden != 0;
  }

  /// Copies [source]'s permissions, extended attributes (Finder tags,
  /// quarantine, resource forks) and ACLs onto [target], as Finder does
  /// after a copy. Works for files and folders. Returns false on failure.
  static bool copyMetadata(String source, String target) {
    if (!_supported) return false;
    return using((arena) {
      final from = source.toNativeUtf8(allocator: arena);
      final to = target.toNativeUtf8(allocator: arena);
      return _copyfile(from, to, nullptr, _copyfileMetadata) == 0;
    });
  }

  // <sys/stat.h> struct stat (64-bit inodes): 144 bytes on arm64 and
  // x86_64, st_dev (int32) at 0 and st_flags (uint32) at 116.
  static const _statSize = 144;
  static const _devOffset = 0;
  static const _flagsOffset = 116;
  static const _ufHidden = 0x8000;
  // COPYFILE_SECURITY | COPYFILE_XATTR (mode, owner, ACLs and xattrs).
  static const _copyfileMetadata = 0x7;

  static ({int dev, int flags})? _stat(String path) {
    if (!_supported) return null;
    return using((arena) {
      final buf = arena<Uint8>(_statSize);
      if (_lstat(path.toNativeUtf8(allocator: arena), buf) != 0) return null;
      final data = buf.cast<Uint8>();
      return (
        dev: (data + _devOffset).cast<Int32>().value,
        flags: (data + _flagsOffset).cast<Uint32>().value,
      );
    });
  }

  static final _lib = DynamicLibrary.process();

  // Intel Macs export the 64-bit-inode lstat under its $INODE64 name.
  static final _lstat = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
      int Function(Pointer<Utf8>, Pointer<Uint8>)>(
    Abi.current() == Abi.macosX64 ? r'lstat$INODE64' : 'lstat',
  );

  static final _copyfile = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, Uint32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, int)>(
    'copyfile',
  );
}
