import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'book_models.dart';
import 'epub_parser.dart';
import 'fb2_parser.dart';
import 'html_text.dart';
import 'mobi_parser.dart';
import 'text_codec.dart';

/// An opened book: parsed structure plus access to its resources by path.
abstract class BookSource {
  BookInfo get info;

  /// The canonical stored spelling of [path] (case-insensitive lookup), or
  /// null if the book has no such resource.
  String? canonicalPath(String path);

  /// Raw bytes of a resource (fonts already de-obfuscated), or null.
  Future<Uint8List?> readResource(String path);

  /// Every resource path in the book (for diagnostics).
  Iterable<String> get resourcePaths;

  /// Full-text search over the spine documents.
  Future<List<SearchHit>> search(String query, {int maxResults = 500});

  Future<void> dispose();

  /// Opens [file], sniffing the content first and falling back to the
  /// extension. Throws [BookOpenException] with a friendly message.
  static Future<BookSource> open(File file) async {
    if (!await file.exists()) {
      throw const BookOpenException('The file no longer exists.');
    }
    final length = await file.length();
    if (length == 0) {
      throw const BookOpenException('The file is empty.');
    }
    final header = await _readHeader(file, 4096);
    final name = file.path.toLowerCase();

    final isZip = header.length >= 4 &&
        header[0] == 0x50 &&
        header[1] == 0x4B &&
        (header[2] == 0x03 || header[2] == 0x05);
    final palmType = header.length >= 68
        ? String.fromCharCodes(header.sublist(60, 68))
        : '';
    final isPalm = palmType == 'BOOKMOBI' || palmType == 'TEXtREAd';
    final headText = String.fromCharCodes(
      header.where((b) => b != 0).take(2048),
    );
    final isFb2Xml = headText.contains('<FictionBook');

    if (isZip) {
      if (name.endsWith('.fb2.zip') || name.endsWith('.fbz')) {
        return Fb2BookSource.open(file);
      }
      final epub = await EpubBookSource.tryOpen(file);
      if (epub != null) return epub;
      // A ZIP without an OPF: maybe a zipped FB2.
      return Fb2BookSource.open(file);
    }
    if (isPalm) return MobiBookSource.open(file);
    if (isFb2Xml) return Fb2BookSource.open(file);

    if (name.endsWith('.fb2')) return Fb2BookSource.open(file);
    if (RegExp(r'\.(mobi|azw3?|prc|pdb|kf8)$').hasMatch(name)) {
      if (palmType.trim().isEmpty) {
        throw const BookOpenException(
          "This file doesn't look like a MOBI/Kindle book. It may be damaged.",
        );
      }
      throw BookOpenException(
        'This Palm database ("$palmType") is not an e-book format that can '
        'be read here.',
      );
    }
    if (name.endsWith('.epub')) {
      throw const BookOpenException(
        "This EPUB isn't a valid ZIP container. It may be damaged or "
        'incompletely downloaded.',
      );
    }
    throw const BookOpenException(
      "This file isn't a supported e-book (EPUB, FB2, MOBI, AZW3).",
    );
  }

  static Future<Uint8List> _readHeader(File file, int max) async {
    final raf = await file.open();
    try {
      return await raf.read(max);
    } finally {
      await raf.close();
    }
  }
}

/// A book whose resources were generated in memory (FB2, MOBI).
class MemoryBookSource extends BookSource {
  MemoryBookSource({
    required this.info,
    required Map<String, Uint8List> resources,
  })  : _resources = resources,
        _lower = {for (final k in resources.keys) k.toLowerCase(): k};

  @override
  final BookInfo info;
  final Map<String, Uint8List> _resources;
  final Map<String, String> _lower;

  @override
  String? canonicalPath(String path) =>
      _resources.containsKey(path) ? path : _lower[path.toLowerCase()];

  @override
  Future<Uint8List?> readResource(String path) async {
    final key = canonicalPath(path);
    return key == null ? null : _resources[key];
  }

  @override
  Iterable<String> get resourcePaths => _resources.keys;

  @override
  Future<List<SearchHit>> search(String query, {int maxResults = 500}) =>
      _searchInBackground(
        [for (final s in info.spine) _resources[s.path]],
        query,
        maxResults,
      );

  static Future<List<SearchHit>> _searchInBackground(
    List<Uint8List?> docs,
    String query,
    int maxResults,
  ) =>
      Isolate.run(() => searchMarkupDocuments(docs, query, maxResults));

  @override
  Future<void> dispose() async => _resources.clear();
}

/// Searches already-loaded documents (index = spine index).
List<SearchHit> searchMarkupDocuments(
  List<Uint8List?> docs,
  String query,
  int maxResults,
) {
  final hits = <SearchHit>[];
  for (var i = 0; i < docs.length && hits.length < maxResults; i++) {
    final bytes = docs[i];
    if (bytes == null) continue;
    hits.addAll(HtmlText.searchDocument(
      TextCodec.decodeMarkup(bytes),
      query,
      i,
      maxHits: maxResults - hits.length,
    ));
  }
  return hits;
}
