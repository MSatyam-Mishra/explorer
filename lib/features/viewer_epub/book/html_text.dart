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

  /// The body's text as the browser exposes it through its text nodes
  /// (script/style excluded, entities decoded, tags removed without adding
  /// separators). Must stay in sync with the reader JS' text walker.
  static String bodyText(String markup) {
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
        .replaceAll(_comment, '')
        .replaceAll(_cdata, '')
        .replaceAll(_selfClosingScript, '')
        .replaceAll(_scriptStyle, '')
        .replaceAll(_tag, '');
    return decodeEntities(s);
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

  /// Lower-cases [text] char by char (keeping length) and collapses runs of
  /// whitespace to one space. Mirrors `normalize()` in the reader JS.
  static String normalizeForSearch(String text) {
    final out = StringBuffer();
    var prevSpace = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (_isSpace(c)) {
        if (prevSpace) continue;
        prevSpace = true;
        out.writeCharCode(0x20);
        continue;
      }
      prevSpace = false;
      if (c >= 0x41 && c <= 0x5A) {
        out.writeCharCode(c + 32);
      } else if (c < 0x80) {
        out.writeCharCode(c);
      } else {
        final ch = String.fromCharCode(c);
        final lower = ch.toLowerCase();
        out.write(lower.length == 1 ? lower : ch);
      }
    }
    return out.toString();
  }

  /// Same as [normalizeForSearch] but keeps the original case (for
  /// snippets), so indices line up.
  static String collapseKeepCase(String text) {
    final out = StringBuffer();
    var prevSpace = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (_isSpace(c)) {
        if (prevSpace) continue;
        prevSpace = true;
        out.writeCharCode(0x20);
        continue;
      }
      prevSpace = false;
      out.writeCharCode(c);
    }
    return out.toString();
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
    final raw = bodyText(markup);
    final lower = normalizeForSearch(raw);
    final display = collapseKeepCase(raw);
    final hits = <SearchHit>[];
    var from = 0;
    var occurrence = 0;
    while (hits.length < maxHits) {
      final idx = lower.indexOf(q, from);
      if (idx < 0) break;
      final end = idx + q.length;
      hits.add(SearchHit(
        spineIndex: spineIndex,
        occurrence: occurrence,
        before: _trimStart(display.substring(math.max(0, idx - 70), idx)),
        match: display.substring(idx, math.min(display.length, end)),
        after: _trimEnd(
          display.substring(math.min(display.length, end),
              math.min(display.length, end + 90)),
        ),
      ));
      occurrence++;
      from = idx + 1;
    }
    return hits;
  }

  static String _trimStart(String s) {
    final space = s.indexOf(' ');
    if (s.length >= 70 && space >= 0 && space < 20) {
      return '…${s.substring(space + 1)}';
    }
    return s.trimLeft();
  }

  static String _trimEnd(String s) {
    final space = s.lastIndexOf(' ');
    if (s.length >= 90 && space > 60) return '${s.substring(0, space)}…';
    return s.trimRight();
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
