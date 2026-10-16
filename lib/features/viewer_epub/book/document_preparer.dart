import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart' show XmlDefaultEntityMapping;

import 'book_models.dart';
import 'html_text.dart';
import 'text_codec.dart';

/// Input for [prepareDocument]; plain data so it can be sent to an isolate.
class DocumentPrepareRequest {
  const DocumentPrepareRequest({
    required this.bytes,
    required this.path,
    required this.mediaType,
    required this.readerCss,
    required this.readerJs,
    this.fixedLayout = false,
    this.forceHtml = false,
  });

  final Uint8List bytes;

  /// Decoded resource path of the document inside the book.
  final String path;
  final String mediaType;

  /// Reader stylesheet and script, inlined into the document's head so the
  /// page needs no extra round trips before it can lay out.
  final String readerCss;
  final String readerJs;
  final bool fixedLayout;

  /// Skip the XHTML attempt (used after XHTML rendering failed).
  final bool forceHtml;

  DocumentPrepareRequest withBytes(Uint8List bytes) => DocumentPrepareRequest(
        bytes: bytes,
        path: path,
        mediaType: mediaType,
        readerCss: readerCss,
        readerJs: readerJs,
        fixedLayout: fixedLayout,
        forceHtml: forceHtml,
      );
}

/// A spine document ready to serve: UTF-8 markup with the reader injected,
/// split where the per-load config JSON goes.
class PreparedDocument {
  const PreparedDocument({
    required this.xhtml,
    required this.head,
    required this.tail,
  });

  /// True to serve as `application/xhtml+xml`, false for `text/html`.
  final bool xhtml;

  /// Markup before the reader config.
  final Uint8List head;

  /// Markup after the reader config.
  final Uint8List tail;

  /// The document with [configJson] (a JS expression) in place.
  Uint8List withConfig(String configJson) {
    final config = utf8.encode(configJson);
    final out = Uint8List(head.length + config.length + tail.length);
    out.setRange(0, head.length, head);
    out.setRange(head.length, head.length + config.length, config);
    out.setRange(head.length + config.length, out.length, tail);
    return out;
  }
}

const _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', //
  'meta', 'param', 'source', 'track', 'wbr', 'basefont', 'frame', 'keygen',
};

const _xmlEntities = {'lt', 'gt', 'amp', 'quot', 'apos'};
const _xhtmlNs = 'http://www.w3.org/1999/xhtml';

const _knownNamespaces = {
  'epub': 'http://www.idpf.org/2007/ops',
  'xlink': 'http://www.w3.org/1999/xlink',
  'svg': 'http://www.w3.org/2000/svg',
  'm': 'http://www.w3.org/1998/Math/MathML',
  'mml': 'http://www.w3.org/1998/Math/MathML',
  'math': 'http://www.w3.org/1998/Math/MathML',
  'ibooks': 'http://vocabulary.itunes.apple.com/rdf/ibooks/vocabulary-extensions-1.0',
  'ssml': 'http://www.w3.org/2001/10/synthesis',
  'xsi': 'http://www.w3.org/2001/XMLSchema-instance',
};

/// Turns a spine document into something the reader WebView can render:
/// decides XHTML vs HTML parsing, repairs the most common XHTML errors, and
/// injects the reader viewport, stylesheet, config and script.
///
/// Pure function (runs in an isolate for larger documents).
PreparedDocument prepareDocument(DocumentPrepareRequest r) {
  final ext = BookPaths.extension(r.path);
  final mt = r.mediaType.toLowerCase();
  const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'avif'};
  if (mt.startsWith('image/') || (mt.isEmpty && imageExts.contains(ext))) {
    return _imageDocument(r);
  }

  final text = TextCodec.decodeMarkup(r.bytes);
  if (_looksBinary(text)) {
    throw const BookOpenException(
      'This chapter appears to be encrypted (DRM) or damaged and cannot be '
      'displayed.',
    );
  }
  if (mt == 'text/plain' || ext == 'txt') {
    return _inject(
      '<!DOCTYPE html><html><head></head><body><pre>'
      '${HtmlText.escape(text)}</pre></body></html>',
      r,
    );
  }

  final wantXhtml = !r.forceHtml &&
      (mt.contains('xhtml') ||
          mt.contains('xml') ||
          ext == 'xhtml' ||
          ext == 'xht' ||
          ext == 'xml');
  if (wantXhtml) {
    final x = _tryXhtml(text, r);
    if (x != null) return x;
  }
  return _htmlDocument(text, r);
}

