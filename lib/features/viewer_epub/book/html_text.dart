import 'dart:math' as math;

import 'package:xml/xml.dart';

import 'book_models.dart';

/// Markup/text helpers shared by the parsers and the in-book search.
abstract final class HtmlText {
  static const XmlEntityMapping _entities = XmlDefaultEntityMapping.html5();

  static String decodeEntities(String s) =>
      s.contains('&') ? _entities.decode(s) : s;

  static String escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static final _bodyOpen = RegExp(r'<body\b[^>]*>', caseSensitive: false);
  static final _headClose = RegExp(r'</head\s*>', caseSensitive: false);
  static final _comment = RegExp(r'<!--[\s\S]*?-->');
  static final _cdata = RegExp(r'<!\[CDATA\[[\s\S]*?\]\]>');
  static final _scriptStyle = RegExp(
    r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
    caseSensitive: false,
  );
  static final _selfClosingScript =
      RegExp(r'<(script|style)\b[^>]*/>', caseSensitive: false);
  static final _tag = RegExp(r'<[^>]*>');

  static final _blockTag = RegExp(
    r'</?(p|div|h[1-6]|li|ul|ol|dl|dt|dd|br|hr|tr|td|th|table|section|'
    r'article|aside|header|footer|blockquote|pre|figure|figcaption|nav)\b[^>]*>',
    caseSensitive: false,
  );

  /// Marks block boundaries in [bodyText] output (for snippets only); the
  /// marker is skipped when matching, so indices follow the DOM text.
  static const blockMarker = '\uE000';

  /// The body's text as the browser exposes it through its text nodes
  /// (script/style excluded, entities decoded, tags removed without adding
  /// separators). Must stay in sync with the reader JS' text walker. With
  /// [markBlocks], block-level tags become [blockMarker] instead.
  static String bodyText(String markup, {bool markBlocks = false}) {
    var s = markup;
    final open = _bodyOpen.firstMatch(s);
    if (open != null) {
      s = s.substring(open.end);
    } else {
      final head = _headClose.firstMatch(s);
      if (head != null) s = s.substring(head.end);
    }
    final close = s.toLowerCase().lastIndexOf('</body');
    if (close >= 0) s = s.substring(0, close);
    s = s
        .replaceAll(blockMarker, '')
        .replaceAll(_comment, '')
        .replaceAll(_cdata, '')
        .replaceAll(_selfClosingScript, '')
        .replaceAll(_scriptStyle, '');
    if (markBlocks) s = s.replaceAll(_blockTag, blockMarker);
    return decodeEntities(s.replaceAll(_tag, ''));
  }

  /// Plain text with collapsed whitespace, for titles and labels.
  static String plain(String markup) => collapse(
        decodeEntities(markup.replaceAll(_tag, ' ')),
      );

