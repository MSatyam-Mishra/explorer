import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Whether this user may add, rename and remove items in [folder] on macOS,
/// through access(2): false on a read-only volume (the system's, a disk
/// image) or in a folder that isn't theirs, such as /Library or /usr/bin.
/// Null off macOS. Safe to use from any isolate.
bool? macosCanWriteIn(String folder) {
  if (!Platform.isMacOS) return null;
  return using((arena) => _access(folder.toNativeUtf8(allocator: arena), _wOk | _xOk) == 0);
}

// <unistd.h>
const _wOk = 2;
const _xOk = 1;

final _access = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('access');
