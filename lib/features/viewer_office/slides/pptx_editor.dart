import 'package:xml/xml.dart';

import '../common/office_package.dart';
import '../common/office_xml.dart';

const _relSlide =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide';
const _ctSlide =
    'application/vnd.openxmlformats-officedocument.presentationml.slide+xml';
const _ctNotes =
    'application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml';

/// Edits a PPTX package in memory, keeping every unrelated part intact.
///
/// Slides are addressed by their relationship id in
/// `presentation.xml.rels` (stable across reorders).
class PptxEditor {
  PptxEditor(this.pkg) : presPart = pkg.mainPart() ?? 'ppt/presentation.xml';

  final OfficePackage pkg;
  final String presPart;

  static String? _local(XmlNode? n) => n is XmlElement ? n.name.local : null;

  XmlDocument _xml(String part) {
    final d = pkg.xml(part);
    if (d == null) throw StateError('Missing part $part');
    return d;
  }

  void _save(String part, XmlDocument doc) =>
      pkg.putText(part, doc.toXmlString());

  String? slidePartFor(String relId) {
    final rel = pkg.relMap(presPart)[relId];
    return rel == null ? null : OfficePackage.resolve(presPart, rel.target);
  }

  // ---------------------------------------------------------------------------
  // Text

  /// Current paragraphs of a shape's text, with line breaks as U+2028.
  List<String>? shapeParagraphs(String slidePart, String shapeId) {
    final doc = pkg.xml(slidePart);
    final sp = doc == null ? null : _findShape(doc, shapeId);
    final body = Ox.child(sp, 'txBody');
    if (body == null) return null;
    return [for (final p in Ox.children(body, 'p')) _paraText(p)];
  }

  /// Replaces the text of shape [shapeId], one entry per paragraph.
  /// Unchanged paragraphs keep their markup; changed ones keep the
  /// formatting of the runs around the edit.
  bool setShapeText(String slidePart, String shapeId, List<String> paragraphs) {
    final doc = _xml(slidePart);
    final sp = _findShape(doc, shapeId);
    final body = Ox.child(sp, 'txBody');
    if (body == null) return false;
    final paras = Ox.children(body, 'p').toList();
    final newTexts = paragraphs.isEmpty ? [''] : paragraphs;
    if (paras.isEmpty) {
      final prefix = body.name.prefix;
      final p = XmlElement(
        XmlName('p', prefix == null || prefix.isEmpty ? 'a' : 'a'),
      );
      body.children.add(p);
      paras.add(p);
    }
    for (var i = 0; i < newTexts.length; i++) {
      XmlElement p;
      if (i < paras.length) {
        p = paras[i];
      } else {
        p = paras.last.copy();
        p.children.removeWhere(
          (n) =>
              n is XmlElement &&
              const {'r', 'br', 'fld'}.contains(n.name.local),
        );
        final at = body.children.indexOf(paras.last);
        body.children.insert(at + 1, p);
        paras.add(p);
      }
      if (_paraText(p) != newTexts[i]) _rewrite(p, newTexts[i]);
    }
    for (var i = paras.length - 1; i >= newTexts.length; i--) {
      body.children.remove(paras[i]);
    }
    _save(slidePart, doc);
    return true;
  }

  XmlElement? _findShape(XmlDocument doc, String shapeId) {
    for (final e in doc.descendants.whereType<XmlElement>()) {
      if (e.name.local != 'cNvPr' || Ox.attr(e, 'id') != shapeId) continue;
      final shape = e.parent?.parent;
      if (shape is XmlElement && shape.name.local == 'sp') return shape;
    }
    return null;
  }

  static String _itemText(XmlElement e) =>
      e.name.local == 'br' ? '\u2028' : (Ox.child(e, 't')?.innerText ?? '');

  static String _paraText(XmlElement p) => [
    for (final e in Ox.elements(p))
      if (const {'r', 'br', 'fld'}.contains(e.name.local)) _itemText(e),
  ].join();

  void _setT(XmlElement run, String text) {
    var t = Ox.child(run, 't');
    if (t == null) {
      t = XmlElement(XmlName('t', run.name.prefix));
      run.children.add(t);
    }
    t.children
      ..clear()
      ..add(XmlText(text));
  }

