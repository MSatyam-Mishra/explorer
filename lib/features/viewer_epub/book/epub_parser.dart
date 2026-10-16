import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'book_models.dart';
import 'book_source.dart';
import 'document_preparer.dart';
import 'html_text.dart';
import 'sha1.dart';
import 'text_codec.dart';
import 'zip_index.dart';

const _idpfObfuscation = 'http://www.idpf.org/2008/embedding';
const _adobeObfuscation = 'http://ns.adobe.com/pdf/enc#RC';

/// Parses XML leniently: HTML5 named entities are understood, and on a
/// failure bare `&` characters are escaped before a second attempt.
XmlDocument parseXmlLenient(String text) {
  const mapping = XmlDefaultEntityMapping.html5();
  try {
    return XmlDocument.parse(text, entityMapping: mapping);
  } on XmlException {
    final fixed = text.replaceAll(
      RegExp(r'&(?!(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);)'),
      '&amp;',
    );
    return XmlDocument.parse(fixed, entityMapping: mapping);
  }
}

XmlElement? _firstChild(XmlNode parent, String localName) {
  for (final e in parent.findElements(localName, namespace: '*')) {
    return e;
  }
  for (final e in parent.findAllElements(localName, namespace: '*')) {
    return e;
  }
  return null;
}

/// Result of parsing an EPUB container in a background isolate.
class EpubPackage {
  EpubPackage({
    required this.info,
    required this.obfuscation,
    this.idpfKey,
    this.adobeKey,
  });

  final BookInfo info;

  /// Canonical resource path → `idpf` | `adobe` font obfuscation.
  final Map<String, String> obfuscation;
  final Uint8List? idpfKey;
  final Uint8List? adobeKey;

  Map<String, dynamic> toJson() => {
        'info': info.toJson(),
        'obf': obfuscation,
        if (idpfKey != null) 'idpf': base64.encode(idpfKey!),
        if (adobeKey != null) 'adobe': base64.encode(adobeKey!),
      };

  factory EpubPackage.fromJson(Map<String, dynamic> j) => EpubPackage(
        info: BookInfo.fromJson(j['info'] as Map<String, dynamic>),
        obfuscation: {
          for (final e in (j['obf'] as Map).entries)
            e.key as String: e.value as String,
        },
        idpfKey: j['idpf'] == null ? null : base64.decode(j['idpf'] as String),
        adobeKey:
            j['adobe'] == null ? null : base64.decode(j['adobe'] as String),
      );
}

/// Parsed EPUB structure cached on disk (JSON), so reopening a book skips
/// the package/TOC parsing. Keyed by path, size and modification time.
abstract final class EpubStructureCache {
  static const version = 1;

  /// Cache file for [path] in [dir].
  static String fileFor(String dir, String path, FileStat stat) {
    final key = '$version|$path|${stat.size}|'
        '${stat.modified.millisecondsSinceEpoch}';
    final hex = sha1Digest(utf8.encode(key))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$dir${Platform.pathSeparator}$hex.json';
  }

  static Map<String, dynamic> header(String path, FileStat stat) => {
        'v': version,
        'path': path,
        'size': stat.size,
        'mtime': stat.modified.millisecondsSinceEpoch,
      };

  /// Serializes a fresh parse (in a background isolate).
  static Uint8List encode(
    Map<String, dynamic> header,
    EpubPackage package,
    ZipIndex index,
  ) =>
      utf8.encode(jsonEncode({
        ...header,
        'dir': index.directoryOffset,
        'count': index.entries.length,
        ...package.toJson(),
      }));

