import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'book_models.dart';
import 'book_source.dart';
import 'epub_parser.dart' show parseXmlLenient;
import 'html_text.dart';
import 'text_codec.dart';
import 'zip_index.dart';

/// FictionBook 2 (`.fb2`, `.fb2.zip`, `.fbz`), converted to HTML chapters.
abstract final class Fb2BookSource {
  static Future<BookSource> open(File file) async {
    final path = file.path;
    final (info, resources) = await Isolate.run(() => parseFb2File(path));
    return MemoryBookSource(info: info, resources: resources);
  }
}

(BookInfo, Map<String, Uint8List>) parseFb2File(String path) {
  var bytes = File(path).readAsBytesSync();
  if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    final index = ZipIndex.read(path);
    ZipEntryInfo? best;
    for (final e in index.entries.values) {
      if (e.name.toLowerCase().endsWith('.fb2')) {
        best = e;
        break;
      }
    }
    if (best == null) {
      throw const BookOpenException(
        "This ZIP archive doesn't contain an EPUB or FB2 book.",
      );
    }
    final reader = ZipSyncReader(path);
    try {
      bytes = reader.read(best);
    } finally {
      reader.close();
    }
  }
  final text = TextCodec.decodeMarkup(bytes);
  XmlDocument doc;
  try {
    doc = parseXmlLenient(text);
  } catch (_) {
    throw const BookOpenException(
      "This FB2 book's XML is damaged and can't be read.",
    );
  }
  final title = BookPaths.basename(path).replaceAll(
    RegExp(r'(\.fb2)?(\.zip)?$|\.fbz$', caseSensitive: false),
    '',
  );
  return _Fb2Converter(doc, title).convert();
}

class _Chapter {
  _Chapter(this.title);

  String title;
  final StringBuffer html = StringBuffer();
}

class _Fb2Converter {
  _Fb2Converter(this.doc, this.fallbackTitle);

  final XmlDocument doc;
  final String fallbackTitle;
  final resources = <String, Uint8List>{};
  final chapters = <_Chapter>[];
  final idToChapter = <String, int>{};
  final binaryIds = <String>{};
  var _autoId = 0;

  static const _linkMarker = '\u0001';

  int get _current => chapters.length - 1;

  static String _path(int chapter) =>
      'chapter-${(chapter + 1).toString().padLeft(3, '0')}.html';

  XmlElement? _child(XmlElement? parent, String name) {
    if (parent == null) return null;
    for (final e in parent.childElements) {
      if (e.name.local == name) return e;
    }
    return null;
  }

  String _text(XmlElement? e) =>
      e == null ? '' : HtmlText.collapse(e.innerText);

  String? _href(XmlElement e) {
    for (final a in e.attributes) {
      if (a.name.local == 'href') return a.value;
    }
    return null;
  }