  void _rewrite(XmlElement p, String text) {
    final items = [
      for (final e in Ox.elements(p))
        if (const {'r', 'br', 'fld'}.contains(e.name.local)) e,
    ];
    final old = items.map(_itemText).join();
    var pre = 0;
    while (pre < old.length && pre < text.length && old[pre] == text[pre]) {
      pre++;
    }
    var suf = 0;
    while (suf < old.length - pre &&
        suf < text.length - pre &&
        old[old.length - 1 - suf] == text[text.length - 1 - suf]) {
      suf++;
    }
    final middle = text.substring(pre, text.length - suf);
    final cutEnd = old.length - suf;

    // Item receiving the inserted text.
    XmlElement? anchor;
    var pos = 0;
    final ranges = <(XmlElement, int, int)>[];
    for (final e in items) {
      final len = _itemText(e).length;
      ranges.add((e, pos, pos + len));
      pos += len;
    }
    for (final (e, s, end) in ranges) {
      if (e.name.local != 'br' && s <= pre && pre < end) {
        anchor = e;
        break;
      }
    }
    if (anchor == null) {
      for (final (e, _, end) in ranges.reversed) {
        if (e.name.local != 'br' && end <= pre) {
          anchor = e;
          break;
        }
      }
    }
    anchor ??= ranges
        .where((r) => r.$1.name.local != 'br')
        .map((r) => r.$1)
        .firstOrNull;
    if (anchor == null) {
      // No runs at all: create one from the paragraph-end properties.
      final prefix = p.name.prefix;
      final r = XmlElement(XmlName('r', prefix));
      final end = Ox.child(p, 'endParaRPr');
      if (end != null) {
        final rPr = end.copy();
        r.children.add(
          XmlElement(
            XmlName('rPr', prefix),
            rPr.attributes.map((a) => a.copy()),
            rPr.children.map((c) => c.copy()),
          ),
        );
      }
      _setT(r, '');
      final at = end == null ? p.children.length : p.children.indexOf(end);
      p.children.insert(at, r);
      ranges.add((r, old.length, old.length));
      anchor = r;
    }

    for (final (e, s, end) in ranges) {
      final t = _itemText(e);
      final keepBefore = s < pre
          ? t.substring(0, (pre - s).clamp(0, t.length))
          : '';
      final keepAfter = end > cutEnd
          ? t.substring((cutEnd - s).clamp(0, t.length))
          : '';
      var newText =
          keepBefore + (identical(e, anchor) ? middle : '') + keepAfter;
      if (e.name.local == 'br') {
        if (newText.isEmpty) p.children.remove(e);
        continue;
      }
      if (newText.isEmpty && !identical(e, anchor)) {
        p.children.remove(e);
        continue;
      }
      if (newText.contains('\u2028')) {
        // Split into runs separated by line breaks.
        final parts = newText.split('\u2028');
        var at = p.children.indexOf(e);
        _setT(e, parts.first);
        for (final part in parts.skip(1)) {
          final br = XmlElement(XmlName('br', e.name.prefix));
          final rPr = Ox.child(e, 'rPr');
          if (rPr != null) br.children.add(rPr.copy());
          final r = e.copy();
          _setT(r, part);
          p.children.insert(++at, br);
          p.children.insert(++at, r);
        }
        continue;
      }
      newText = newText.replaceAll('\n', ' ');
      _setT(e, newText);
    }
  }

  // ---------------------------------------------------------------------------
  // Slides

  XmlElement _sldIdLst(XmlDocument pres) {
    final l = Ox.child(pres.rootElement, 'sldIdLst');
    if (l == null) throw StateError('No slide list');
    return l;
  }