  /// Restores a cached parse, or null if it doesn't match this exact file.
  static EpubPackage? decode(
    Uint8List bytes,
    Map<String, dynamic> header,
    ZipIndex index,
  ) {
    try {
      final j = utf8.decoder.fuse(json.decoder).convert(bytes);
      if (j is! Map<String, dynamic>) return null;
      for (final e in header.entries) {
        if (j[e.key] != e.value) return null;
      }
      if (index.directoryOffset < 0 ||
          j['dir'] != index.directoryOffset ||
          j['count'] != index.entries.length) {
        return null;
      }
      final package = EpubPackage.fromJson(j);
      for (final s in package.info.spine) {
        if (index.entries[s.path] == null) return null;
      }
      return package;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the cache directory from growing without bound.
  static Future<void> prune(Directory dir, {int max = 300, int keep = 200}) async {
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) files.add(e);
    }
    if (files.length <= max) return;
    final dated = <(File, DateTime)>[];
    for (final f in files) {
      try {
        dated.add((f, (await f.stat()).modified));
      } catch (_) {}
    }
    dated.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _) in dated.take(dated.length - keep)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}

class _ManifestItem {
  _ManifestItem(this.id, this.path, this.mediaType, this.properties,
      this.fallback);

  final String id;
  final String path;
  final String mediaType;
  final Set<String> properties;
  final String? fallback;
}

/// EPUB 2/3 book backed by the ZIP file on disk.
class EpubBookSource extends BookSource {
  EpubBookSource._(this.filePath, this._package, this._index, {
    String? cacheFile,
    Map<String, dynamic>? cacheHeader,
  })  : _reader = ZipAsyncReader(filePath),
        _cacheFile = cacheFile,
        _cacheHeader = cacheHeader;

  final String filePath;
  final EpubPackage _package;
  final ZipIndex _index;
  final ZipAsyncReader _reader;
  final String? _cacheFile;

  /// Set while a fresh parse still has to be written to [_cacheFile].
  Map<String, dynamic>? _cacheHeader;

  /// Parses [file] as an EPUB, or restores its structure from the cache in
  /// [cacheDir] (keyed by [stat]). Returns null when the ZIP has no package
  /// document but contains an `.fb2` (zipped FictionBook).
  static Future<EpubBookSource?> tryOpen(
    File file, {
    FileStat? stat,
    String? cacheDir,
  }) async {
    final path = file.path;
    final cacheFile = stat != null && cacheDir != null
        ? EpubStructureCache.fileFor(cacheDir, path, stat)
        : null;
    final header =
        stat == null ? null : EpubStructureCache.header(path, stat);
    if (cacheFile != null) {
      final cached = await _openCached(path, cacheFile, header!);
      if (cached != null) return cached;
    }
    final result = await _parseInBackground(path);
    if (result == null) return null;
    return EpubBookSource._(
      path,
      result.$1,
      result.$2,
      cacheFile: cacheFile,
      cacheHeader: cacheFile == null ? null : header,
    );
  }

  static Future<(EpubPackage, ZipIndex)?> _parseInBackground(String path) =>
      Isolate.run(() => parseEpub(path));

  static Future<Uint8List> _encodeInBackground(
    Map<String, dynamic> header,
    EpubPackage package,
    ZipIndex index,
  ) =>
      Isolate.run(() => EpubStructureCache.encode(header, package, index));

  /// Reads the central directory and the cached structure concurrently, on
  /// this isolate (both are small); null on any mismatch.
  static Future<EpubBookSource?> _openCached(
    String path,
    String cacheFile,
    Map<String, dynamic> header,
  ) async {
    final bytesFuture = File(cacheFile)
        .readAsBytes()
        .then<Uint8List?>((b) => b, onError: (_) => null);
    ZipIndex? index;
    try {
      final raf = await File(path).open();
      try {
        index = await ZipIndex.readAsync(raf);
      } finally {
        await raf.close();
      }
    } catch (_) {
      index = null;
    }
    final bytes = await bytesFuture;
    if (bytes == null || index == null) return null;
    final idx = index;
    final package = bytes.length > 256 * 1024
        ? await _decodeInBackground(bytes, header, idx)
        : EpubStructureCache.decode(bytes, header, idx);
    if (package == null) return null;
    return EpubBookSource._(path, package, idx, cacheFile: cacheFile);
  }

  static Future<EpubPackage?> _decodeInBackground(
    Uint8List bytes,
    Map<String, dynamic> header,
    ZipIndex index,
  ) =>
      Isolate.run(() => EpubStructureCache.decode(bytes, header, index));