  (BookInfo, Map<String, Uint8List>) convert() {
    final root = doc.rootElement;
    final description = _child(root, 'description');
    final titleInfo = _child(description, 'title-info');

    final authors = <String>[];
    for (final a in titleInfo?.childElements ?? const <XmlElement>[]) {
      if (a.name.local != 'author') continue;
      final parts = [
        _text(_child(a, 'first-name')),
        _text(_child(a, 'middle-name')),
        _text(_child(a, 'last-name')),
      ].where((s) => s.isNotEmpty).join(' ');
      final name = parts.isNotEmpty ? parts : _text(_child(a, 'nickname'));
      if (name.isNotEmpty && !authors.contains(name)) authors.add(name);
    }
    final bookTitle = _text(_child(titleInfo, 'book-title'));
    final lang = _text(_child(titleInfo, 'lang'));
    final annotation = _text(_child(titleInfo, 'annotation'));

    // Binaries (base64 images).
    final binaryTypes = <String, String>{};
    for (final b in root.childElements) {
      if (b.name.local != 'binary') continue;
      final id = b.getAttribute('id');
      if (id == null || id.isEmpty) continue;
      try {
        final data = base64.decode(
          b.innerText.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), ''),
        );
        resources['images/$id'] = data;
        binaryIds.add(id);
        binaryTypes[id] = b.getAttribute('content-type') ?? '';
      } catch (_) {
        // Skip a corrupt image rather than the whole book.
      }
    }

    // Cover page.
    String? coverPath;
    final coverImage = _child(_child(titleInfo, 'coverpage'), 'image');
    if (coverImage != null) {
      final id = _imageId(coverImage);
      if (id != null) {
        coverPath = 'images/$id';
        chapters.add(_Chapter('Cover'));
        chapters.last.html.write(
          '<div class="fb2-cover"><img src="${HtmlText.escape(BookPaths.encode(coverPath))}" alt="Cover"/></div>',
        );
      }
    }

    final toc = <TocEntry>[];
    final bodies =
        root.childElements.where((e) => e.name.local == 'body').toList();
    if (bodies.isEmpty) {
      throw const BookOpenException('This FB2 book has no text.');
    }
    final mainBody = bodies.firstWhere(
      (b) => b.getAttribute('name') == null,
      orElse: () => bodies.first,
    );

    // Title page content of the main body (title, epigraphs, images).
    final intro = mainBody.childElements
        .where((e) => e.name.local != 'section')
        .toList();
    final sections = mainBody.childElements
        .where((e) => e.name.local == 'section')
        .toList();

    if (sections.isEmpty) {
      chapters.add(_Chapter(bookTitle.isEmpty ? fallbackTitle : bookTitle));
      for (final n in mainBody.children) {
        _emit(n, chapters.last.html, 0, toc);
      }
    } else {
      if (intro.isNotEmpty) {
        chapters.add(_Chapter(bookTitle.isEmpty ? 'Title page' : bookTitle));
        toc.add(TocEntry(
          title: chapters.last.title,
          path: _path(_current),
          spineIndex: _current,
        ));
        for (final n in intro) {
          _emit(n, chapters.last.html, 0, null);
        }
      }
      for (final s in sections) {
        _chapterize(s, 0, toc);
      }
    }

    // Notes / comments bodies.
    for (final body in bodies) {
      if (identical(body, mainBody)) continue;
      final name = body.getAttribute('name') ?? '';
      final title = _text(_child(body, 'title'));
      chapters.add(_Chapter(title.isNotEmpty
          ? title
          : name == 'comments'
              ? 'Comments'
              : 'Notes'));
      final entry = TocEntry(
        title: chapters.last.title,
        path: _path(_current),
        spineIndex: _current,
      );
      toc.add(entry);
      for (final n in body.children) {
        _emit(n, chapters.last.html, 0, null);
      }
    }

    // Assemble documents, resolving internal links across chapters.
    final language = lang.isEmpty ? null : lang;
    final spine = <SpineItem>[];
    final linkPattern = RegExp('$_linkMarker([^$_linkMarker]*)$_linkMarker');
    for (var i = 0; i < chapters.length; i++) {
      final body = chapters[i].html.toString().replaceAllMapped(linkPattern,
          (m) {
        final id = m.group(1)!;
        final target = idToChapter[HtmlText.decodeEntities(id)];
        if (target == null || target == i) return '#$id';
        return '${_path(target)}#$id';
      });
      final html = '<!DOCTYPE html>\n<html${language == null ? '' : ' lang="${HtmlText.escape(language)}"'}>'
          '<head><meta charset="utf-8"/><title>${HtmlText.escape(chapters[i].title)}</title>'
          '<link rel="stylesheet" type="text/css" href="fb2.css"/></head>'
          '<body class="fb2">$body</body></html>';
      final bytes = Uint8List.fromList(utf8.encode(html));
      resources[_path(i)] = bytes;
      spine.add(SpineItem(
        path: _path(i),
        mediaType: 'text/html',
        size: bytes.length,
        title: chapters[i].title,
      ));
    }
    resources['fb2.css'] = Uint8List.fromList(utf8.encode(_fb2Css));

    if (spine.isEmpty) {
      throw const BookOpenException('This FB2 book has no text.');
    }

    if (toc.isEmpty) {
      for (var i = 0; i < chapters.length; i++) {
        toc.add(TocEntry(
          title: chapters[i].title,
          path: _path(i),
          spineIndex: i,
        ));
      }
    } else if (coverPath != null) {
      toc.insert(0, TocEntry(title: 'Cover', path: _path(0), spineIndex: 0));
    }

    final rtl = RegExp(r'^(ar|he|iw|fa|ur|yi|ps|sd|ug|dv)\b')
        .hasMatch(lang.toLowerCase());
    return (
      BookInfo(
        format: BookFormat.fb2,
        metadata: BookMetadata(
          title: bookTitle.isEmpty ? fallbackTitle : bookTitle,
          authors: authors,
          language: language,
          description: annotation.isEmpty ? null : annotation,
          coverPath: coverPath,
          rtl: rtl,
        ),
        spine: spine,
        toc: toc,
      ),
      resources,
    );
  }

  /// Splits big sections that are mostly sub-sections into one chapter per
  /// sub-section; everything else becomes a single chapter.
  void _chapterize(XmlElement section, int depth, List<TocEntry> tocOut) {
    final subs = section.childElements
        .where((e) => e.name.local == 'section')
        .toList();
    final ownText = section.childElements
        .where((e) => e.name.local != 'section')
        .fold<int>(0, (n, e) => n + e.innerText.length);
    final total = section.innerText.length;
    final title = _sectionTitle(section);

    if (subs.isNotEmpty && depth < 3 && total > 60000 && ownText < 3000) {
      chapters.add(_Chapter(title ?? 'Chapter ${chapters.length + 1}'));
      final id = _sectionId(section);
      final entry = TocEntry(
        title: title ?? chapters.last.title,
        path: _path(_current),
        fragment: id,
        spineIndex: _current,
      );
      tocOut.add(entry);
      final out = chapters.last.html;
      out.write('<section class="fb2-section" id="${HtmlText.escape(id)}">');
      for (final child in section.childElements) {
        if (child.name.local == 'section') continue;
        _emit(child, out, depth, null);
      }
      out.write('</section>');
      for (final s in subs) {
        _chapterize(s, depth + 1, entry.children);
      }
      return;
    }

    chapters.add(_Chapter(title ?? 'Chapter ${chapters.length + 1}'));
    _emit(section, chapters.last.html, depth, tocOut, chapterRoot: true);
  }

  String? _sectionTitle(XmlElement section) {
    final t = _text(_child(section, 'title'));
    return t.isEmpty ? null : t;
  }

  String _sectionId(XmlElement section) {
    final id = section.getAttribute('id') ?? 'fb2s${_autoId++}';
    idToChapter.putIfAbsent(id, () => _current);
    return id;
  }

  String? _imageId(XmlElement image) {
    final href = _href(image);
    if (href == null) return null;
    final id = href.startsWith('#') ? href.substring(1) : href;
    return binaryIds.contains(id) ? id : null;
  }

  void _emit(
    XmlNode node,
    StringBuffer out,
    int depth,
    List<TocEntry>? tocOut, {
    bool chapterRoot = false,
  }) {
    if (node is XmlText || node is XmlCDATA) {
      out.write(HtmlText.escape(node.value ?? ''));
      return;
    }
    if (node is! XmlElement) return;
    final el = node;
    final name = el.name.local;
    final rawId = el.getAttribute('id');
    if (rawId != null) idToChapter.putIfAbsent(rawId, () => _current);
    final idAttr = rawId == null ? '' : ' id="${HtmlText.escape(rawId)}"';

    void children([int? d, List<TocEntry>? toc]) {
      for (final c in el.children) {
        _emit(c, out, d ?? depth, toc);
      }
    }

    switch (name) {
      case 'section':
        final id = _sectionId(el);
        final title = _sectionTitle(el);
        var childToc = tocOut;
        if (tocOut != null && title != null) {
          final entry = TocEntry(
            title: title,
            path: _path(_current),
            fragment: chapterRoot ? null : id,
            spineIndex: _current,
          );
          tocOut.add(entry);
          childToc = entry.children;
        }
        out.write('<section class="fb2-section" id="${HtmlText.escape(id)}">');
        children(depth + 1, childToc);
        out.write('</section>');
      case 'title':
        final level = (depth + 1).clamp(1, 6);
        out.write('<div class="fb2-title"$idAttr><h$level>');
        var first = true;
        for (final c in el.childElements) {
          if (c.name.local != 'p') continue;
          if (!first) out.write('<br/>');
          first = false;
          for (final n in c.children) {
            _emit(n, out, depth, null);
          }
        }
        if (first) out.write(HtmlText.escape(_text(el)));
        out.write('</h$level></div>');
      case 'subtitle':
        out.write('<h6 class="fb2-subtitle"$idAttr>');
        children();
        out.write('</h6>');
      case 'p':
        out.write('<p$idAttr>');
        children();
        out.write('</p>');
      case 'empty-line':
        out.write('<p class="fb2-empty">&#160;</p>');
      case 'emphasis':
        out.write('<em>');
        children();
        out.write('</em>');
      case 'strong':
        out.write('<strong>');
        children();
        out.write('</strong>');
      case 'strikethrough':
        out.write('<s>');
        children();
        out.write('</s>');
      case 'sub' || 'sup' || 'code':
        out.write('<$name>');
        children();
        out.write('</$name>');
      case 'style':
        out.write('<span>');
        children();
        out.write('</span>');
      case 'a':
        final href = _href(el) ?? '';
        final note = el.getAttribute('type') == 'note';
        final target = href.startsWith('#')
            ? '$_linkMarker${HtmlText.escape(href.substring(1))}$_linkMarker'
            : HtmlText.escape(href);
        out.write('<a href="$target"${note ? ' class="fb2-noteref"' : ''}>');
        children();
        out.write('</a>');
      case 'image':
        final id = _imageId(el);
        if (id == null) return;
        final src = HtmlText.escape(BookPaths.encode('images/$id'));
        final alt = HtmlText.escape(el.getAttribute('alt') ?? '');
        final parent = el.parent;
        final inline = parent is XmlElement &&
            const {'p', 'v', 'subtitle', 'td', 'th', 'text-author', 'emphasis', 'strong'}
                .contains(parent.name.local);
        if (inline) {
          out.write('<img class="fb2-inline" src="$src" alt="$alt"/>');
        } else {
          out.write('<div class="fb2-image"$idAttr><img src="$src" alt="$alt"/></div>');
        }
      case 'epigraph':
        out.write('<blockquote class="fb2-epigraph"$idAttr>');
        children();
        out.write('</blockquote>');
      case 'cite':
        out.write('<blockquote class="fb2-cite"$idAttr>');
        children();
        out.write('</blockquote>');
      case 'annotation':
        out.write('<div class="fb2-annotation"$idAttr>');
        children();
        out.write('</div>');
      case 'poem':
        out.write('<div class="fb2-poem"$idAttr>');
        children();
        out.write('</div>');
      case 'stanza':
        out.write('<div class="fb2-stanza">');
        children();
        out.write('</div>');
      case 'v':
        out.write('<p class="fb2-v"$idAttr>');
        children();
        out.write('</p>');
      case 'text-author':
        out.write('<p class="fb2-author"$idAttr>');
        children();
        out.write('</p>');
      case 'date':
        out.write('<p class="fb2-date">');
        children();
        out.write('</p>');
      case 'table':
        out.write('<table class="fb2-table"$idAttr>');
        children();
        out.write('</table>');
      case 'tr':
        out.write('<tr>');
        children();
        out.write('</tr>');
      case 'td' || 'th':
        final span = StringBuffer();
        for (final attr in const ['colspan', 'rowspan', 'align']) {
          final v = el.getAttribute(attr);
          if (v != null) span.write(' $attr="${HtmlText.escape(v)}"');
        }
        out.write('<$name$span>');
        children();
        out.write('</$name>');
      default:
        children();
    }
  }
}