  void deleteSlide(String relId) {
    final pres = _xml(presPart);
    final list = _sldIdLst(pres);
    final sld = Ox.children(
      list,
      'sldId',
    ).where((e) => Ox.attrQ(e, 'r:id') == relId).firstOrNull;
    if (sld == null) return;
    final sldNumId = Ox.attr(sld, 'id');
    if (Ox.children(list, 'sldId').length <= 1) {
      throw StateError('A presentation needs at least one slide.');
    }
    list.children.remove(sld);
    // Other references (custom shows) to the same relationship.
    final refs = pres.descendants
        .whereType<XmlElement>()
        .where(
          (e) => e.attributes.any(
            (a) =>
                a.name.prefix == 'r' &&
                a.name.local == 'id' &&
                a.value == relId,
          ),
        )
        .toList();
    for (final e in refs) {
      e.parent?.children.remove(e);
    }
    _sectionIds(pres)
        .where((e) => Ox.attr(e, 'id') == sldNumId)
        .toList()
        .forEach((e) => e.parent?.children.remove(e));
    _save(presPart, pres);

    final slidePart = slidePartFor(relId);
    _removeRelationship(presPart, relId);
    if (slidePart == null) return;
    for (final r in pkg.rels(slidePart)) {
      if (r.kind == 'notesSlide') {
        _removePart(OfficePackage.resolve(slidePart, r.target));
      }
    }
    _removeIncomingRelationships(slidePart);
    _removePart(slidePart);
    _updateAppSlideCount();
  }

  /// Duplicates the slide and inserts the copy right after it. Returns the
  /// new relationship id.
  String duplicateSlide(String relId) {
    final slidePart = slidePartFor(relId);
    if (slidePart == null) throw StateError('Slide not found');
    final bytes = pkg.bytes(slidePart);
    if (bytes == null) throw StateError('Slide not found');
    final dir = slidePart.substring(0, slidePart.lastIndexOf('/') + 1);
    final newPart = _nextName(dir, 'slide', '.xml');
    pkg.put(newPart, bytes);
    ContentTypes.ensureOverride(
      pkg,
      newPart,
      ContentTypes.overrideFor(pkg, slidePart) ?? _ctSlide,
    );

    final relsPath = OfficePackage.relsPathFor(slidePart);
    final relsDoc = pkg.xml(relsPath);
    if (relsDoc != null) {
      final root = relsDoc.rootElement;
      for (final r in Ox.children(root, 'Relationship').toList()) {
        final type = Ox.attr(r, 'Type') ?? '';
        final target = Ox.attr(r, 'Target') ?? '';
        if (type.endsWith('/notesSlide')) {
          final notesPart = OfficePackage.resolve(slidePart, target);
          final newNotes = _duplicateNotes(notesPart, newPart);
          if (newNotes == null) {
            root.children.remove(r);
          } else {
            r.setAttribute(
              'Target',
              OfficePackage.relativeTarget(newPart, newNotes),
            );
          }
        } else if (type.toLowerCase().contains('comment')) {
          root.children.remove(r);
        }
      }
      pkg.putText(OfficePackage.relsPathFor(newPart), relsDoc.toXmlString());
    }

    final newRel = _addRelationship(
      presPart,
      _relSlide,
      OfficePackage.relativeTarget(presPart, newPart),
    );

    final pres = _xml(presPart);
    final list = _sldIdLst(pres);
    final ids = Ox.children(list, 'sldId').toList();
    final orig = ids.where((e) => Ox.attrQ(e, 'r:id') == relId).firstOrNull;
    var maxId = 255;
    for (final e in ids) {
      final v = int.tryParse(Ox.attr(e, 'id') ?? '') ?? 0;
      if (v > maxId) maxId = v;
    }
    final newId = '${maxId + 1}';
    final copy = (orig ?? ids.first).copy();
    copy.setAttribute('id', newId);
    for (final a in copy.attributes) {
      if (a.name.local == 'id' && a.name.prefix == 'r') a.value = newRel;
    }
    final at = orig == null
        ? list.children.length
        : list.children.indexOf(orig) + 1;
    list.children.insert(at, copy);
    // Keep the copy in the same section.
    final origId = Ox.attr(orig, 'id');
    for (final s in _sectionIds(pres).toList()) {
      if (Ox.attr(s, 'id') == origId) {
        final c = s.copy()..setAttribute('id', newId);
        final parent = s.parent!;
        parent.children.insert(parent.children.indexOf(s) + 1, c);
      }
    }
    _save(presPart, pres);
    _updateAppSlideCount();
    return newRel;
  }