  @override
  Future<void> saveCache() async {
    final file = _cacheFile;
    if (file == null) return;
    final header = _cacheHeader;
    _cacheHeader = null;
    try {
      if (header == null) {
        // Restored from the cache: mark it recently used.
        await File(file).setLastModified(DateTime.now());
        return;
      }
      // Encoded off this isolate, and only once the book is on screen.
      final bytes = await _encodeInBackground(header, _package, _index);
      final dir = File(file).parent;
      await dir.create(recursive: true);
      final tmp = File('$file.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file);
      await EpubStructureCache.prune(dir);
    } catch (_) {
      // The cache is an optimization only.
    }
  }

  @override
  Future<PreparedDocument> prepare(
    String path,
    DocumentPrepareRequest options,
  ) {
    final entry = _index.find(path);
    if (entry == null ||
        entry.size < BookSource.inlinePrepareLimit ||
        _package.obfuscation.containsKey(entry.name)) {
      return super.prepare(path, options);
    }
    // Read, inflate and prepare in one background isolate: nothing big is
    // read on, or copied from, this isolate.
    return _prepareFromFile(filePath, entry, options);
  }

  static Future<PreparedDocument> _prepareFromFile(
    String file,
    ZipEntryInfo entry,
    DocumentPrepareRequest options,
  ) =>
      Isolate.run(() {
        final reader = ZipSyncReader(file);
        try {
          return prepareDocument(options.withBytes(reader.read(entry)));
        } finally {
          reader.close();
        }
      });

  @override
  BookInfo get info => _package.info;

  @override
  String? canonicalPath(String path) => _index.canonical(path);

  @override
  Iterable<String> get resourcePaths => _index.names;

  @override
  Future<Uint8List?> readResource(String path) async {
    final entry = _index.find(path);
    if (entry == null) return null;
    final bytes = await _reader.read(entry);
    final algorithm = _package.obfuscation[entry.name];
    if (algorithm == 'idpf' && _package.idpfKey != null) {
      _xor(bytes, _package.idpfKey!, 1040);
    } else if (algorithm == 'adobe' && _package.adobeKey != null) {
      _xor(bytes, _package.adobeKey!, 1024);
    }
    return bytes;
  }

  static void _xor(Uint8List data, Uint8List key, int count) {
    final n = math.min(count, data.length);
    for (var i = 0; i < n; i++) {
      data[i] ^= key[i % key.length];
    }
  }

  @override
  Future<List<SearchHit>> search(String query, {int maxResults = 500}) =>
      _searchInBackground(
        filePath,
        [for (final s in info.spine) s.path],
        query,
        maxResults,
      );

  static Future<List<SearchHit>> _searchInBackground(
    String path,
    List<String> spine,
    String query,
    int maxResults,
  ) =>
      Isolate.run(() => searchEpubFile(path, spine, query, maxResults));

  @override
  Future<void> dispose() => _reader.close();
}

/// Searches the spine documents of the EPUB at [path] (background isolate).
List<SearchHit> searchEpubFile(
  String path,
  List<String> spine,
  String query,
  int maxResults,
) {
  final index = ZipIndex.read(path);
  final reader = ZipSyncReader(path);
  try {
    final hits = <SearchHit>[];
    for (var i = 0; i < spine.length && hits.length < maxResults; i++) {
      final entry = index.find(spine[i]);
      if (entry == null) continue;
      Uint8List bytes;
      try {
        bytes = reader.read(entry);
      } catch (_) {
        continue;
      }
      hits.addAll(HtmlText.searchDocument(
        TextCodec.decodeMarkup(bytes),
        query,
        i,
        maxHits: maxResults - hits.length,
      ));
    }
    return hits;
  } finally {
    reader.close();
  }
}

/// Parses the EPUB at [path]. Runs in a background isolate.
(EpubPackage, ZipIndex)? parseEpub(String path) {
  final index = ZipIndex.read(path);
  final reader = ZipSyncReader(path);
  try {
    return _EpubParser(index, reader).parse();
  } finally {
    reader.close();
  }
}

class _EpubParser {
  _EpubParser(this.index, this.reader);

  final ZipIndex index;
  final ZipSyncReader reader;

