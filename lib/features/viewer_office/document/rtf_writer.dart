import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'doc_model.dart';

/// Writes [model] as RTF (Word-compatible subset).
Uint8List writeRtf(DocModel model) =>
    Uint8List.fromList(ascii.encode(_RtfWriter(model).write()));

class _RtfWriter {
  _RtfWriter(this.model);

  final DocModel model;
  final Map<String, int> _fonts = {};
  final Map<int, int> _colors = {};
  final StringBuffer _out = StringBuffer();

  int _font(String? name) {
    final n = name ?? model.baseStyle.fontFamily ?? 'Calibri';
    return _fonts.putIfAbsent(n, () => _fonts.length);
  }

  int _color(int argb) =>
      _colors.putIfAbsent(argb & 0xFFFFFF, () => _colors.length + 1);

  String write() {
    _font(model.baseStyle.fontFamily);
    final body = StringBuffer();
    _blocks(model.blocks, body, inTable: false);

    _out.write(r'{\rtf1\ansi\ansicpg1252\deff0\uc1');
    _out.write(r'{\fonttbl');
    _fonts.forEach((name, i) {
      _out.write('{\\f$i\\fnil\\fcharset0 ${_escapePlain(name)};}');
    });
    _out.write('}');
    _out.write(r'{\colortbl;');
    final ordered = _colors.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    for (final e in ordered) {
      final c = e.key;
      _out.write('\\red${(c >> 16) & 0xFF}\\green${(c >> 8) & 0xFF}\\blue${c & 0xFF};');
    }
    _out.write('}');
    _out.write(r'{\stylesheet{\s0 Normal;}');
    for (var l = 1; l <= 6; l++) {
      final h = model.headingStyles[l];
      final fs = ((h?.fontSize ?? 14) * 2).round();
      _out.write('{\\s$l\\sbasedon0\\snext0${h?.bold ?? true ? '\\b' : ''}\\fs$fs heading $l;}');
    }
    _out.write('}');
    if (model.title != null) {
      _out.write('{\\info{\\title ${_escape(model.title!)}}}');
    }
    final p = model.page;
    _out.write('\\paperw${_tw(p.width)}\\paperh${_tw(p.height)}'
        '\\margl${_tw(p.marginLeft)}\\margr${_tw(p.marginRight)}'
        '\\margt${_tw(p.marginTop)}\\margb${_tw(p.marginBottom)}'
        '${p.width > p.height ? '\\landscape' : ''}\n');
    final fs = ((model.baseStyle.fontSize ?? 11) * 2).round();
    _out.write('\\deftab720\\f0\\fs$fs\n');
    _out.write(body);
    _out.write('}');
    return _out.toString();
  }

  static int _tw(double pt) => (pt * 20).round();