  String? _duplicateNotes(String notesPart, String newSlidePart) {
    final bytes = pkg.bytes(notesPart);
    if (bytes == null) return null;
    final dir = notesPart.substring(0, notesPart.lastIndexOf('/') + 1);
    final newNotes = _nextName(dir, 'notesSlide', '.xml');
    pkg.put(newNotes, bytes);
    ContentTypes.ensureOverride(
      pkg,
      newNotes,
      ContentTypes.overrideFor(pkg, notesPart) ?? _ctNotes,
    );
    final rels = pkg.xml(OfficePackage.relsPathFor(notesPart));
    if (rels != null) {
      for (final r in Ox.children(rels.rootElement, 'Relationship')) {
        if ((Ox.attr(r, 'Type') ?? '').endsWith('/slide')) {
          r.setAttribute(
            'Target',
            OfficePackage.relativeTarget(newNotes, newSlidePart),
          );
        }
      }
      pkg.putText(OfficePackage.relsPathFor(newNotes), rels.toXmlString());
    }
    return newNotes;
  }

  /// Moves the slide at [from] to position [to] (0-based, after removal).
  void moveSlide(int from, int to) {
    final pres = _xml(presPart);
    final list = _sldIdLst(pres);
    final ids = Ox.children(list, 'sldId').toList();
    if (from < 0 ||
        from >= ids.length ||
        to < 0 ||
        to >= ids.length ||
        from == to) {
      return;
    }
    final moving = ids.removeAt(from);
    ids.insert(to, moving);
    list.children.removeWhere(
      (n) => n is XmlElement && n.name.local == 'sldId',
    );
    list.children.addAll(ids);
    _fixSections(pres, [for (final e in ids) Ox.attr(e, 'id') ?? '']);
    _save(presPart, pres);
  }

  // ---------------------------------------------------------------------------
  // Helpers

