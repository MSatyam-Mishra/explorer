import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Replaces the contents of [target] with [bytes] without ever leaving the
/// original truncated or half-written.
///
/// The bytes go to a hidden temporary file in the same folder, which is
/// flushed and then renamed over [target] (rename replaces atomically on
/// POSIX and, via MoveFileEx, on Windows). If that write fails — e.g. the
/// disk is full — the error is rethrown and [target] is untouched.
///
/// Falls back to writing [target] in place only when the folder doesn't let
/// us create the temporary file or rename it (some removable or
/// provider-backed storage); that is no worse than a plain write.
///
/// Symbolic links are resolved first so the link itself is kept. A renamed
/// file is a new inode: POSIX permission bits and hard links of the old file
/// are not carried over.
Future<void> writeFileAtomically(File target, List<int> bytes) async {
  var path = target.path;
  try {
    if (await FileSystemEntity.isLink(path)) {
      path = await target.resolveSymbolicLinks();
    }
  } catch (_) {
    // Keep the original path.
  }
  final tmp = File(
    p.join(p.dirname(path), '.${p.basename(path)}.${_randomTag()}.tmp'),
  );

  try {
    await tmp.create(exclusive: true);
  } catch (_) {
    // No permission to create files here: plain write is all we can do.
    await File(path).writeAsBytes(bytes, flush: true);
    return;
  }

  try {
    await tmp.writeAsBytes(bytes, flush: true);
  } catch (_) {
    await _deleteQuietly(tmp);
    rethrow; // The original is still intact.
  }

  try {
    await tmp.rename(path);
  } catch (_) {
    // e.g. the target is open without delete sharing on Windows. Free the
    // temp file's space first, then write in place.
    await _deleteQuietly(tmp);
    await File(path).writeAsBytes(bytes, flush: true);
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

String _randomTag() =>
    '$pid-${Random().nextInt(0x7FFFFFFF).toRadixString(36)}';
