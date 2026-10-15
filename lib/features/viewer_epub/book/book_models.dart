/// Format-neutral model of an e-book, shared by the EPUB, FB2 and MOBI
/// parsers and the reader UI.
///
/// Every class here is plain data so it can cross isolate boundaries.
library;

enum BookFormat { epub, fb2, mobi }

class BookMetadata {
  const BookMetadata({
    required this.title,
    this.authors = const [],
    this.language,
    this.publisher,
    this.description,
    this.identifier,
    this.coverPath,
    this.rtl = false,
    this.fixedLayout = false,
  });

  final String title;
  final List<String> authors;
  final String? language;
  final String? publisher;
  final String? description;
  final String? identifier;

  /// Resource path (inside the book) of the cover image, if known.
  final String? coverPath;

  /// `page-progression-direction="rtl"` (or an RTL language for formats
  /// without that notion).
  final bool rtl;

  /// EPUB `rendition:layout` = `pre-paginated` for the whole book.
  final bool fixedLayout;

  String get authorLine => authors.isEmpty ? '' : authors.join(', ');
}

/// One document in reading order.
class SpineItem {
  const SpineItem({
    required this.path,
    required this.mediaType,
    this.linear = true,
    this.size = 1,
    this.fixedLayout = false,
    this.title,
  });

  /// Decoded resource path inside the book (`OEBPS/Text/ch1.xhtml`).
  final String path;
  final String mediaType;
  final bool linear;

  /// Uncompressed size in bytes, used to weight the overall progress.
  final int size;
  final bool fixedLayout;

  /// Fallback title used when the TOC doesn't name this document.
  final String? title;
}

/// A node of the (possibly nested) table of contents.
class TocEntry {
  TocEntry({
    required this.title,
    this.path,
    this.fragment,
    this.spineIndex,
    List<TocEntry>? children,
  }) : children = children ?? [];

  final String title;

  /// Decoded resource path of the target document.
  final String? path;

  /// Element id inside the document, without `#`.
  final String? fragment;

  /// Index into [BookInfo.spine], or null if the target isn't in the spine.
  int? spineIndex;

  final List<TocEntry> children;
}

/// A [TocEntry] flattened for list display.
class FlatTocEntry {
  const FlatTocEntry(this.entry, this.depth, this.order);

  final TocEntry entry;
  final int depth;

  /// Position in a depth-first walk; stable id for the UI.
  final int order;
}

class BookInfo {
  BookInfo({
    required this.format,
    required this.metadata,
    required this.spine,
    required this.toc,
  });

  final BookFormat format;
  final BookMetadata metadata;
  final List<SpineItem> spine;
  final List<TocEntry> toc;

  List<FlatTocEntry>? _flat;

  List<FlatTocEntry> get flatToc {
    final cached = _flat;
    if (cached != null) return cached;
    final out = <FlatTocEntry>[];
    void walk(List<TocEntry> entries, int depth) {
      for (final e in entries) {
        out.add(FlatTocEntry(e, depth, out.length));
        walk(e.children, depth + 1);
      }
    }

    walk(toc, 0);
    return _flat = out;
  }

  /// Total weight of the spine (sum of sizes, at least 1).
  int get totalSize {
    var total = 0;
    for (final s in spine) {
      total += s.size < 1 ? 1 : s.size;
    }
    return total < 1 ? 1 : total;
  }
}

/// One in-book search result.
class SearchHit {
  const SearchHit({
    required this.spineIndex,
    required this.occurrence,
    required this.before,
    required this.match,
    required this.after,
  });

  final int spineIndex;

  /// Index of this match among all matches in the same document, counted
  /// the same way the reader's JS highlighter counts them.
  final int occurrence;
  final String before;
  final String match;
  final String after;
}

/// A friendly, user-facing failure while opening a book.
class BookOpenException implements Exception {
  const BookOpenException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// Reading position: spine index plus the fraction read within it.
class ReaderPosition {
  const ReaderPosition(this.spine, this.progress);

  final int spine;

  /// 0..1 within the spine document.
  final double progress;

  Map<String, dynamic> toJson() => {
        'v': 2,
        'spine': spine,
        'progress': double.parse(progress.toStringAsFixed(5)),
      };

  /// Parses a saved position. Accepts the current map format and the legacy
  /// plain `int` (index into the top-level TOC chapters of the old reader).
  static ReaderPosition? fromSaved(dynamic raw, BookInfo info) {
    if (info.spine.isEmpty) return null;
    final last = info.spine.length - 1;
    if (raw is Map) {
      final spine = raw['spine'];
      final progress = raw['progress'];
      if (spine is num) {
        final p = progress is num ? progress.toDouble() : 0.0;
        return ReaderPosition(
          spine.toInt().clamp(0, last),
          p.isFinite ? p.clamp(0.0, 1.0) : 0.0,
        );
      }
      return null;
    }
    if (raw is String) {
      final asInt = int.tryParse(raw);
      if (asInt == null) return null;
      raw = asInt;
    }
    if (raw is num) {
      final index = raw.toInt();
      // The old reader used epubx's top-level chapters, which follow the
      // top-level TOC entries.
      if (index >= 0 && index < info.toc.length) {
        final target = info.toc[index].spineIndex;
        if (target != null) return ReaderPosition(target, 0);
      }
      return ReaderPosition(index.clamp(0, last), 0);
    }
    return null;
  }
}