  Iterable<XmlElement> _sectionIds(XmlDocument pres) =>
      pres.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'sldId' && _local(e.parent?.parent) == 'section',
      );

  /// Reorders section membership to follow the new slide order; drops the
  /// section list when a section would no longer be contiguous.
  void _fixSections(XmlDocument pres, List<String> order) {
    final sections = pres.descendants
        .whereType<XmlElement>()
        .where(
          (e) => e.name.local == 'section' && _local(e.parent) == 'sectionLst',
        )
        .toList();
    if (sections.isEmpty) return;
    final owner = <String, XmlElement>{};
    for (final s in sections) {
      for (final id in Ox.descendants(s, 'sldId')) {
        owner[Ox.attr(id, 'id') ?? ''] = s;
      }
    }
    final seen = <XmlElement>[];
    for (final id in order) {
      final s = owner[id];
      if (s == null) continue;
      if (seen.isEmpty || !identical(seen.last, s)) {
        if (seen.contains(s)) {
          // Non-contiguous: remove the whole section list extension.
          final lst = sections.first.parent!;
          final ext = lst.parent;
          if (ext != null && _local(ext) == 'ext') {
            ext.parent?.children.remove(ext);
          } else {
            lst.parent?.children.remove(lst);
          }
          return;
        }
        seen.add(s);
      }
    }
    // Contiguous: reorder each section's ids and the sections themselves.
    for (final s in sections) {
      final lst = Ox.child(s, 'sldIdLst');
      if (lst == null) continue;
      final ids = Ox.children(lst, 'sldId').toList()
        ..sort(
          (a, b) => order
              .indexOf(Ox.attr(a, 'id') ?? '')
              .compareTo(order.indexOf(Ox.attr(b, 'id') ?? '')),
        );
      lst.children.removeWhere(
        (n) => n is XmlElement && n.name.local == 'sldId',
      );
      lst.children.addAll(ids);
    }
    final parent = sections.first.parent!;
    final ordered = [
      ...seen,
      for (final s in sections)
        if (!seen.contains(s)) s,
    ];
    parent.children.removeWhere(
      (n) => n is XmlElement && n.name.local == 'section',
    );
    parent.children.addAll(ordered);
  }

  String _nextName(String dir, String stem, String ext) {
    var max = 0;
    final re = RegExp(
      '^${RegExp.escape(dir)}${RegExp.escape(stem)}(\\d+)${RegExp.escape(ext)}\$',
    );
    for (final n in pkg.order) {
      final m = re.firstMatch(n);
      if (m != null) {
        final v = int.parse(m.group(1)!);
        if (v > max) max = v;
      }
    }
    return '$dir$stem${max + 1}$ext';
  }

  String _addRelationship(String sourcePart, String type, String target) {
    final path = OfficePackage.relsPathFor(sourcePart);
    final doc = _xml(path);
    final root = doc.rootElement;
    var max = 0;
    for (final r in Ox.children(root, 'Relationship')) {
      final m = RegExp(r'(\d+)$').firstMatch(Ox.attr(r, 'Id') ?? '');
      if (m != null) {
        final v = int.parse(m.group(1)!);
        if (v > max) max = v;
      }
    }
    final id = 'rId${max + 1}';
    final template = Ox.children(root, 'Relationship').firstOrNull;
    final el = template != null
        ? template.copy()
        : XmlElement(XmlName('Relationship'));
    el.attributes.removeWhere((a) => a.name.local == 'TargetMode');
    el
      ..setAttribute('Id', id)
      ..setAttribute('Type', type)
      ..setAttribute('Target', target);
    root.children.add(el);
    _save(path, doc);
    return id;
  }

  void _removeRelationship(String sourcePart, String relId) {
    final path = OfficePackage.relsPathFor(sourcePart);
    final doc = pkg.xml(path);
    if (doc == null) return;
    doc.rootElement.children.removeWhere(
      (n) =>
          n is XmlElement &&
          n.name.local == 'Relationship' &&
          Ox.attr(n, 'Id') == relId,
    );
    _save(path, doc);
  }

  /// Drops relationships (and the elements using them) that point at
  /// [part] from any other part.
  void _removeIncomingRelationships(String part) {
    for (final relsPath
        in pkg.order.where((n) => n.endsWith('.rels')).toList()) {
      final doc = pkg.xml(relsPath);
      if (doc == null) continue;
      final source = _sourceOfRels(relsPath);
      final removed = <String>[];
      for (final r in Ox.children(doc.rootElement, 'Relationship').toList()) {
        if ((Ox.attr(r, 'TargetMode') ?? '') == 'External') continue;
        final target = OfficePackage.resolve(
          source,
          Ox.attr(r, 'Target') ?? '',
        );
        if (target == part) {
          doc.rootElement.children.remove(r);
          removed.add(Ox.attr(r, 'Id') ?? '');
        }
      }
      if (removed.isEmpty) continue;
      _save(relsPath, doc);
      final src = pkg.xml(source);
      if (src == null) continue;
      final users = src.descendants
          .whereType<XmlElement>()
          .where(
            (e) => e.attributes.any(
              (a) => a.name.prefix == 'r' && removed.contains(a.value),
            ),
          )
          .toList();
      for (final e in users) {
        e.parent?.children.remove(e);
      }
      _save(source, src);
    }
  }

  static String _sourceOfRels(String relsPath) {
    // dir/_rels/file.rels → dir/file
    final i = relsPath.lastIndexOf('_rels/');
    final dir = relsPath.substring(0, i);
    final file = relsPath.substring(i + 6, relsPath.length - 5);
    return '$dir$file';
  }

  void _removePart(String part) {
    pkg.remove(part);
    pkg.remove(OfficePackage.relsPathFor(part));
    ContentTypes.removeOverride(pkg, part);
  }

  void _updateAppSlideCount() {
    const app = 'docProps/app.xml';
    final text = pkg.text(app);
    if (text == null) return;
    final pres = pkg.xml(presPart);
    final count = Ox.children(
      Ox.child(pres?.rootElement, 'sldIdLst'),
      'sldId',
    ).length;
    final updated = text.replaceFirst(
      RegExp(r'<Slides>\d+</Slides>'),
      '<Slides>$count</Slides>',
    );
    if (updated != text) pkg.putText(app, updated);
  }
}
