import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'book_models.dart';
import 'html_text.dart';
import 'text_codec.dart';

/// Placeholder replaced with the reader config JSON each time a prepared
/// document is served.
const kReaderConfigPlaceholder = '/*__ER_CONFIG__*/null';

/// Input for [prepareDocument]; plain data so it can be sent to an isolate.
class DocumentPrepareRequest {
  const DocumentPrepareRequest({
    required this.bytes,
    required this.path,
    required this.mediaType,
    required this.assetBase,
    this.fixedLayout = false,
    this.forceHtml = false,
  });

  final Uint8List bytes;

  /// Decoded resource path of the document inside the book.
  final String path;
  final String mediaType;

  /// Absolute URL path of the reader assets, ending in `/`.
  final String assetBase;
  final bool fixedLayout;

  /// Skip the XHTML attempt (used after XHTML rendering failed).
  final bool forceHtml;
}

class PreparedDocument {
  const PreparedDocument({required this.xhtml, required this.template});

  /// True to serve as `application/xhtml+xml`, false for `text/html`.
  final bool xhtml;

  /// Markup with the reader assets injected and [kReaderConfigPlaceholder]
  /// where the config goes.
  final String template;
}

const _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', //
  'meta', 'param', 'source', 'track', 'wbr', 'basefont', 'frame', 'keygen',
};

const _xmlEntities = {'lt', 'gt', 'amp', 'quot', 'apos'};

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
/// Pure function (runs in an isolate).
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
    return PreparedDocument(
      xhtml: false,
      template: _inject(
        '<!DOCTYPE html><html><head></head><body><pre>'
        '${HtmlText.escape(text)}</pre></body></html>',
        r,
      ),
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
  return PreparedDocument(
    xhtml: false,
    template: _inject(
      '<!DOCTYPE html><html><head></head><body class="er-image-doc">'
      '<div class="er-image-page"><img src="$src" alt=""/></div>'
      '</body></html>',
      r,
    ),
  );
}

PreparedDocument? _tryXhtml(String text, DocumentPrepareRequest r) {
  var t = text.replaceFirst(RegExp(r'^\s*<\?xml[^>]*\?>'), '');

  // Undeclared HTML entities (&nbsp; ...) are fatal in XML: make them
  // numeric, unless the DOCTYPE declares its own entities.
  if (!RegExp(r'<!DOCTYPE[^>\[]*\[').hasMatch(t)) {
    const mapping = XmlDefaultEntityMapping.html5();
    t = t.replaceAllMapped(RegExp(r'&([A-Za-z][A-Za-z0-9]*);'), (m) {
      final name = m.group(1)!;
      if (_xmlEntities.contains(name)) return m.group(0)!;
      final value = mapping.decodeEntity(name);
      if (value == null) return '&amp;$name;';
      return value.runes.map((c) => '&#$c;').join();
    });
  }

  final htmlTag = RegExp(r'<html\b[^>]*>').firstMatch(t);
  if (htmlTag == null) return null;
  var tag = htmlTag.group(0)!;
  final defaultNs =
      RegExp(r'''\sxmlns\s*=\s*["']([^"']*)["']''').firstMatch(tag);
  if (defaultNs == null) {
    tag = tag.replaceFirst('<html', '<html xmlns="http://www.w3.org/1999/xhtml"');
  } else if (defaultNs.group(1) != 'http://www.w3.org/1999/xhtml') {
    return null;
  }

  // Declare namespace prefixes that are used but never declared.
  final declared = RegExp(r'xmlns:([A-Za-z_][\w.\-]*)\s*=')
      .allMatches(t)
      .map((m) => m.group(1)!)
      .toSet();
  final used = <String>{};
  for (final m in RegExp(r'</?([A-Za-z_][\w.\-]*):[A-Za-z_]').allMatches(t)) {
    used.add(m.group(1)!);
  }
  for (final m in RegExp(r'\s([A-Za-z_][\w.\-]*):[A-Za-z_][\w.\-]*\s*=')
      .allMatches(t)) {
    used.add(m.group(1)!);
  }
  used.removeAll(['xml', 'xmlns', ...declared]);
  if (used.isNotEmpty) {
    final extra = used
        .map((p) => ' xmlns:$p="${_knownNamespaces[p] ?? 'urn:x-unknown:$p'}"')
        .join();
    tag = tag.endsWith('/>')
        ? '${tag.substring(0, tag.length - 2)}$extra/>'
        : '${tag.substring(0, tag.length - 1)}$extra>';
  }
  t = t.replaceRange(htmlTag.start, htmlTag.end, tag);

  try {
    XmlDocument.parse(t);
  } catch (_) {
    return null;
  }
  return PreparedDocument(xhtml: true, template: _inject(t, r));
}

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
  return PreparedDocument(
    xhtml: false,
    template: _inject('<!DOCTYPE html>\n${t.trimLeft()}', r),
  );
}

String _inject(String t, DocumentPrepareRequest r) {
  final base = r.assetBase;
  if (!r.fixedLayout) {
    t = t.replaceAll(
      RegExp(
        r'''<meta\b[^>]*name\s*=\s*["']viewport["'][^>]*>''',
        caseSensitive: false,
      ),
      '',
    );
  }
  final viewport = r.fixedLayout
      ? ''
      : '<meta name="viewport" content="width=device-width, '
          'initial-scale=1, maximum-scale=1, user-scalable=no"/>';
  final tail = '<link rel="stylesheet" type="text/css" href="${base}reader.css"/>'
      '<script type="text/javascript">//<![CDATA[\n'
      'window.__ER_CONFIG__ = $kReaderConfigPlaceholder;\n//]]></script>'
      '<script type="text/javascript" src="${base}reader.js"></script>';

  final headOpen = RegExp(r'<head\b[^>]*>', caseSensitive: false).firstMatch(t);
  if (headOpen != null) {
    final open = headOpen.group(0)!;
    if (open.endsWith('/>')) {
      return t.replaceRange(
        headOpen.start,
        headOpen.end,
        '<head>$viewport$tail</head>',
      );
    }
    final close = RegExp(r'</head\s*>', caseSensitive: false)
        .firstMatch(t.substring(headOpen.end));
    if (close != null) {
      final closeAt = headOpen.end + close.start;
      return t.substring(0, headOpen.end) +
          viewport +
          t.substring(headOpen.end, closeAt) +
          tail +
          t.substring(closeAt);
    }
    return t.substring(0, headOpen.end) +
        viewport +
        tail +
        t.substring(headOpen.end);
  }
  final htmlOpen = RegExp(r'<html\b[^>]*>', caseSensitive: false).firstMatch(t);
  final block = '<head>$viewport$tail</head>';
  if (htmlOpen != null) {
    return t.substring(0, htmlOpen.end) + block + t.substring(htmlOpen.end);
  }
  final doctype =
      RegExp(r'^\s*<!DOCTYPE[^>]*>', caseSensitive: false).firstMatch(t);
  final at = doctype?.end ?? 0;
  return '${t.substring(0, at)}<html>$block<body>${t.substring(at)}</body></html>';
}