  Uint8List? read(String path) {
    final e = index.find(path);
    if (e == null) return null;
    try {
      return reader.read(e);
    } on BookOpenException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  String? readText(String path) {
    final b = read(path);
    return b == null ? null : TextCodec.decodeMarkup(b);
  }

  Uint8List? readHead(String path, int maxBytes) {
    final e = index.find(path);
    if (e == null) return null;
    try {
      return reader.readHead(e, maxBytes);
    } catch (_) {
      return null;
    }
  }

  (EpubPackage, ZipIndex)? parse() {
    final opfPath = _findOpf();
    if (opfPath == null) {
      if (index.names.any((n) => n.toLowerCase().endsWith('.fb2'))) {
        return null;
      }
      throw const BookOpenException(
        "This isn't a valid EPUB: its package document (content.opf) is "
        'missing.',
      );
    }

    final obfuscation = _readEncryption();

    final opfText = readText(opfPath);
    if (opfText == null) {
      throw const BookOpenException("The book's package document is unreadable.");
    }
    XmlDocument opf;
    try {
      opf = parseXmlLenient(opfText);
    } catch (_) {
      throw const BookOpenException(
        "The book's package document is damaged and can't be read.",
      );
    }
    final opfDir = BookPaths.dirname(opfPath);
    final pkg = opf.rootElement;
    final metadataEl = _firstChild(pkg, 'metadata') ?? pkg;

    String? dc(String name) {
      for (final e in metadataEl.findAllElements(name, namespace: '*')) {
        final t = HtmlText.collapse(e.innerText);
        if (t.isNotEmpty) return t;
      }
      return null;
    }

    final authors = <String>[];
    for (final e in metadataEl.findAllElements('creator', namespace: '*')) {
      final t = HtmlText.collapse(e.innerText);
      if (t.isNotEmpty && !authors.contains(t)) authors.add(t);
    }

    final uidId = pkg.getAttribute('unique-identifier');
    String? uniqueId;
    final identifiers = <String>[];
    for (final e in metadataEl.findAllElements('identifier', namespace: '*')) {
      final t = e.innerText.trim();
      if (t.isEmpty) continue;
      identifiers.add(t);
      if (uidId != null && e.getAttribute('id') == uidId) uniqueId = t;
    }
    uniqueId ??= identifiers.isEmpty ? null : identifiers.first;

    String? coverId;
    var fixedLayout = false;
    for (final m in metadataEl.findAllElements('meta', namespace: '*')) {
      if (m.getAttribute('name') == 'cover') coverId = m.getAttribute('content');
      if (m.getAttribute('property') == 'rendition:layout' &&
          m.innerText.trim() == 'pre-paginated') {
        fixedLayout = true;
      }
    }
    if (!fixedLayout) {
      final apple =
          readText('META-INF/com.apple.ibooks.display-options.xml') ?? '';
      if (RegExp(r'name="fixed-layout"\s*>\s*true').hasMatch(apple)) {
        fixedLayout = true;
      }
    }

    // Manifest.
    final items = <String, _ManifestItem>{};
    final manifestEl = _firstChild(pkg, 'manifest');
    if (manifestEl != null) {
      for (final el in manifestEl.findElements('item', namespace: '*')) {
        final id = el.getAttribute('id');
        final href = el.getAttribute('href');
        if (id == null || href == null) continue;
        final resolved = BookPaths.resolve(opfDir, href);
        if (resolved == null) continue;
        items[id] = _ManifestItem(
          id,
          index.canonical(resolved) ?? resolved,
          (el.getAttribute('media-type') ?? '').toLowerCase().trim(),
          (el.getAttribute('properties') ?? '')
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .toSet(),
          el.getAttribute('fallback'),
        );
      }
    }

    // Spine.
    final spineEl = _firstChild(pkg, 'spine');
    final ppd = spineEl?.getAttribute('page-progression-direction');
    final spine = <SpineItem>[];
    if (spineEl != null) {
      for (final ref in spineEl.findElements('itemref', namespace: '*')) {
        var item = items[ref.getAttribute('idref') ?? ''];
        if (item == null) continue;
        var guard = 0;
        while (!_isContentDocument(item!.mediaType, item.path) &&
            item.fallback != null &&
            items[item.fallback] != null &&
            guard++ < 6) {
          item = items[item.fallback];
        }
        final entry = index.find(item.path);
        if (entry == null) continue;
        final props = ref.getAttribute('properties') ?? '';
        spine.add(SpineItem(
          path: entry.name,
          mediaType: item.mediaType,
          linear: ref.getAttribute('linear')?.trim() != 'no',
          size: math.max(1, entry.size),
          fixedLayout: props.contains('rendition:layout-pre-paginated')
              ? true
              : props.contains('rendition:layout-reflowable')
                  ? false
                  : fixedLayout,
        ));
      }
    }
    if (spine.isEmpty) {
      for (final item in items.values) {
        if (!item.mediaType.contains('html') || item.properties.contains('nav')) {
          continue;
        }
        final entry = index.find(item.path);
        if (entry == null) continue;
        spine.add(SpineItem(
          path: entry.name,
          mediaType: item.mediaType,
          size: math.max(1, entry.size),
          fixedLayout: fixedLayout,
        ));
      }
    }
    if (spine.isEmpty) {
      throw const BookOpenException('This book has no readable content.');
    }

    final spineByPath = <String, int>{};
    for (var i = 0; i < spine.length; i++) {
      spineByPath.putIfAbsent(spine[i].path.toLowerCase(), () => i);
    }

    // Table of contents: EPUB 3 nav, then EPUB 2 NCX, then the spine.
    var toc = <TocEntry>[];
    _ManifestItem? navItem;
    for (final i in items.values) {
      if (i.properties.contains('nav')) {
        navItem = i;
        break;
      }
    }
    if (navItem != null) {
      final text = readText(navItem.path);
      if (text != null) toc = _parseNav(text, navItem.path);
    }
    if (!_resolveToc(toc, spineByPath)) {
      _ManifestItem? ncx = items[spineEl?.getAttribute('toc') ?? ''];
      if (ncx == null) {
        for (final i in items.values) {
          if (i.mediaType == 'application/x-dtbncx+xml' ||
              i.path.toLowerCase().endsWith('.ncx')) {
            ncx = i;
            break;
          }
        }
      }
      if (ncx != null) {
        final text = readText(ncx.path);
        toc = text == null ? [] : _parseNcx(text, ncx.path);
      } else {
        toc = [];
      }
      if (!_resolveToc(toc, spineByPath)) toc = [];
    }

    final spineTitles = <int, String>{};
    if (toc.isEmpty) {
      for (var i = 0; i < spine.length; i++) {
        String? title;
        if (spine.length <= 400 && spine[i].mediaType.contains('html')) {
          // Only the start of each document: titles are near the top.
          final head = readHead(spine[i].path, 64 * 1024);
          if (head != null) {
            title = HtmlText.guessTitle(TextCodec.decodeMarkup(head));
          }
        }
        title ??= 'Section ${i + 1}';
        spineTitles[i] = title;
        if (!spine[i].linear && spine.length > 1) continue;
        toc.add(TocEntry(title: title, path: spine[i].path, spineIndex: i));
      }
    }

    // Cover.
    String? cover;
    for (final i in items.values) {
      if (i.properties.contains('cover-image')) {
        cover = i.path;
        break;
      }
    }
    if (cover == null && coverId != null) {
      cover = items[coverId]?.path ??
          index.canonical(BookPaths.resolve(opfDir, coverId) ?? '');
    }
    if (cover == null) {
      for (final i in items.values) {
        if (i.mediaType.startsWith('image/') &&
            (i.id.toLowerCase().contains('cover') ||
                i.path.toLowerCase().contains('cover'))) {
          cover = i.path;
          break;
        }
      }
    }
    if (cover != null && index.find(cover) == null) cover = null;

    // Obfuscation keys.
    Uint8List? idpfKey;
    Uint8List? adobeKey;
    if (obfuscation.isNotEmpty) {
      if (uniqueId != null) {
        idpfKey = sha1Digest(
          utf8.encode(uniqueId.replaceAll(RegExp(r'[\x20\x09\x0d\x0a]'), '')),
        );
      }
      for (final id in identifiers) {
        final hex = id
            .replaceFirst(RegExp(r'^urn:uuid:', caseSensitive: false), '')
            .replaceAll('-', '')
            .trim();
        if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
          adobeKey = Uint8List.fromList([
            for (var i = 0; i < 32; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16),
          ]);
          break;
        }
      }
    }

    final finalSpine = spineTitles.isEmpty
        ? spine
        : [
            for (var i = 0; i < spine.length; i++)
              SpineItem(
                path: spine[i].path,
                mediaType: spine[i].mediaType,
                linear: spine[i].linear,
                size: spine[i].size,
                fixedLayout: spine[i].fixedLayout,
                title: spineTitles[i],
              ),
          ];

    final info = BookInfo(
      format: BookFormat.epub,
      metadata: BookMetadata(
        title: dc('title') ??
            BookPaths.basename(opfPath).replaceAll(RegExp(r'\.opf$'), ''),
        authors: authors,
        language: dc('language'),
        publisher: dc('publisher'),
        description: () {
          final d = dc('description');
          return d == null ? null : HtmlText.plain(d);
        }(),
        identifier: uniqueId,
        coverPath: cover,
        rtl: ppd == 'rtl',
        fixedLayout: fixedLayout,
      ),
      spine: finalSpine,
      toc: toc,
    );
    return (
      EpubPackage(
        info: info,
        obfuscation: obfuscation,
        idpfKey: idpfKey,
        adobeKey: adobeKey,
      ),
      index,
    );
  }