const _fb2Css = '''
body.fb2 p { margin: 0 0 0.25em; text-indent: 1.5em; }
.fb2-title { text-align: center; margin: 1.6em 0 1em; text-indent: 0; }
.fb2-title h1, .fb2-title h2, .fb2-title h3, .fb2-title h4, .fb2-title h5, .fb2-title h6 { margin: 0.2em 0; }
.fb2-subtitle { text-align: center; font-size: 1em; margin: 1em 0 0.6em; }
.fb2-epigraph { margin: 1em 0 1em 30%; font-style: italic; }
.fb2-epigraph p, .fb2-cite p, .fb2-annotation p { text-indent: 0; }
.fb2-cite { margin: 1em 1.5em; }
.fb2-poem { margin: 1em 0 1em 2em; }
.fb2-stanza { margin: 0.6em 0; }
body.fb2 p.fb2-v { text-indent: 0; margin: 0; }
body.fb2 p.fb2-author { text-align: right; font-style: italic; text-indent: 0; }
body.fb2 p.fb2-date { text-align: right; text-indent: 0; }
body.fb2 p.fb2-empty { text-indent: 0; }
.fb2-image { text-align: center; margin: 1em 0; text-indent: 0; }
.fb2-image img { max-width: 100%; height: auto; }
img.fb2-inline { max-height: 1.5em; vertical-align: middle; }
.fb2-cover { text-align: center; }
.fb2-cover img { max-width: 100%; max-height: 92vh; height: auto; }
a.fb2-noteref { vertical-align: super; font-size: 0.75em; line-height: 1; text-decoration: none; }
table.fb2-table { border-collapse: collapse; margin: 1em 0; }
table.fb2-table td, table.fb2-table th { border: 1px solid rgba(128,128,128,0.5); padding: 0.2em 0.4em; }
''';