bool _looksBinary(String text) {
  final sample = text.length > 4000 ? text.substring(0, 4000) : text;
  if (sample.isEmpty) return false;
  var bad = 0;
  for (var i = 0; i < sample.length; i++) {
    final c = sample.codeUnitAt(i);
    if (c == 0xFFFD || c < 0x09 || (c > 0x0D && c < 0x20)) bad++;
  }
  return bad > sample.length * 0.08;
}

PreparedDocument _imageDocument(DocumentPrepareRequest r) {
  final src = HtmlText.escape(Uri.encodeComponent(BookPaths.basename(r.path)));
  return _inject(
    '<!DOCTYPE html><html><head></head><body class="er-image-doc">'
    '<div class="er-image-page"><img src="$src" alt=""/></div>'
    '</body></html>',
    r,
  );
}

// ------------------------------------------------------------- assembly

/// A replacement of `[start, end)` (an insertion when equal) in the source.
class _Edit {
  _Edit(this.start, this.end, this.text, this.seq, {this.configBefore = false});

  final int start;
  final int end;
  final String text;
  final int seq;

  /// The reader config goes right before [text].
  final bool configBefore;
}

class _Edits {
  final list = <_Edit>[];

  void add(int start, int end, String text, {bool configBefore = false}) =>
      list.add(_Edit(start, end, text, list.length, configBefore: configBefore));

  /// Inserts the viewport (unless fixed layout), stylesheet and script at
  /// [at], or with [wrap] as a whole `<head>` element.
  void head(int at, DocumentPrepareRequest r, {bool wrap = false}) {
    final open = wrap ? '<head>' : '';
    if (!r.fixedLayout) {
      add(
        at,
        at,
        '$open<meta name="viewport" content="width=device-width, '
        'initial-scale=1, maximum-scale=1, user-scalable=no"/>',
      );
    } else if (wrap) {
      add(at, at, open);
    }
    tail(at, r);
    if (wrap) add(at, at, '</head>');
  }

  /// The stylesheet and the config + script (inline, in CDATA so they are
  /// valid in both XHTML and HTML).
  void tail(int at, DocumentPrepareRequest r) {
    add(
      at,
      at,
      '<style type="text/css">/*<![CDATA[*/\n${r.readerCss}\n/*]]>*/</style>'
      '<script type="text/javascript">//<![CDATA[\n'
      'window.__ER_CONFIG__ = ',
    );
    add(at, at, ';\n${r.readerJs}\n//]]></script>', configBefore: true);
  }

  PreparedDocument build(String source, int from, {required bool xhtml}) {
    // By position; at the same position insertions go first (e.g. our
    // viewport right after <head>, before the removal of the book's own
    // viewport <meta> that follows it), then in the order added.
    list.sort((a, b) {
      if (a.start != b.start) return a.start - b.start;
      final ai = a.start == a.end, bi = b.start == b.end;
      if (ai != bi) return ai ? -1 : 1;
      return a.seq - b.seq;
    });
    final sb = StringBuffer();
    var cursor = from;
    var split = -1;
    for (final e in list) {
      if (e.start < cursor) continue; // overlapped by an earlier edit
      if (e.start > cursor) sb.write(source.substring(cursor, e.start));
      if (e.configBefore) split = sb.length;
      sb.write(e.text);
      cursor = e.end;
    }
    if (cursor < source.length) sb.write(source.substring(cursor));
    final out = sb.toString();
    if (split < 0) split = out.length;
    return PreparedDocument(
      xhtml: xhtml,
      head: utf8.encode(out.substring(0, split)),
      tail: utf8.encode(out.substring(split)),
    );
  }
}

// ---------------------------------------------------------------- XHTML