  String? _findOpf() {
    final container = readText('META-INF/container.xml');
    if (container != null) {
      try {
        final doc = parseXmlLenient(container);
        for (final rf in doc.findAllElements('rootfile', namespace: '*')) {
          final type = rf.getAttribute('media-type');
          final fullPath = rf.getAttribute('full-path');
          if (fullPath == null) continue;
          if (type != null && !type.contains('oebps-package')) continue;
          final c = index.canonical(
            BookPaths.normalize(BookPaths.safeDecode(fullPath)),
          );
          if (c != null) return c;
        }
      } catch (_) {
        // Fall through to scanning for an .opf file.
      }
    }
    for (final name in index.names) {
      if (name.toLowerCase().endsWith('.opf')) return name;
    }
    return null;
  }

  Map<String, String> _readEncryption() {
    if (index.find('META-INF/sinf.xml') != null) {
      throw const BookOpenException(
        'This book is protected by Apple FairPlay DRM and can only be read '
        'in Apple Books.',
        retryable: false,
      );
    }
    final out = <String, String>{};
    final text = readText('META-INF/encryption.xml');
    if (text == null) return out;
    XmlDocument doc;
    try {
      doc = parseXmlLenient(text);
    } catch (_) {
      return out;
    }
    var drm = false;
    for (final ed in doc.findAllElements('EncryptedData', namespace: '*')) {
      String? algorithm;
      for (final m in ed.findAllElements('EncryptionMethod', namespace: '*')) {
        algorithm = m.getAttribute('Algorithm');
        break;
      }
      String? uri;
      for (final r in ed.findAllElements('CipherReference', namespace: '*')) {
        uri = r.getAttribute('URI');
        break;
      }
      if (uri == null) continue;
      final resolved = BookPaths.resolve('', uri);
      if (resolved == null) continue;
      final path = index.canonical(resolved) ?? resolved;
      if (algorithm == _idpfObfuscation) {
        out[path] = 'idpf';
      } else if (algorithm == _adobeObfuscation) {
        out[path] = 'adobe';
      } else {
        drm = true;
      }
    }
    if (drm) {
      final adobe = index.find('META-INF/rights.xml') != null;
      throw BookOpenException(
        adobe
            ? 'This book is protected by Adobe DRM and can only be opened in '
                'an app authorized for your Adobe ID (for example Adobe '
                'Digital Editions).'
            : 'This book is protected by DRM (digital rights management) and '
                "can't be opened here. Open it in the app or store it was "
                'purchased from.',
      );
    }
    return out;
  }

