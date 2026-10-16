/// Page selection for comic archives (CBZ/CBR/CB7/CBT).
library;

import 'archive_backend.dart';

const _imageExtensions = {
  'jpg', 'jpeg', 'jfif', 'png', 'gif', 'webp', 'bmp', 'avif', 'heic', 'heif',
};

const _junkNames = {'thumbs.db', '.ds_store', 'desktop.ini'};

/// Image entries of a comic archive in reading order: natural sort by path
/// (`page2` before `page10`), without macOS resource forks (`__MACOSX/`,
/// `._*`), hidden files or thumbnail databases.
List<ArcEntry> comicPages(List<ArcEntry> entries) {
  final pages = <ArcEntry>[];
  for (final e in entries) {
    if (e.isDirectory || e.isSymlink || e.size == 0) continue;
    final segments = e.path.split('/');
    if (segments.any(
      (s) => s == '__MACOSX' || (s.startsWith('.') && s.length > 1),
    )) {
      continue;
    }
    final name = segments.last.toLowerCase();
    if (_junkNames.contains(name) || name.startsWith('._')) continue;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || !_imageExtensions.contains(name.substring(dot + 1))) {
      continue;
    }
    pages.add(e);
  }
  pages.sort((a, b) => naturalCompare(a.path, b.path));
  return pages;
}