/// Serves [text] as XHTML if it is well-formed after the usual repairs
/// (HTML named entities, undeclared namespace prefixes, missing XHTML
/// namespace); null means "use the HTML parser instead".
PreparedDocument? _tryXhtml(String text, DocumentPrepareRequest r) {
  final scan = _XhtmlScanner(text);
  if (!scan.scan()) return null;
  final defaultNs = scan.rootDefaultNs;
  if (scan.rootName != 'html' || scan.rootSelfClosing) return null;
  if (defaultNs != null && defaultNs != _xhtmlNs) return null;

  final edits = _Edits();
  // Undeclared HTML entities (&nbsp; ...) are fatal in XML: make them
  // numeric (the scanner skips this when the DOCTYPE declares entities).
  const mapping = XmlDefaultEntityMapping.html5();
  for (var i = 0; i < scan.entities.length; i += 2) {
    final start = scan.entities[i];
    final end = scan.entities[i + 1];
    final name = text.substring(start + 1, end - 1);
    final value = mapping.decodeEntity(name);
    edits.add(
      start,
      end,
      value == null ? '&amp;$name;' : value.runes.map((c) => '&#$c;').join(),
    );
  }

  // Declare the XHTML namespace and any prefixes used but never declared.
  final extra = StringBuffer();
  if (defaultNs == null) extra.write(' xmlns="$_xhtmlNs"');
  final undeclared = scan.usedPrefixes.difference(scan.declaredPrefixes)
    ..removeAll(const ['xml', 'xmlns']);
  for (final p in undeclared) {
    extra.write(' xmlns:$p="${_knownNamespaces[p] ?? 'urn:x-unknown:$p'}"');
  }
  if (extra.isNotEmpty) {
    edits.add(scan.rootEnd - 1, scan.rootEnd - 1, extra.toString());
  }

  if (!r.fixedLayout) {
    for (var i = 0; i < scan.viewports.length; i += 2) {
      edits.add(scan.viewports[i], scan.viewports[i + 1], '');
    }
  }

  if (scan.headStart < 0) {
    edits.head(scan.rootEnd, r, wrap: true);
  } else if (scan.headSelfClosing) {
    // <head .../> -> <head ...>[injected]</head>
    final slash = scan.headEnd - 2;
    edits.add(slash, slash + 1, '>');
    edits.head(slash + 1, r);
    edits.add(slash + 1, slash + 1, '</head');
  } else {
    if (!r.fixedLayout) {
      edits.add(
        scan.headEnd,
        scan.headEnd,
        '<meta name="viewport" content="width=device-width, '
        'initial-scale=1, maximum-scale=1, user-scalable=no"/>',
      );
    }
    edits.tail(scan.headClose, r);
  }
  return edits.build(text, scan.prologEnd, xhtml: true);
}

/// One pass over a document that checks XML well-formedness the way the
/// browser's XML parser would (so we only serve XHTML that will render) and
/// collects what the repairs and the reader injection need.
///
/// It errs on the side of "not well-formed": a false alarm only means the
/// forgiving HTML parser is used instead.
class _XhtmlScanner {
  _XhtmlScanner(this.s) : n = s.length;

  final String s;
  final int n;

  /// End of a leading XML declaration (dropped: we always serve UTF-8).
  int prologEnd = 0;
  bool internalSubset = false;

  String? rootName;
  String? rootDefaultNs;
  int rootEnd = -1;
  bool rootSelfClosing = false;

  int headStart = -1;
  int headEnd = -1;
  int headClose = -1;
  bool headSelfClosing = false;

  final declaredPrefixes = <String>{};
  final usedPrefixes = <String>{};

  /// `[start, end)` pairs of named references that need rewriting.
  final entities = <int>[];

  /// `[start, end)` pairs of `<meta name="viewport">` elements.
  final viewports = <int>[];

  final _names = <String>[];
  final _starts = <int>[];
  final _flags = <int>[];
  static const _flagHead = 1;
  static const _flagViewport = 2;

  static bool _ws(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D;

  static bool _nameStart(int c) =>
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0x41 && c <= 0x5A) ||
      c == 0x5F ||
      c == 0x3A ||
      (c >= 0xC0 && c != 0xD7 && c != 0xF7 && c < 0xD800) ||
      (c >= 0xF900 && c <= 0xFFFD);