  static bool _isContentDocument(String mediaType, String path) {
    if (mediaType.contains('html') || mediaType.contains('svg')) return true;
    if (mediaType.startsWith('image/')) return false;
    final ext = BookPaths.extension(path);
    return ext == 'xhtml' || ext == 'html' || ext == 'htm' || ext == 'xml';
  }

  /// Fills in spine indices; returns true if at least one entry resolved.
  static bool _resolveToc(List<TocEntry> toc, Map<String, int> spineByPath) {
    var any = false;
    void walk(List<TocEntry> entries) {
      for (final e in entries) {
        final p = e.path;
        if (p != null) {
          e.spineIndex = spineByPath[p.toLowerCase()];
          if (e.spineIndex != null) any = true;
        }
        walk(e.children);
      }
    }

    walk(toc);
    return any;
  }

  List<TocEntry> _parseNav(String markup, String navPath) {
    XmlDocument doc;
    try {
      doc = parseXmlLenient(markup);
    } catch (_) {
      return [];
    }
    XmlElement? tocNav;
    final navs = doc.findAllElements('nav', namespace: '*').toList();
    for (final n in navs) {
      final type = n.getAttribute('type', namespace: '*') ?? '';
      if (type.split(RegExp(r'\s+')).contains('toc')) {
        tocNav = n;
        break;
      }
    }
    tocNav ??= navs.isEmpty ? null : navs.first;
    if (tocNav == null) return [];
    final ol = _firstChild(tocNav, 'ol');
    return ol == null ? [] : _parseOl(ol, navPath);
  }