  static String collapse(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _isSpace(int c) =>
      c == 0x20 ||
      (c >= 0x09 && c <= 0x0D) ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 ||
      c == 0xFEFF;

  static int _lowerUnit(int c) {
    if (c >= 0x41 && c <= 0x5A) return c + 32;
    if (c < 0x80) return c;
    final lower = String.fromCharCode(c).toLowerCase();
    return lower.length == 1 ? lower.codeUnitAt(0) : c;
  }

  /// Lower-cases [text] char by char (keeping length) and collapses runs of
  /// whitespace to one space; [blockMarker]s are skipped. Mirrors
  /// `normalize()` in the reader JS. When [map] is given it receives, for
  /// every output char, its index in [text].
  static String normalizeForSearch(String text, [List<int>? map]) {
    final out = StringBuffer();
    final marker = blockMarker.codeUnitAt(0);
    var prevSpace = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == marker) continue;
      if (_isSpace(c)) {
        if (prevSpace) continue;
        prevSpace = true;
        out.writeCharCode(0x20);
        map?.add(i);
        continue;
      }
      prevSpace = false;
      out.writeCharCode(_lowerUnit(c));
      map?.add(i);
    }
    return out.toString();
  }

  static String _display(String marked, int start, int end) {
    final s = math.max(0, math.min(start, marked.length));
    final e = math.max(s, math.min(end, marked.length));
    return marked
        .substring(s, e)
        .replaceAll(blockMarker, ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Finds [query] in one document's markup.
  static List<SearchHit> searchDocument(
    String markup,
    String query,
    int spineIndex, {
    int maxHits = 300,
  }) {
    final q = normalizeForSearch(query.trim());
    if (q.isEmpty) return const [];
    final marked = bodyText(markup, markBlocks: true);
    final map = <int>[];
    final lower = normalizeForSearch(marked, map);
    final hits = <SearchHit>[];
    var from = 0;
    var occurrence = 0;
    while (hits.length < maxHits) {
      final idx = lower.indexOf(q, from);
      if (idx < 0) break;
      final start = map[idx];
      final end = map[idx + q.length - 1] + 1;
      hits.add(SearchHit(
        spineIndex: spineIndex,
        occurrence: occurrence,
        before: _trimStart(_display(marked, start - 80, start)),
        match: _display(marked, start, end),
        after: _trimEnd(_display(marked, end, end + 100)),
      ));
      occurrence++;
      from = idx + 1;
    }
    return hits;
  }

  static String _trimStart(String s) {
    if (s.length < 70) return s.trimLeft();
    final space = s.indexOf(' ');
    return space >= 0 && space < 20 ? '…${s.substring(space + 1)}' : '…$s';
  }

  static String _trimEnd(String s) {
    if (s.length < 90) return s.trimRight();
    final space = s.lastIndexOf(' ');
    return space > 50 ? '${s.substring(0, space)}…' : '$s…';
  }

  /// First `<title>` / heading text of a document, for spine fallbacks.
  static String? guessTitle(String markup) {
    for (final pattern in [
      RegExp(r'<h([1-3])\b[^>]*>([\s\S]*?)</h\1\s*>', caseSensitive: false),
      RegExp(r'<title\b[^>]*>([\s\S]*?)</title\s*>', caseSensitive: false),
    ]) {
      final m = pattern.firstMatch(markup);
      if (m == null) continue;
      final text = plain(m.group(m.groupCount)!);
      if (text.isNotEmpty && text.length < 160) return text;
    }
    return null;
  }
}

/// Path helpers for resources inside a book (always `/`-separated, decoded,
/// relative to the container root).
abstract final class BookPaths {
  static String dirname(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  static String basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  static String extension(String path) {
    final name = basename(path);
    final i = name.lastIndexOf('.');
    return i <= 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static String safeDecode(String s) {
    if (!s.contains('%')) return s;
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  /// Splits `a/b.xhtml#frag` into the path part and decoded fragment.
  static (String, String?) splitHref(String href) {
    final hash = href.indexOf('#');
    var path = hash < 0 ? href : href.substring(0, hash);
    final frag = hash < 0 ? null : safeDecode(href.substring(hash + 1));
    final q = path.indexOf('?');
    if (q >= 0) path = path.substring(0, q);
    return (path, (frag == null || frag.isEmpty) ? null : frag);
  }

  static bool isExternal(String href) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(href);

  /// Resolves [href] (URL-encoded, relative to [baseDir]) to a normalized
  /// decoded path. Returns null for external URLs.
  static String? resolve(String baseDir, String href) {
    final (raw, _) = splitHref(href.trim());
    if (isExternal(raw)) return null;
    final decoded = safeDecode(raw);
    final joined = decoded.startsWith('/')
        ? decoded.substring(1)
        : (baseDir.isEmpty ? decoded : '$baseDir/$decoded');
    return normalize(joined);
  }

  static String normalize(String path) {
    final out = <String>[];
    for (final seg in path.replaceAll('\\', '/').split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(seg);
    }
    return out.join('/');
  }

  /// URL-encodes each segment of a decoded path.
  static String encode(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');
}