  void _blocks(List<DocBlock> blocks, StringBuffer sb, {required bool inTable, bool lastEndsCell = false}) {
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final isLast = i == blocks.length - 1;
      switch (b) {
        case DocParagraph():
          _paragraph(b, sb, inTable: inTable, endCell: inTable && lastEndsCell && isLast);
        case DocTable():
          if (inTable) {
            // Nested tables are flattened to tab-separated rows.
            for (final r in b.rows) {
              final text = r.cells
                  .where((c) => !c.covered)
                  .map((c) => DocModel.paragraphsIn(c.blocks).map((p) => p.plainText).join(' '))
                  .join('\t');
              _paragraph(DocParagraph(inlines: [DocText(text, model.baseStyle)]), sb,
                  inTable: true, endCell: false);
            }
          } else {
            _table(b, sb);
          }
        case DocPageBreak():
          sb.write('\\page\n');
        case DocSectionBreak():
          if (b.newPage) sb.write('\\page\n');
        case DocFrame():
          _blocks(b.blocks, sb, inTable: inTable);
      }
    }
    if (inTable && lastEndsCell && (blocks.isEmpty || blocks.last is! DocParagraph)) {
      sb.write('\\pard\\intbl\\cell\n');
    }
  }

  void _paragraph(DocParagraph p, StringBuffer sb, {required bool inTable, required bool endCell}) {
    sb.write('\\pard\\plain');
    if (inTable) sb.write('\\intbl');
    final h = p.headingLevel;
    if (h != null) sb.write('\\s$h\\outlinelevel${h - 1}');
    switch (p.align) {
      case DocAlign.center:
        sb.write('\\qc');
      case DocAlign.right:
        sb.write('\\qr');
      case DocAlign.justify:
        sb.write('\\qj');
      case DocAlign.left:
        sb.write('\\ql');
    }
    var li = p.indentLeft;
    var fi = p.firstLine;
    final list = p.list;
    if (list != null && li <= 0) {
      li = 36.0 * (list.level + 1);
      fi = -18;
    }
    if (li != 0) sb.write('\\li${_tw(li)}');
    if (p.indentRight != 0) sb.write('\\ri${_tw(p.indentRight)}');
    if (fi != 0) sb.write('\\fi${_tw(fi)}');
    if (p.spaceBefore != 0) sb.write('\\sb${_tw(p.spaceBefore)}');
    if (p.spaceAfter != 0) sb.write('\\sa${_tw(p.spaceAfter)}');
    if (p.lineExact != null) {
      sb.write('\\sl-${_tw(p.lineExact!)}\\slmult0');
    } else if ((p.lineSpacing - 1).abs() > 0.01) {
      sb.write('\\sl${(p.lineSpacing * 240).round()}\\slmult1');
    }
    if (p.keepNext) sb.write('\\keepn');
    if (p.pageBreakBefore) sb.write('\\pagebb');
    if (p.rtl) sb.write('\\rtlpar');
    if (p.shading != null) sb.write('\\cbpat${_color(p.shading!)}');
    sb.write(' ');
    if (list != null && list.label.isNotEmpty) {
      final st = list.labelStyle ?? p.markStyle;
      sb.write('{\\listtext${_charProps(st)} ${_escape(list.label)}\\tab}');
    }
    String? link;
    final base = model.editorBaseFor(h);
    for (final i in p.inlines) {
      final l = i is DocText ? i.link : null;
      if (l != link) {
        if (link != null) sb.write('}}}');
        if (l != null) {
          sb.write('{\\field{\\*\\fldinst{HYPERLINK "${_escape(l)}"}}{\\fldrslt{');
        }
        link = l;
      }
      switch (i) {
        case DocText():
          sb.write('{${_charProps(i.style, base)} ${_escape(i.text)}}');
        case DocImage():
          sb.write(_picture(i));
        case DocObject():
          final t = i.displayText ?? '';
          if (t.isNotEmpty) sb.write('{${_charProps(i.style, base)} ${_escape(t)}}');
      }
    }
    if (link != null) sb.write('}}}');
    sb.write(endCell ? '\\cell\n' : '\\par\n');
  }

  String _charProps(DocRunStyle s, [DocRunStyle? base]) {
    final sb = StringBuffer('\\f${_font(s.fontFamily)}');
    sb.write('\\fs${((s.fontSize ?? base?.fontSize ?? 11) * 2).round()}');
    if (s.bold) sb.write('\\b');
    if (s.italic) sb.write('\\i');
    if (s.underline) sb.write('\\ul');
    if (s.strike) sb.write('\\strike');
    if (s.allCaps) sb.write('\\caps');
    if (s.smallCaps) sb.write('\\scaps');
    if (s.color != null) sb.write('\\cf${_color(s.color!)}');
    if (s.highlight != null) {
      final c = _color(s.highlight!);
      sb.write('\\highlight$c\\chcbpat$c');
    }
    if (s.vertAlign == DocVertAlign.superscript) sb.write('\\super');
    if (s.vertAlign == DocVertAlign.subscript) sb.write('\\sub');
    return sb.toString();
  }

  void _table(DocTable t, StringBuffer sb) {
    final n = t.columnCount;
    if (n == 0) return;
    var widths = t.columnWidths.length == n
        ? t.columnWidths
        : List<double>.filled(n, model.page.contentWidth / n);
    final total = widths.fold<double>(0, (a, b) => a + b);
    if (total > model.page.contentWidth * 1.5) {
      final f = model.page.contentWidth / total;
      widths = [for (final w in widths) w * f];
    }
    final edges = <double>[0];
    for (final w in widths) {
      edges.add(edges.last + w);
    }
    for (final row in t.rows) {
      final def = StringBuffer('\\trowd\\trgaph108\\trleft0');
      if (row.header) def.write('\\trhdr');
      if (row.height != null) {
        def.write('\\trrh${row.exactHeight ? '-' : ''}${_tw(row.height!)}');
      }
      var col = 0;
      final cells = <DocTableCell>[];
      for (final cell in row.cells) {
        final span = cell.colSpan.clamp(1, n);
        final right = edges[(col + span).clamp(0, n)];
        if (t.borders) {
          def.write('\\clbrdrt\\brdrs\\brdrw10\\clbrdrl\\brdrs\\brdrw10'
              '\\clbrdrb\\brdrs\\brdrw10\\clbrdrr\\brdrs\\brdrw10');
        }
        if (cell.covered) {
          def.write('\\clvmrg');
        } else if (cell.rowSpan > 1) {
          def.write('\\clvmgf');
        }
        if (cell.shading != null) def.write('\\clcbpat${_color(cell.shading!)}');
        if (cell.vAlign == DocCellVAlign.center) def.write('\\clvertalc');
        if (cell.vAlign == DocCellVAlign.bottom) def.write('\\clvertalb');
        def.write('\\cellx${_tw(right)}');
        cells.add(cell);
        col += span;
      }
      sb.write('$def\n');
      for (final cell in cells) {
        if (cell.covered || cell.blocks.isEmpty) {
          sb.write('\\pard\\intbl\\cell\n');
        } else {
          _blocks(cell.blocks, sb, inTable: true, lastEndsCell: true);
        }
      }
      sb.write('$def\\row\n');
    }
    sb.write('\\pard\n');
  }

  String _picture(DocImage i) {
    final data = model.images[i.imageId];
    if (data == null) return '';
    var bytes = data.bytes;
    var type = data.extension;
    if (type != 'png' && type != 'jpeg' && type != 'emf' && type != 'wmf') {
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return '';
        bytes = Uint8List.fromList(img.encodePng(decoded));
        type = 'png';
      } catch (_) {
        return '';
      }
    }
    final blip = switch (type) {
      'png' => '\\pngblip',
      'jpeg' => '\\jpegblip',
      'emf' => '\\emfblip',
      _ => '\\wmetafile8',
    };
    final hex = StringBuffer();
    for (var k = 0; k < bytes.length; k++) {
      hex.write(bytes[k].toRadixString(16).padLeft(2, '0'));
      if (k % 64 == 63) hex.write('\n');
    }
    final w = i.width <= 0 ? 144.0 : i.width;
    final h = i.height <= 0 ? 108.0 : i.height;
    return '{\\pict$blip\\picw${(w / 0.75).round()}\\pich${(h / 0.75).round()}'
        '\\picwgoal${_tw(w)}\\pichgoal${_tw(h)}\n$hex}';
  }

  /// Escapes text, encoding non-ASCII as \uN?.
  static String _escape(String t) {
    final sb = StringBuffer();
    for (final u in t.codeUnits) {
      switch (u) {
        case 0x5C:
          sb.write(r'\\');
        case 0x7B:
          sb.write(r'\{');
        case 0x7D:
          sb.write(r'\}');
        case 0x09:
          sb.write(r'\tab ');
        case 0x0A:
        case 0x2028:
          sb.write(r'\line ');
        case 0x0D:
          break;
        default:
          if (u < 0x20) continue;
          if (u < 0x80) {
            sb.writeCharCode(u);
          } else {
            sb.write('\\u${u > 32767 ? u - 65536 : u}?');
          }
      }
    }
    return sb.toString();
  }

  static String _escapePlain(String t) => _escape(t).replaceAll(';', '');
}
