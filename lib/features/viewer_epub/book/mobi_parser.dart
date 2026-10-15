import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'book_models.dart';
import 'book_source.dart';
import 'html_text.dart';
import 'text_codec.dart';

/// MOBI / AZW / AZW3 (KF8) / PRC / PalmDOC, converted to HTML chapters.
///
/// Supports PalmDOC compression (1 = none, 2 = LZ77). HUFF/CDIC (17480)
/// and DRM-encrypted books are rejected with a friendly message. KF8-only
/// AZW3 files get a best-effort extraction (no skeleton/fragment index).
abstract final class MobiBookSource {
  static Future<BookSource> open(File file) async {
    final path = file.path;
    final (info, resources) = await Isolate.run(() => parseMobiFile(path));
    return MemoryBookSource(info: info, resources: resources);
  }
}

(BookInfo, Map<String, Uint8List>) parseMobiFile(String path) {
  final data = File(path).readAsBytesSync();
  final name = path.replaceAll('\\', '/').split('/').last;
  return _MobiConverter(data, name.replaceAll(RegExp(r'\.[^.]+$'), ''))
      .convert();
}

const _base32 = '0123456789ABCDEFGHIJKLMNOPQRSTUV';

class _MobiConverter {
  _MobiConverter(this.data, this.fileTitle)
      : bd = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData bd;
  final String fileTitle;
  late final List<int> offsets;
  final resources = <String, Uint8List>{};