  List<TocEntry> _parseOl(XmlElement ol, String docPath) {
    final out = <TocEntry>[];
    for (final li in ol.findElements('li', namespace: '*')) {
      XmlElement? label;
      for (final child in li.childElements) {
        final n = child.name.local;
        if (n == 'a' || n == 'span') {
          label = child;
          break;
        }
      }
      var title = label == null ? '' : HtmlText.collapse(label.innerText);
      if (title.isEmpty && label != null) {
        title = label.getAttribute('title') ??
            _firstChild(label, 'img')?.getAttribute('alt') ??
            '';
      }
      final href = label?.name.local == 'a' ? label!.getAttribute('href') : null;
      XmlElement? childOl;
      for (final c in li.childElements) {
        if (c.name.local == 'ol') {
          childOl = c;
          break;
        }
      }
      final children =
          childOl == null ? <TocEntry>[] : _parseOl(childOl, docPath);
      if (title.isEmpty && href == null && children.isEmpty) continue;
      out.add(_entry(title, href, docPath, children));
    }
    return out;
  }

  List<TocEntry> _parseNcx(String markup, String ncxPath) {
    XmlDocument doc;
    try {
      doc = parseXmlLenient(markup);
    } catch (_) {
      return [];
    }
    final navMap = _firstChild(doc.rootElement, 'navMap');
    if (navMap == null) return [];

    List<TocEntry> points(XmlElement parent) {
      final out = <TocEntry>[];
      for (final np in parent.findElements('navPoint', namespace: '*')) {
        var title = '';
        final label = _firstChild(np, 'navLabel');
        if (label != null) title = HtmlText.collapse(label.innerText);
        String? src;
        for (final c in np.findElements('content', namespace: '*')) {
          src = c.getAttribute('src');
          break;
        }
        out.add(_entry(title, src, ncxPath, points(np)));
      }
      return out;
    }

    return points(navMap);
  }

  TocEntry _entry(
    String title,
    String? href,
    String docPath,
    List<TocEntry> children,
  ) {
    String? path;
    String? fragment;
    if (href != null && href.trim().isNotEmpty) {
      final (raw, frag) = BookPaths.splitHref(href.trim());
      fragment = frag;
      if (raw.isEmpty) {
        path = docPath;
      } else {
        final resolved = BookPaths.resolve(BookPaths.dirname(docPath), raw);
        if (resolved != null) path = index.canonical(resolved) ?? resolved;
      }
    }
    return TocEntry(
      title: title.isEmpty ? 'Untitled' : title,
      path: path,
      fragment: fragment,
      children: children,
    );
  }
}