  static bool _nameChar(int c) =>
      _nameStart(c) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2D ||
      c == 0x2E ||
      c == 0xB7;

  static bool _xmlChar(int v) =>
      v == 0x9 ||
      v == 0xA ||
      v == 0xD ||
      (v >= 0x20 && v <= 0xD7FF) ||
      (v >= 0xE000 && v <= 0xFFFD) ||
      (v >= 0x10000 && v <= 0x10FFFF);

  /// End of the name starting at [i] (== [i] if there is none).
  int _name(int i) {
    if (i >= n || !_nameStart(s.codeUnitAt(i))) return i;
    i++;
    while (i < n && _nameChar(s.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  int _skipWs(int i) {
    while (i < n && _ws(s.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  /// Namespace-aware names allow at most one colon, not at either end.
  static bool _qname(String name) {
    final colon = name.indexOf(':');
    return colon < 0 ||
        (colon > 0 &&
            colon < name.length - 1 &&
            name.indexOf(':', colon + 1) < 0);
  }

  /// A namespace name the browser accepts as a URI: printable ASCII
  /// without spaces or `<>"{}|\^` and backtick.
  static bool _nsUri(String uri) {
    for (var i = 0; i < uri.length; i++) {
      final c = uri.codeUnitAt(i);
      if (c <= 0x20 ||
          c >= 0x7F ||
          c == 0x3C ||
          c == 0x3E ||
          c == 0x22 ||
          c == 0x7B ||
          c == 0x7D ||
          c == 0x7C ||
          c == 0x5C ||
          c == 0x5E ||
          c == 0x60) {
        return false;
      }
    }
    return true;
  }

  /// Checks the reference at [i] (`&...;`); returns the index after it or
  /// -1 if malformed.
  int _reference(int i) {
    var j = i + 1;
    if (j < n && s.codeUnitAt(j) == 0x23) {
      j++;
      final hex = j < n && s.codeUnitAt(j) == 0x78;
      if (hex) j++;
      final start = j;
      var value = 0;
      while (j < n) {
        final c = s.codeUnitAt(j);
        int d;
        if (c >= 0x30 && c <= 0x39) {
          d = c - 0x30;
        } else if (hex && c >= 0x61 && c <= 0x66) {
          d = c - 0x57;
        } else if (hex && c >= 0x41 && c <= 0x46) {
          d = c - 0x37;
        } else {
          break;
        }
        if (value <= 0x10FFFF) value = value * (hex ? 16 : 10) + d;
        j++;
      }
      if (j == start || j >= n || s.codeUnitAt(j) != 0x3B) return -1;
      return _xmlChar(value) ? j + 1 : -1;
    }
    final end = _name(j);
    if (end == j || end >= n || s.codeUnitAt(end) != 0x3B) return -1;
    if (!internalSubset && !_xmlEntities.contains(s.substring(j, end))) {
      entities
        ..add(i)
        ..add(end + 1);
    }
    return end + 1;
  }

  /// Validates character data from [i] to [end] (exclusive), as found in
  /// text or attribute values. Returns false on an error.
  bool _chars(int i, int end, {required bool attribute}) {
    while (i < end) {
      final c = s.codeUnitAt(i);
      if (c >= 0x5E && c < 0xD800) {
        i++;
      } else if (c == 0x26) {
        final next = _reference(i);
        if (next < 0 || next > end) return false;
        i = next;
      } else if (c == 0x3C) {
        return false;
      } else if (c < 0x20) {
        if (c != 0x09 && c != 0x0A && c != 0x0D) return false;
        i++;
      } else if (c >= 0xD800) {
        if (c <= 0xDBFF) {
          if (i + 1 >= end) return false;
          final d = s.codeUnitAt(i + 1);
          if (d < 0xDC00 || d > 0xDFFF) return false;
          i += 2;
        } else if (c <= 0xDFFF || c >= 0xFFFE) {
          return false;
        } else {
          i++;
        }
      } else if (c == 0x5D &&
          !attribute &&
          i + 2 < end &&
          s.codeUnitAt(i + 1) == 0x5D &&
          s.codeUnitAt(i + 2) == 0x3E) {
        return false; // "]]>" in content
      } else {
        i++;
      }
    }
    return true;
  }

  bool scan() {
    var i = _skipWs(0);
    if (s.startsWith('<?xml', i) && i + 5 < n && !_nameChar(s.codeUnitAt(i + 5))) {
      final end = s.indexOf('?>', i + 5);
      if (end < 0) return false;
      prologEnd = i = end + 2;
    }
    var rootDone = false;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c != 0x3C) {
        // Character data up to the next markup.
        var end = s.indexOf('<', i);
        if (end < 0) end = n;
        if (_names.isEmpty) {
          for (var k = i; k < end; k++) {
            if (!_ws(s.codeUnitAt(k))) return false; // text outside the root
          }
        } else if (!_chars(i, end, attribute: false)) {
          return false;
        }
        i = end;
        continue;
      }
      final c1 = i + 1 < n ? s.codeUnitAt(i + 1) : 0;
      if (c1 == 0x21) {
        // <!-- -->, <![CDATA[ ]]>, <!DOCTYPE>
        if (s.startsWith('<!--', i)) {
          final end = s.indexOf('-->', i + 4);
          if (end < 0) return false;
          final dash = s.indexOf('--', i + 4);
          if (dash < end) return false; // "--" inside a comment
          i = end + 3;
        } else if (s.startsWith('<![CDATA[', i)) {
          if (_names.isEmpty) return false;
          final end = s.indexOf(']]>', i + 9);
          if (end < 0) return false;
          i = end + 3;
        } else if (s.startsWith('<!DOCTYPE', i)) {
          if (rootName != null) return false;
          i = _doctype(i + 9);
          if (i < 0) return false;
        } else {
          return false;
        }
      } else if (c1 == 0x3F) {
        // Processing instruction; an XML declaration is only allowed first.
        final end = s.indexOf('?>', i + 2);
        if (end < 0) return false;
        final nameEnd = _name(i + 2);
        if (nameEnd == i + 2 || (nameEnd != end && !_ws(s.codeUnitAt(nameEnd)))) {
          return false;
        }
        if (s.substring(i + 2, nameEnd).toLowerCase() == 'xml') return false;
        i = end + 2;
      } else if (c1 == 0x2F) {
        // End tag.
        final nameEnd = _name(i + 2);
        if (nameEnd == i + 2) return false;
        final close = _skipWs(nameEnd);
        if (close >= n || s.codeUnitAt(close) != 0x3E) return false;
        if (_names.isEmpty || _names.last != s.substring(i + 2, nameEnd)) {
          return false;
        }
        final flags = _flags.removeLast();
        final start = _starts.removeLast();
        _names.removeLast();
        if (flags & _flagHead != 0) headClose = i;
        if (flags & _flagViewport != 0) {
          viewports
            ..add(start)
            ..add(close + 1);
        }
        if (_names.isEmpty) rootDone = true;
        i = close + 1;
      } else {
        if (rootDone) return false; // a second root element
        i = _startTag(i);
        if (i < 0) return false;
      }
    }
    return rootName != null && _names.isEmpty;
  }

  /// Index after the quoted literal at [i], or -1. [pubid] restricts the
  /// characters to those allowed in a public identifier.
  int _literal(int i, {bool pubid = false}) {
    if (i >= n) return -1;
    final quote = s.codeUnitAt(i);
    if (quote != 0x22 && quote != 0x27) return -1;
    final end = s.indexOf(String.fromCharCode(quote), i + 1);
    if (end < 0) return -1;
    if (pubid) {
      const extra = " \r\n-'()+,./:=?;!*#@\$_%";
      for (var k = i + 1; k < end; k++) {
        final c = s.codeUnitAt(k);
        final ok = (c >= 0x61 && c <= 0x7A) ||
            (c >= 0x41 && c <= 0x5A) ||
            (c >= 0x30 && c <= 0x39) ||
            extra.contains(s[k]);
        if (!ok) return -1;
      }
    }
    return end + 1;
  }

  /// Parses a DOCTYPE starting after `<!DOCTYPE`; returns the index after
  /// its `>` or -1.
  int _doctype(int i) {
    var j = _skipWs(i);
    if (j == i) return -1;
    final nameEnd = _name(j);
    if (nameEnd == j) return -1;
    i = nameEnd;
    j = _skipWs(i);
    if (j > i && (s.startsWith('SYSTEM', j) || s.startsWith('PUBLIC', j))) {
      final public = s.startsWith('PUBLIC', j);
      var k = j + 6;
      var m = _skipWs(k);
      if (m == k) return -1;
      if (public) {
        k = _literal(m, pubid: true);
        if (k < 0) return -1;
        m = _skipWs(k);
        if (m == k) return -1;
      }
      k = _literal(m);
      if (k < 0) return -1;
      j = _skipWs(k);
    }
    if (j < n && s.codeUnitAt(j) == 0x5B) {
      // Internal subset: skipped (quote- and comment-aware).
      internalSubset = true;
      j++;
      while (true) {
        if (j >= n) return -1;
        final c = s.codeUnitAt(j);
        if (c == 0x22 || c == 0x27) {
          j = _literal(j);
          if (j < 0) return -1;
        } else if (s.startsWith('<!--', j)) {
          final end = s.indexOf('-->', j + 4);
          if (end < 0) return -1;
          j = end + 3;
        } else if (c == 0x5D) {
          j = _skipWs(j + 1);
          break;
        } else {
          j++;
        }
      }
    }
    if (j >= n || s.codeUnitAt(j) != 0x3E) return -1;
    return j + 1;
  }

  /// Parses a start tag at [start]; returns the index after it or -1.
  int _startTag(int start) {
    final nameEnd = _name(start + 1);
    if (nameEnd == start + 1) return -1;
    final name = s.substring(start + 1, nameEnd);
    if (!_qname(name)) return -1;
    final colon = name.indexOf(':');
    if (colon > 0) usedPrefixes.add(name.substring(0, colon));
    final depth = _names.length;
    final isRoot = depth == 0;
    final isMeta = name == 'meta';
    var viewport = false;
    final attrs = <String>[];
    var i = nameEnd;
    bool selfClosing;
    while (true) {
      final afterWs = _skipWs(i);
      if (afterWs >= n) return -1;
      final c = s.codeUnitAt(afterWs);
      if (c == 0x3E) {
        selfClosing = false;
        i = afterWs + 1;
        break;
      }
      if (c == 0x2F) {
        if (afterWs + 1 >= n || s.codeUnitAt(afterWs + 1) != 0x3E) return -1;
        selfClosing = true;
        i = afterWs + 2;
        break;
      }
      if (afterWs == i) return -1; // attributes must be separated by space
      final attrEnd = _name(afterWs);
      if (attrEnd == afterWs) return -1;
      final attr = s.substring(afterWs, attrEnd);
      if (!_qname(attr) || attrs.contains(attr)) return -1; // or duplicate
      attrs.add(attr);
      var j = _skipWs(attrEnd);
      if (j >= n || s.codeUnitAt(j) != 0x3D) return -1;
      j = _skipWs(j + 1);
      if (j >= n) return -1;
      final quote = s.codeUnitAt(j);
      if (quote != 0x22 && quote != 0x27) return -1;
      final close = s.indexOf(String.fromCharCode(quote), j + 1);
      if (close < 0) return -1;
      if (!_chars(j + 1, close, attribute: true)) return -1;
      if (attr == 'xmlns' || attr.startsWith('xmlns:')) {
        // Namespace names are taken literally here; references in them are
        // rare enough to just leave to the HTML parser.
        final value = s.substring(j + 1, close);
        if (value.contains('&') || !_nsUri(value)) return -1;
        if (attr == 'xmlns') {
          if (isRoot) rootDefaultNs = value;
        } else {
          final prefix = attr.substring(6);
          if (value.isEmpty ||
              prefix == 'xmlns' ||
              (prefix == 'xml') !=
                  (value == 'http://www.w3.org/XML/1998/namespace')) {
            return -1;
          }
          declaredPrefixes.add(prefix);
        }
      } else {
        final ac = attr.indexOf(':');
        if (ac > 0) usedPrefixes.add(attr.substring(0, ac));
        if (isMeta &&
            attr == 'name' &&
            s.substring(j + 1, close).trim().toLowerCase() == 'viewport') {
          viewport = true;
        }
      }
      i = close + 1;
    }

    if (isRoot) {
      rootName = name;
      rootEnd = i;
      rootSelfClosing = selfClosing;
    }
    var flags = 0;
    if (depth == 1 && name == 'head' && headStart < 0) {
      headStart = start;
      headEnd = i;
      headSelfClosing = selfClosing;
      flags |= _flagHead;
    }
    if (viewport) {
      if (selfClosing) {
        viewports
          ..add(start)
          ..add(i);
      } else {
        flags |= _flagViewport;
      }
    }
    if (!selfClosing) {
      _names.add(name);
      _starts.add(start);
      _flags.add(flags);
    }
    return i;
  }
}

// ----------------------------------------------------------------- HTML

PreparedDocument _htmlDocument(String text, DocumentPrepareRequest r) {
  var t = text
      .replaceFirst(RegExp(r'^\s*<\?xml[^>]*\?>'), '')
      .replaceFirst(
        RegExp(r'<!DOCTYPE[^>\[]*(\[[\s\S]*?\])?\s*>', caseSensitive: false),
        '',
      );
  // XHTML-style self-closing tags (<a id="x"/>, <title/>, <div/>) would
  // swallow the following content in the HTML parser.
  t = t.replaceAllMapped(
    RegExp(r'<([A-Za-z][\w:.\-]*)(\s[^<>]*?)?\s*/>'),
    (m) {
      final tag = m.group(1)!;
      final local = tag.contains(':') ? tag.split(':').last : tag;
      if (_voidElements.contains(local.toLowerCase())) return m.group(0)!;
      return '<$tag${m.group(2) ?? ''}></$tag>';
    },
  );
  return _inject('<!DOCTYPE html>\n${t.trimLeft()}', r);
}

/// Injects the reader into HTML markup (located with forgiving regexes).
PreparedDocument _inject(String t, DocumentPrepareRequest r) {
  final edits = _Edits();
  if (!r.fixedLayout) {
    for (final m in RegExp(
      r'''<meta\b[^>]*name\s*=\s*["']viewport["'][^>]*>''',
      caseSensitive: false,
    ).allMatches(t)) {
      edits.add(m.start, m.end, '');
    }
  }
  final headOpen = RegExp(r'<head\b[^>]*>', caseSensitive: false).firstMatch(t);
  if (headOpen != null) {
    final open = headOpen.group(0)!;
    if (open.endsWith('/>')) {
      edits.add(headOpen.start, headOpen.end, '');
      edits.head(headOpen.end, r, wrap: true);
      return edits.build(t, 0, xhtml: false);
    }
    final close = RegExp(r'</head\s*>', caseSensitive: false)
        .firstMatch(t.substring(headOpen.end));
    if (close != null) {
      final closeAt = headOpen.end + close.start;
      if (!r.fixedLayout) {
        edits.add(
          headOpen.end,
          headOpen.end,
          '<meta name="viewport" content="width=device-width, '
          'initial-scale=1, maximum-scale=1, user-scalable=no"/>',
        );
      }
      edits.tail(closeAt, r);
    } else {
      edits.head(headOpen.end, r);
    }
    return edits.build(t, 0, xhtml: false);
  }
  final htmlOpen = RegExp(r'<html\b[^>]*>', caseSensitive: false).firstMatch(t);
  if (htmlOpen != null) {
    edits.head(htmlOpen.end, r, wrap: true);
    return edits.build(t, 0, xhtml: false);
  }
  final doctype =
      RegExp(r'^\s*<!DOCTYPE[^>]*>', caseSensitive: false).firstMatch(t);
  final at = doctype?.end ?? 0;
  edits.add(at, at, '<html>');
  edits.head(at, r, wrap: true);
  edits.add(at, at, '<body>');
  edits.add(t.length, t.length, '</body></html>');
  return edits.build(t, 0, xhtml: false);
}