  int _u16(Uint8List b, int o) => o + 2 <= b.length ? (b[o] << 8) | b[o + 1] : 0;
  int _u32(Uint8List b, int o) => o + 4 <= b.length
      ? ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3])
      : 0;

  Uint8List record(int i) {
    if (i < 0 || i >= offsets.length) return Uint8List(0);
    final start = offsets[i];
    final end = i + 1 < offsets.length ? offsets[i + 1] : data.length;
    if (start >= data.length || end <= start) return Uint8List(0);
    return Uint8List.sublistView(data, start, math.min(end, data.length));
  }

  static BookOpenException _damaged() => const BookOpenException(
        'This Kindle/MOBI file is damaged or incomplete.',
      );

  (BookInfo, Map<String, Uint8List>) convert() {
    if (data.length < 86) throw _damaged();
    final type = String.fromCharCodes(data.sublist(60, 68));
    final count = _u16(data, 76);
    if (count < 2 || 78 + count * 8 > data.length) throw _damaged();
    offsets = [for (var i = 0; i < count; i++) _u32(data, 78 + i * 8)];
    for (var i = 1; i < offsets.length; i++) {
      if (offsets[i] < offsets[i - 1] || offsets[i] > data.length) {
        throw _damaged();
      }
    }
    final pdbName = latin1
        .decode(data.sublist(0, 32))
        .split('\u0000')
        .first
        .replaceAll('_', ' ')
        .trim();

    final rec0 = record(0);
    if (rec0.length < 16) throw _damaged();
    final compression = _u16(rec0, 0);
    final textLength = _u32(rec0, 4);
    final textRecords = _u16(rec0, 8);
    final encryption = _u16(rec0, 12);

    if (type == 'TEXtREAd') {
      return _palmDoc(compression, textLength, textRecords,
          pdbName.isEmpty ? fileTitle : pdbName);
    }

    final isMobi = rec0.length >= 24 &&
        String.fromCharCodes(rec0.sublist(16, 20)) == 'MOBI';
    if (!isMobi) {
      throw const BookOpenException(
        "This file doesn't contain a MOBI header and can't be read.",
      );
    }
    if (encryption != 0) {
      throw const BookOpenException(
        'This Kindle book is protected by DRM and can only be read in the '
        'Kindle app or on a Kindle device.',
      );
    }
    if (compression == 17480) {
      throw const BookOpenException(
        "This MOBI/AZW3 uses HUFF/CDIC compression, which isn't supported "
        'yet. Try converting it to EPUB (for example with Calibre).',
      );
    }
    if (compression != 1 && compression != 2) {
      throw BookOpenException(
        'This MOBI uses an unknown compression ($compression) that isn\'t '
        'supported.',
      );
    }

    final headerLength = _u32(rec0, 20);
    final encodingCode = _u32(rec0, 28);
    final version = _u32(rec0, 36);
    final firstImage = _u32(rec0, 0x6C);
    final extraFlags =
        headerLength >= 0xE4 && rec0.length >= 0xF4 ? _u16(rec0, 0xF2) : 0;
    final exthFlags = _u32(rec0, 0x80);
    final exth = (exthFlags & 0x40) != 0
        ? _parseExth(rec0, 16 + headerLength)
        : <int, List<Uint8List>>{};

    final utf8Text = encodingCode == 65001;
    String exthString(int key) {
      final v = exth[key];
      if (v == null || v.isEmpty) return '';
      return (utf8Text
              ? utf8.decode(v.first, allowMalformed: true)
              : TextCodec.decodeCp1252(v.first))
          .trim();
    }

    var fullName = '';
    final nameOffset = _u32(rec0, 0x54);
    final nameLength = _u32(rec0, 0x58);
    if (nameLength > 0 && nameOffset + nameLength <= rec0.length) {
      final raw = Uint8List.sublistView(rec0, nameOffset, nameOffset + nameLength);
      fullName = (utf8Text
              ? utf8.decode(raw, allowMalformed: true)
              : TextCodec.decodeCp1252(raw))
          .trim();
    }

    final authors = <String>[];
    for (final a in exth[100] ?? const <Uint8List>[]) {
      final s = (utf8Text
              ? utf8.decode(a, allowMalformed: true)
              : TextCodec.decodeCp1252(a))
          .trim();
      if (s.isNotEmpty && !authors.contains(s)) authors.add(s);
    }
    final title = [exthString(503), fullName, pdbName, fileTitle]
        .firstWhere((s) => s.isNotEmpty, orElse: () => 'Untitled');
    final language = exthString(524);
    final description = exthString(103);
    final publisher = exthString(101);

    final boundary = exth[121]?.isNotEmpty == true && exth[121]!.first.length >= 4
        ? _u32(exth[121]!.first, 0)
        : 0xFFFFFFFF;
    final kf8Only = version >= 8 && (boundary == 0xFFFFFFFF || boundary == 0);

    // Text.
    final text = BytesBuilder(copy: false);
    for (var i = 1; i <= textRecords && i < offsets.length; i++) {
      var rec = record(i);
      final trail = _trailingSize(rec, extraFlags);
      if (trail > 0 && trail <= rec.length) {
        rec = Uint8List.sublistView(rec, 0, rec.length - trail);
      }
      text.add(compression == 2 ? _palmDocDecompress(rec) : rec);
    }
    var raw = text.takeBytes();
    if (textLength > 0 && raw.length > textLength) {
      raw = Uint8List.sublistView(raw, 0, textLength);
    }
    if (raw.isEmpty) throw _damaged();

    // Cover image record (EXTH 201 = offset from the first image record).
    int? coverIndex;
    final coverOffset = exth[201]?.isNotEmpty == true && exth[201]!.first.length >= 4
        ? _u32(exth[201]!.first, 0)
        : null;
    if (coverOffset != null && coverOffset != 0xFFFFFFFF) {
      coverIndex = coverOffset + 1;
    }

    final chapters = kf8Only
        ? _kf8Chapters(raw, rec0, firstImage, utf8Text)
        : _mobi6Chapters(raw, firstImage, utf8Text);

    String? coverPath;
    if (coverIndex != null && firstImage != 0xFFFFFFFF) {
      coverPath = _imagePath(firstImage, coverIndex);
    }
    if (coverPath != null &&
        !chapters.any((c) => c.html.contains('src="$coverPath"'))) {
      chapters.insert(
        0,
        _MobiChapter(
          'Cover',
          '<div class="mobi-cover"><img src="$coverPath" alt="Cover"/></div>',
        ),
      );
    }

    return _assemble(
      chapters,
      BookMetadata(
        title: title,
        authors: authors,
        language: language.isEmpty ? null : language,
        description: description.isEmpty ? null : HtmlText.plain(description),
        publisher: publisher.isEmpty ? null : publisher,
        coverPath: coverPath,
        rtl: RegExp(r'^(ar|he|iw|fa|ur|yi)\b')
            .hasMatch(language.toLowerCase()),
      ),
    );
  }

  Map<int, List<Uint8List>> _parseExth(Uint8List rec0, int start) {
    final out = <int, List<Uint8List>>{};
    if (start + 12 > rec0.length ||
        String.fromCharCodes(rec0.sublist(start, start + 4)) != 'EXTH') {
      return out;
    }
    final n = _u32(rec0, start + 8);
    var pos = start + 12;
    for (var i = 0; i < n && pos + 8 <= rec0.length; i++) {
      final type = _u32(rec0, pos);
      final len = _u32(rec0, pos + 4);
      if (len < 8 || pos + len > rec0.length) break;
      out
          .putIfAbsent(type, () => [])
          .add(Uint8List.sublistView(rec0, pos + 8, pos + len));
      pos += len;
    }
    return out;
  }

  /// Size of the trailing entries appended to a text record.
  static int _trailingSize(Uint8List rec, int flags) {
    var size = 0;
    var f = flags >> 1;
    while (f != 0) {
      if ((f & 1) != 0) {
        final end = rec.length - size;
        var value = 0;
        for (var i = math.max(0, end - 4); i < end; i++) {
          final v = rec[i];
          if ((v & 0x80) != 0) value = 0;
          value = (value << 7) | (v & 0x7F);
        }
        size += value;
        if (size > rec.length) return rec.length;
      }
      f >>= 1;
    }
    if ((flags & 1) != 0) {
      final pos = rec.length - size - 1;
      if (pos >= 0) size += (rec[pos] & 0x3) + 1;
    }
    return size;
  }

  /// PalmDOC LZ77 decompression.
  static Uint8List _palmDocDecompress(Uint8List src) {
    var out = Uint8List(math.max(4096, src.length * 2));
    var n = 0;
    void ensure(int extra) {
      if (n + extra <= out.length) return;
      final grown = Uint8List(math.max(out.length * 2, n + extra));
      grown.setRange(0, n, out);
      out = grown;
    }

    var i = 0;
    while (i < src.length) {
      final c = src[i++];
      if (c >= 1 && c <= 8) {
        ensure(c);
        for (var j = 0; j < c && i < src.length; j++) {
          out[n++] = src[i++];
        }
      } else if (c < 0x80) {
        ensure(1);
        out[n++] = c;
      } else if (c >= 0xC0) {
        ensure(2);
        out[n++] = 0x20;
        out[n++] = c ^ 0x80;
      } else {
        if (i >= src.length) break;
        final pair = (c << 8) | src[i++];
        final distance = (pair >> 3) & 0x07FF;
        final length = (pair & 0x07) + 3;
        if (distance == 0 || distance > n) continue;
        ensure(length);
        for (var j = 0; j < length; j++) {
          out[n] = out[n - distance];
          n++;
        }
      }
    }
    return Uint8List.sublistView(out, 0, n);
  }

  String? _imagePath(int firstImage, int recIndex) {
    final path0 = 'images/$recIndex';
    for (final ext in const ['jpg', 'gif', 'png', 'bmp']) {
      if (resources.containsKey('$path0.$ext')) return '$path0.$ext';
    }
    final rec = record(firstImage + recIndex - 1);
    final ext = _imageExt(rec);
    if (ext == null) return null;
    final path = '$path0.$ext';
    resources[path] = rec;
    return path;
  }

  static String? _imageExt(Uint8List b) {
    if (b.length < 4) return null;
    if (b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'png';
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
    if (b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
    return null;
  }

  // ---------------------------------------------------------------- MOBI 6

  List<_MobiChapter> _mobi6Chapters(
    Uint8List raw,
    int firstImage,
    bool utf8Text,
  ) {
    // Work on a byte-preserving string so filepos offsets stay valid.
    final s = latin1.decode(raw);
    final positions = <int>{};
    final fileposAttr =
        RegExp(r'''filepos\s*=\s*["']?0*(\d+)''', caseSensitive: false);
    for (final m in fileposAttr.allMatches(s)) {
      final pos = int.tryParse(m.group(1)!);
      if (pos != null && pos < s.length) positions.add(pos);
    }
    final sorted = positions.toList()..sort();
    final withAnchors = StringBuffer();
    var last = 0;
    for (final orig in sorted) {
      var pos = orig;
      final lt = s.lastIndexOf('<', pos == 0 ? 0 : pos - 1);
      final gt = s.lastIndexOf('>', pos == 0 ? 0 : pos - 1);
      if (lt > gt && lt >= last) pos = lt;
      if (pos < last) pos = last;
      withAnchors
        ..write(s.substring(last, pos))
        ..write('<a id="filepos$orig"></a>');
      last = pos;
    }
    withAnchors.write(s.substring(last));
    var html = withAnchors.toString();

    // Guide TOC reference, before the guide is removed.
    int? tocFilepos;
    final tocRef = RegExp(
      r'''<reference\b[^>]*type\s*=\s*["']?toc["']?[^>]*>''',
      caseSensitive: false,
    ).firstMatch(html);
    if (tocRef != null) {
      final m = fileposAttr.firstMatch(tocRef.group(0)!);
      if (m != null) tocFilepos = int.tryParse(m.group(1)!);
    }

    html = html
        .replaceAll(
          RegExp(r'<guide\b[\s\S]*?</guide\s*>', caseSensitive: false),
          '',
        )
        .replaceAllMapped(
          RegExp(
            r'''<a\b([^>]*?)\sfilepos\s*=\s*["']?0*(\d+)["']?''',
            caseSensitive: false,
          ),
          (m) => '<a${m.group(1)} href="#filepos${m.group(2)}"',
        )
        .replaceAllMapped(
          RegExp(
            r'''<img\b([^>]*?)\srecindex\s*=\s*["']?(\d+)["']?''',
            caseSensitive: false,
          ),
          (m) {
            final idx = int.tryParse(m.group(2)!) ?? 0;
            final path = firstImage == 0xFFFFFFFF || idx <= 0
                ? null
                : _imagePath(firstImage, idx);
            return '<img${m.group(1)} src="${path ?? ''}"';
          },
        )
        .replaceAll(
          RegExp(r'''\s(hi|lo)recindex\s*=\s*["']?\d+["']?''',
              caseSensitive: false),
          '',
        );

    // Decode now that offsets no longer matter.
    final bytes = latin1.encode(html);
    var text = utf8Text
        ? utf8.decode(bytes, allowMalformed: true)
        : TextCodec.decodeCp1252(bytes);

    final bodyOpen =
        RegExp(r'<body\b[^>]*>', caseSensitive: false).firstMatch(text);
    if (bodyOpen != null) text = text.substring(bodyOpen.end);
    final bodyClose = text.toLowerCase().lastIndexOf('</body');
    if (bodyClose >= 0) text = text.substring(0, bodyClose);
    text = text.replaceAll(
      RegExp(r'<head\b[\s\S]*?</head\s*>', caseSensitive: false),
      '',
    );

    var parts = text.split(
      RegExp(r'<mbp:pagebreak\b[^>]*>(\s*</mbp:pagebreak\s*>)?',
          caseSensitive: false),
    );
    parts = [
      for (final p in parts)
        p.replaceAll(RegExp(r'</?mbp:[^>]*>', caseSensitive: false), ''),
    ];
    parts = _mergeAndSplit(parts);

    final chapters = <_MobiChapter>[];
    for (var i = 0; i < parts.length; i++) {
      chapters.add(_MobiChapter(
        HtmlText.guessTitle(parts[i]) ?? 'Section ${i + 1}',
        parts[i],
      ));
    }
    _tocFilepos = tocFilepos;
    return chapters;
  }

  int? _tocFilepos;

  /// Drops empty parts and splits huge ones at paragraph boundaries.
  static List<String> _mergeAndSplit(List<String> parts) {
    final out = <String>[];
    var carry = '';
    for (final p in parts) {
      final hasContent = p.contains(RegExp(r'<img\b', caseSensitive: false)) ||
          HtmlText.plain(p).isNotEmpty;
      if (!hasContent) {
        carry += p;
        continue;
      }
      out.add(carry + p);
      carry = '';
    }
    if (carry.isNotEmpty) {
      if (out.isEmpty) {
        out.add(carry);
      } else {
        out[out.length - 1] += carry;
      }
    }
    const maxSize = 250000;
    final result = <String>[];
    for (final p in out) {
      if (p.length <= maxSize) {
        result.add(p);
        continue;
      }
      var start = 0;
      while (p.length - start > maxSize) {
        var cut = p.indexOf(
          RegExp(r'<(p|div|h[1-6])\b', caseSensitive: false),
          start + maxSize ~/ 2,
        );
        if (cut < 0 || cut - start > maxSize * 2) break;
        result.add(p.substring(start, cut));
        start = cut;
      }
      result.add(p.substring(start));
    }
    return result.isEmpty ? [''] : result;
  }

  // ------------------------------------------------------------------ KF8

  List<_MobiChapter> _kf8Chapters(
    Uint8List raw,
    Uint8List rec0,
    int firstResource,
    bool utf8Text,
  ) {
    // Flow table (FDST): flow 0 is the text, later flows are CSS/SVG.
    final flows = <Uint8List>[];
    final fdstIndex = _u32(rec0, 0xC0);
    if (fdstIndex > 0 && fdstIndex < offsets.length) {
      final fdst = record(fdstIndex);
      if (fdst.length >= 12 && String.fromCharCodes(fdst.sublist(0, 4)) == 'FDST') {
        final n = _u32(fdst, 8);
        for (var i = 0; i < n && 12 + i * 8 + 8 <= fdst.length; i++) {
          final start = _u32(fdst, 12 + i * 8);
          final end = _u32(fdst, 16 + i * 8);
          if (start <= end && end <= raw.length) {
            flows.add(Uint8List.sublistView(raw, start, end));
          }
        }
      }
    }
    if (flows.isEmpty) flows.add(raw);

    String decode(Uint8List b) => utf8Text
        ? utf8.decode(b, allowMalformed: true)
        : TextCodec.decodeCp1252(b);

    for (var i = 1; i < flows.length; i++) {
      resources['flows/$i.css'] = Uint8List.fromList(
        utf8.encode(_rewriteKindleUrls(decode(flows[i]), firstResource, '../')),
      );
    }

    final text = _rewriteKindleUrls(decode(flows.first), firstResource, '');
    // Each skeleton starts a new document; fragments follow it in order.
    final starts = RegExp(r'<\?xml\b|<!DOCTYPE\b|<html\b', caseSensitive: false)
        .allMatches(text)
        .map((m) => m.start)
        .toList();
    final docs = <String>[];
    if (starts.isEmpty) {
      docs.add(text);
    } else {
      // Collapse <?xml + <!DOCTYPE + <html of the same document.
      final merged = <int>[];
      for (final s in starts) {
        if (merged.isNotEmpty && s - merged.last < 300 &&
            !text.substring(merged.last, s).toLowerCase().contains('<body')) {
          continue;
        }
        merged.add(s);
      }
      if (merged.first > 0) docs.add(text.substring(0, merged.first));
      for (var i = 0; i < merged.length; i++) {
        docs.add(text.substring(
          merged[i],
          i + 1 < merged.length ? merged[i + 1] : text.length,
        ));
      }
    }

    final chapters = <_MobiChapter>[];
    for (final d in docs) {
      // Move stylesheet links into the body so they survive the wrapper;
      // drop the skeleton's own html/head/body wrappers.
      final links = RegExp(r'<link\b[^>]*>', caseSensitive: false)
          .allMatches(d)
          .map((m) => m.group(0)!)
          .join();
      var body = d
          .replaceAll(RegExp(r'<\?xml[^>]*>'), '')
          .replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '')
          .replaceAll(
            RegExp(r'<head\b[\s\S]*?</head\s*>', caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'</?(html|body)\b[^>]*>', caseSensitive: false), '');
      if (HtmlText.plain(body).isEmpty &&
          !body.contains(RegExp(r'<(img|svg)\b', caseSensitive: false))) {
        continue;
      }
      body = links + body;
      chapters.add(_MobiChapter(
        HtmlText.guessTitle(body) ?? 'Section ${chapters.length + 1}',
        body,
      ));
    }
    if (chapters.isEmpty) {
      throw const BookOpenException(
        "This AZW3 (KF8) book's text couldn't be extracted.",
      );
    }
    return chapters;
  }

  String _rewriteKindleUrls(String s, int firstResource, String prefix) {
    return s
        .replaceAllMapped(
          RegExp(r'kindle:embed:([0-9A-Va-v]{4})(\?mime=[^"\x27)\s]*)?'),
          (m) {
            final idx = _decodeBase32(m.group(1)!);
            if (firstResource == 0xFFFFFFFF || idx <= 0) return '';
            final path = _imagePath(firstResource, idx);
            return path == null ? '' : '$prefix$path';
          },
        )
        .replaceAllMapped(
          RegExp(r'kindle:flow:([0-9A-Va-v]{4})(\?mime=[^"\x27)\s]*)?'),
          (m) => '${prefix}flows/${_decodeBase32(m.group(1)!)}.css',
        )
        .replaceAll(
          RegExp(r'''href\s*=\s*["']kindle:pos:[^"']*["']'''),
          'href="#"',
        );
  }

  static int _decodeBase32(String s) {
    var v = 0;
    for (final ch in s.toUpperCase().split('')) {
      final d = _base32.indexOf(ch);
      if (d < 0) return 0;
      v = v * 32 + d;
    }
    return v;
  }

  // ------------------------------------------------------------- PalmDOC

  (BookInfo, Map<String, Uint8List>) _palmDoc(
    int compression,
    int textLength,
    int textRecords,
    String title,
  ) {
    if (compression != 1 && compression != 2) {
      throw const BookOpenException(
        'This PalmDOC file uses an unsupported compression.',
      );
    }
    final b = BytesBuilder(copy: false);
    for (var i = 1; i <= textRecords && i < offsets.length; i++) {
      final rec = record(i);
      b.add(compression == 2 ? _palmDocDecompress(rec) : rec);
    }
    var raw = b.takeBytes();
    if (textLength > 0 && raw.length > textLength) {
      raw = Uint8List.sublistView(raw, 0, textLength);
    }
    final text = TextCodec.decode(raw, null).replaceAll('\r\n', '\n');
    final paragraphs = text.split(RegExp(r'\n\s*\n|\n(?=\s)'));
    final chapters = <_MobiChapter>[];
    final buf = StringBuffer();
    for (final p in paragraphs) {
      final t = p.trim();
      if (t.isEmpty) continue;
      buf.write('<p>${HtmlText.escape(t).replaceAll('\n', '<br/>')}</p>\n');
      if (buf.length > 120000) {
        chapters.add(_MobiChapter('Part ${chapters.length + 1}', buf.toString()));
        buf.clear();
      }
    }
    if (buf.isNotEmpty || chapters.isEmpty) {
      chapters.add(_MobiChapter('Part ${chapters.length + 1}', buf.toString()));
    }
    return _assemble(chapters, BookMetadata(title: title));
  }

  // ------------------------------------------------------------ Assembly

  static String _path(int i) =>
      'chapter-${(i + 1).toString().padLeft(3, '0')}.html';

  (BookInfo, Map<String, Uint8List>) _assemble(
    List<_MobiChapter> chapters,
    BookMetadata metadata,
  ) {
    // Anchor id → chapter, then fix cross-chapter links.
    final idToChapter = <String, int>{};
    final idPattern = RegExp(r'''\bid\s*=\s*["']([^"']+)["']''');
    for (var i = 0; i < chapters.length; i++) {
      for (final m in idPattern.allMatches(chapters[i].html)) {
        idToChapter.putIfAbsent(m.group(1)!, () => i);
      }
    }
    final hrefPattern = RegExp(r'''href\s*=\s*["']#([^"']+)["']''');
    final spine = <SpineItem>[];
    for (var i = 0; i < chapters.length; i++) {
      final body = chapters[i].html.replaceAllMapped(hrefPattern, (m) {
        final target = idToChapter[m.group(1)!];
        if (target == null || target == i) return m.group(0)!;
        return 'href="${_path(target)}#${m.group(1)}"';
      });
      final lang = metadata.language;
      final html = '<!DOCTYPE html>\n<html${lang == null ? '' : ' lang="${HtmlText.escape(lang)}"'}>'
          '<head><meta charset="utf-8"/><title>${HtmlText.escape(chapters[i].title)}</title>'
          '<link rel="stylesheet" type="text/css" href="mobi.css"/></head>'
          '<body class="mobi">$body</body></html>';
      final bytes = Uint8List.fromList(utf8.encode(html));
      resources[_path(i)] = bytes;
      spine.add(SpineItem(
        path: _path(i),
        mediaType: 'text/html',
        size: bytes.length,
        title: chapters[i].title,
      ));
    }
    resources['mobi.css'] = Uint8List.fromList(utf8.encode(_mobiCss));

    // Prefer the book's own HTML table of contents when the guide has one.
    final toc = <TocEntry>[];
    final tocPos = _tocFilepos;
    if (tocPos != null) {
      final tocChapter = idToChapter['filepos$tocPos'];
      if (tocChapter != null) {
        final html = chapters[tocChapter].html;
        final from = html.indexOf('id="filepos$tocPos"');
        final links = RegExp(
          r'''<a\b[^>]*href\s*=\s*["']#(filepos\d+)["'][^>]*>([\s\S]*?)</a\s*>''',
          caseSensitive: false,
        ).allMatches(html, math.max(0, from));
        for (final m in links) {
          final id = m.group(1)!;
          final target = idToChapter[id];
          final title = HtmlText.plain(m.group(2)!);
          if (target == null || title.isEmpty) continue;
          toc.add(TocEntry(
            title: title,
            path: _path(target),
            fragment: id,
            spineIndex: target,
          ));
        }
      }
    }
    if (toc.length < 2) {
      toc
        ..clear()
        ..addAll([
          for (var i = 0; i < chapters.length; i++)
            TocEntry(title: chapters[i].title, path: _path(i), spineIndex: i),
        ]);
    }

    return (
      BookInfo(
        format: BookFormat.mobi,
        metadata: metadata,
        spine: spine,
        toc: toc,
      ),
      resources,
    );
  }
}

class _MobiChapter {
  _MobiChapter(this.title, this.html);

  final String title;
  final String html;
}

const _mobiCss = '''
body.mobi p { margin-top: 0; margin-bottom: 0.25em; }
body.mobi img { max-width: 100%; height: auto; }
.mobi-cover { text-align: center; }
.mobi-cover img { max-height: 92vh; }
body.mobi blockquote { margin: 0.5em 1.5em; }
''';
