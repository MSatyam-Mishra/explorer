import 'dart:typed_data';

import 'package:explorer/core/formats/cfb_reader.dart';

import 'doc_model.dart';
import 'docx_parser.dart' show loadImageData, mapSymbolChar;

/// Parses RTF into a [DocModel].
DocModel parseRtfBytes(Uint8List bytes) => _RtfParser(bytes).parse();

class _CharState {
  bool bold = false, italic = false, underline = false, strike = false;
  bool caps = false, smallCaps = false, hidden = false;
  int fontSize = 24; // half-points
  int color = 0;
  int highlight = 0;
  int font = -1;
  int vert = 0;

  _CharState copy() => _CharState()
    ..bold = bold
    ..italic = italic
    ..underline = underline
    ..strike = strike
    ..caps = caps
    ..smallCaps = smallCaps
    ..hidden = hidden
    ..fontSize = fontSize
    ..color = color
    ..highlight = highlight
    ..font = font
    ..vert = vert;
}

class _ParaState {
  int align = 0; // 0 l, 1 c, 2 r, 3 j
  int li = 0, ri = 0, fi = 0, sb = 0, sa = 0;
  int sl = 0;
  bool slMult = false;
  bool inTable = false;
  int style = 0;
  int list = 0;
  int ilvl = 0;
  int outline = -1;
  bool rtl = false;
  bool keepNext = false;
  bool pageBreakBefore = false;

  _ParaState copy() => _ParaState()
    ..align = align
    ..li = li
    ..ri = ri
    ..fi = fi
    ..sb = sb
    ..sa = sa
    ..sl = sl
    ..slMult = slMult
    ..inTable = inTable
    ..style = style
    ..list = list
    ..ilvl = ilvl
    ..outline = outline
    ..rtl = rtl
    ..keepNext = keepNext
    ..pageBreakBefore = pageBreakBefore;
}

enum _Dest {
  normal,
  skip,
  fontTable,
  colorTable,
  styleSheet,
  pict,
  fieldInst,
  listText,
}

class _Group {
  _Group(this.char, this.para, this.dest, this.uc);
  _CharState char;
  _ParaState para;
  _Dest dest;
  int uc;
  bool fieldResult = false;
  bool isField = false;
}

class _CellDef {
  _CellDef(this.right);
  int right;
  int shading = 0;
  bool hMergeFirst = false, hMerge = false, vMergeFirst = false, vMerge = false;
}

class _RtfParser {
  _RtfParser(Uint8List bytes) : s = String.fromCharCodes(bytes);

  final String s;
  int pos = 0;

  final List<_Group> stack = [];
  late _Group g;

  int codePage = 1252;
  final Map<int, String> fonts = {};
  final Map<int, int> fontCharset = {};
  int defaultFont = 0;
  final List<int?> colors = [];
  final Map<int, String> styleNames = {};
  final Map<String, DocImageData> images = {};
  int _imageNo = 0;

  // Font table entry being read.
  int _curFont = -1;
  final StringBuffer _fontName = StringBuffer();
  // Colour table entry.
  int _r = -1, _g = -1, _b = -1;
  // Style sheet entry.
  int _curStyle = 0;
  final StringBuffer _styleName = StringBuffer();

  // Picture.
  final StringBuffer _pictHex = StringBuffer();
  String _pictType = '';
  int _picwGoal = 0, _pichGoal = 0, _picw = 0, _pich = 0;
  int _scaleX = 100, _scaleY = 100;

  // Fields.
  final List<StringBuffer> _fieldInst = [];
  final List<String?> _fieldLinks = [];

  // Output.
  final List<DocBlock> blocks = [];
  List<DocInline> inlines = [];
  final StringBuffer _listLabel = StringBuffer();
  final List<int> _pendingBytes = [];

  // Tables.
  List<_CellDef> _rowDefs = [];
  DocTable? _table;
  DocTableRow? _row;
  List<DocBlock> _cellBlocks = [];
  bool _rowHeader = false;
  int? _rowHeight;

  DocPageSetup page = DocPageSetup.letter;
  double _pw = 612, _ph = 792, _ml = 90, _mr = 90, _mt = 72, _mb = 72;

  DocModel parse() {
    if (!s.startsWith('{\\rtf')) {
      throw const FormatException('Not an RTF document');
    }
    g = _Group(_CharState(), _ParaState(), _Dest.normal, 1);
    final len = s.length;
    while (pos < len) {
      final c = s.codeUnitAt(pos);
      if (c == 0x7B) {
        _flushBytes();
        stack.add(g);
        final ng = _Group(g.char.copy(), g.para.copy(), g.dest, g.uc);
        g = ng;
        pos++;
      } else if (c == 0x7D) {
        _flushBytes();
        _endGroup();
        pos++;
      } else if (c == 0x5C) {
        _control();
      } else if (c == 0x0D || c == 0x0A) {
        pos++;
      } else {
        if (g.dest == _Dest.pict) {
          _pictHex.writeCharCode(c);
        } else if (c >= 0x80) {
          _pendingBytes.add(c);
        } else {
          _flushBytes();
          _text(String.fromCharCode(c));
        }
        pos++;
      }
    }
    _flushBytes();
    _finishParagraph(force: false);
    _closeTable();
    page = DocPageSetup(
      width: _pw,
      height: _ph,
      marginLeft: _ml,
      marginRight: _mr,
      marginTop: _mt,
      marginBottom: _mb,
    );
    final base = DocRunStyle(
      fontSize: 12,
      fontFamily: fonts[defaultFont],
    );
    final models = blocks.isEmpty ? <DocBlock>[DocParagraph()] : blocks;
    return DocModel(
      format: 'rtf',
      blocks: models,
      images: images,
      page: page,
      baseStyle: _commonBase(models) ?? base,
    );
  }

  /// Most common run size/font, used as the "Normal" style.
  DocRunStyle? _commonBase(List<DocBlock> blocks) {
    final counts = <String, int>{};
    final styles = <String, DocRunStyle>{};
    for (final p in DocModel.paragraphsIn(blocks)) {
      if (p.headingLevel != null) continue;
      for (final i in p.inlines) {
        if (i is DocText) {
          final key = '${i.style.fontFamily}|${i.style.fontSize}';
          counts[key] = (counts[key] ?? 0) + i.text.length;
          styles[key] = DocRunStyle(fontFamily: i.style.fontFamily, fontSize: i.style.fontSize);
        }
      }
    }
    if (counts.isEmpty) return null;
    final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return styles[best];
  }

  void _endGroup() {
    final ending = g;
    switch (ending.dest) {
      case _Dest.fontTable:
        _commitFont();
      case _Dest.styleSheet:
        _commitStyle();
      case _Dest.pict:
        if (stack.isNotEmpty && stack.last.dest != _Dest.pict) _commitPicture();
      default:
        break;
    }
    if (ending.isField && _fieldInst.isNotEmpty) {
      _fieldInst.removeLast();
      _fieldLinks.removeLast();
    }
    if (stack.isEmpty) return;
    g = stack.removeLast();
  }

  void _commitFont() {
    if (_curFont >= 0) {
      var name = _fontName.toString().trim();
      if (name.endsWith(';')) name = name.substring(0, name.length - 1).trim();
      if (name.isNotEmpty) fonts[_curFont] = name;
    }
    _curFont = -1;
    _fontName.clear();
  }

  void _commitStyle() {
    var name = _styleName.toString().trim();
    if (name.endsWith(';')) name = name.substring(0, name.length - 1).trim();
    if (name.isNotEmpty) styleNames[_curStyle] = name;
    _styleName.clear();
    _curStyle = 0;
  }

  void _flushBytes() {
    if (_pendingBytes.isEmpty) return;
    final bytes = [
      for (final b in _pendingBytes)
        if (b >= 0x20 || b == 0x09) b,
    ];
    _pendingBytes.clear();
    if (bytes.isEmpty) return;
    var cp = codePage;
    final cs = fontCharset[g.char.font];
    final fontName = fonts[g.char.font] ?? '';
    final lower = fontName.toLowerCase();
    if (cs == 2 || lower.contains('symbol') || lower.contains('wingdings')) {
      _text(bytes.map((b) => mapSymbolChar(0xF000 + b, fontName)).join());
      return;
    }
    if (cs == 204) cp = 1251;
    if (cs == 0) cp = 1252;
    _text(cp == 1251 ? _decode1251(bytes) : decodeCp1252(bytes));
  }

  static String _decode1251(List<int> bytes) {
    const high = [
      0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F, //
      0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
      0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
      0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ];
    return String.fromCharCodes([
      for (final b in bytes)
        b < 0x80 ? b : (b < 0xC0 ? high[b - 0x80] : 0x0410 + (b - 0xC0)),
    ]);
  }

  void _control() {
    pos++; // backslash
    if (pos >= s.length) return;
    final c = s.codeUnitAt(pos);
    if (_isLetter(c)) {
      final start = pos;
      while (pos < s.length && _isLetter(s.codeUnitAt(pos))) {
        pos++;
      }
      final word = s.substring(start, pos);
      int? param;
      if (pos < s.length) {
        final pc = s.codeUnitAt(pos);
        if (pc == 0x2D || (pc >= 0x30 && pc <= 0x39)) {
          final ps = pos;
          pos++;
          while (pos < s.length && _isDigit(s.codeUnitAt(pos))) {
            pos++;
          }
          param = int.tryParse(s.substring(ps, pos));
        }
      }
      if (pos < s.length && s.codeUnitAt(pos) == 0x20) pos++;
      if (word != 'u' && word != 'bin') _flushBytes();
      _word(word, param);
      return;
    }
    pos++;
    switch (c) {
      case 0x27: // \'hh
        if (pos + 2 <= s.length) {
          final v = int.tryParse(s.substring(pos, pos + 2), radix: 16);
          pos += 2;
          if (v != null) {
            if (g.dest == _Dest.normal || g.dest == _Dest.listText ||
                g.dest == _Dest.fontTable || g.dest == _Dest.styleSheet ||
                g.dest == _Dest.fieldInst) {
              _pendingBytes.add(v);
            }
          }
        }
      case 0x2A: // \*
        _flushBytes();
        _starred = true;
        return;
      case 0x7B:
      case 0x7D:
      case 0x5C:
        _flushBytes();
        _text(String.fromCharCode(c));
      case 0x7E:
        _flushBytes();
        _text('\u00A0');
      case 0x5F:
        _flushBytes();
        _text('\u2011');
      case 0x2D:
        break; // optional hyphen
      case 0x0A:
      case 0x0D:
        _flushBytes();
        _word('par', null);
      case 0x09:
        _flushBytes();
        _text('\t');
    }
    _starred = false;
  }

  bool _starred = false;

  static bool _isLetter(int c) => (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A);
  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static const _skipDestinations = {
    'info', 'header', 'headerl', 'headerr', 'headerf', 'footer', 'footerl',
    'footerr', 'footerf', 'footnote', 'annotation', 'filetbl', 'listtable',
    'listoverridetable', 'revtbl', 'rsidtbl', 'xmlnstbl', 'mmathPr',
    'generator', 'themedata', 'colorschememapping', 'latentstyles',
    'datastore', 'defchp', 'defpap', 'pgdsctbl', 'objdata', 'objclass',
    'bkmkstart', 'bkmkend', 'nonshppict', 'shpinst', 'userprops', 'docvar',
    'template', 'fchars', 'lchars', 'comment', 'author', 'title', 'subject',
    'operator', 'keywords', 'doccomm', 'company', 'category', 'manager',
    'hlinkbase', 'upr', 'pn', 'pnseclvl', 'atnid', 'atnauthor', 'atndate',
    'atnref', 'xe', 'tc', 'txe', 'falt', 'panose', 'fontemb', 'fontfile',
    'blipuid', 'passwordhash', 'wgrffmtfilter', 'ftnsep', 'ftnsepc',
    'ftncn', 'aftnsep', 'aftnsepc', 'aftncn', 'formfield', 'pgptbl',
    'protusertbl', 'listpicture', 'background', 'docinfo', 'sp', 'sn', 'sv',
    'oldcprops', 'oldpprops', 'oldsprops', 'oldtprops', 'mmath', 'nesttableprops',
    'pntxta', 'pntxtb', 'ud', 'factoidname', 'ebcend', 'ebcstart', 'bkmkcolf',
    'bkmkcoll', 'listname', 'leveltext', 'levelnumbers', 'fname',
  };

  void _word(String w, int? p) {
    final starred = _starred;
    _starred = false;
    if (g.dest == _Dest.skip) {
      if (w == 'bin') pos += (p ?? 0);
      return;
    }

    // Destinations.
    switch (w) {
      case 'fonttbl':
        g.dest = _Dest.fontTable;
        return;
      case 'colortbl':
        g.dest = _Dest.colorTable;
        return;
      case 'stylesheet':
        g.dest = _Dest.styleSheet;
        return;
      case 'pict':
        g.dest = _Dest.pict;
        _pictHex.clear();
        _pictType = '';
        _picwGoal = _pichGoal = _picw = _pich = 0;
        _scaleX = _scaleY = 100;
        return;
      case 'shppict':
      case 'shprslt':
      case 'result':
        return; // Process contents normally.
      case 'fldinst':
        g.dest = _Dest.fieldInst;
        return;
      case 'fldrslt':
        g.fieldResult = true;
        if (g.dest == _Dest.fieldInst) g.dest = _Dest.normal;
        return;
      case 'field':
        g.isField = true;
        _fieldInst.add(StringBuffer());
        _fieldLinks.add(null);
        return;
      case 'listtext':
      case 'pntext':
        g.dest = _Dest.listText;
        _listLabel.clear();
        return;
      case 'object':
        return;
      case 'bin':
        pos += (p ?? 0);
        return;
    }
    if (_skipDestinations.contains(w)) {
      g.dest = _Dest.skip;
      return;
    }
    if (starred) {
      // Unknown ignorable destination.
      g.dest = _Dest.skip;
      return;
    }
    if (g.dest == _Dest.skip) return;

    if (g.dest == _Dest.fontTable) {
      switch (w) {
        case 'f':
          _commitFont();
          _curFont = p ?? 0;
        case 'fcharset':
          if (_curFont >= 0) fontCharset[_curFont] = p ?? 0;
      }
      return;
    }
    if (g.dest == _Dest.colorTable) {
      switch (w) {
        case 'red':
          _r = p ?? 0;
        case 'green':
          _g = p ?? 0;
        case 'blue':
          _b = p ?? 0;
      }
      return;
    }
    if (g.dest == _Dest.styleSheet) {
      if (w == 's' || w == 'cs' || w == 'ds' || w == 'ts') {
        _commitStyle();
        _curStyle = w == 's' ? (p ?? 0) : -1000 - (p ?? 0);
      }
      return;
    }
    if (g.dest == _Dest.pict) {
      switch (w) {
        case 'pngblip':
          _pictType = 'png';
        case 'jpegblip':
          _pictType = 'jpeg';
        case 'emfblip':
          _pictType = 'emf';
        case 'wmetafile':
          _pictType = 'wmf';
        case 'dibitmap':
          _pictType = 'dib';
        case 'picwgoal':
          _picwGoal = p ?? 0;
        case 'pichgoal':
          _pichGoal = p ?? 0;
        case 'picw':
          _picw = p ?? 0;
        case 'pich':
          _pich = p ?? 0;
        case 'picscalex':
          _scaleX = p ?? 100;
        case 'picscaley':
          _scaleY = p ?? 100;
      }
      return;
    }

    final c = g.char;
    final para = g.para;
    switch (w) {
      // Document.
      case 'ansicpg':
        codePage = p ?? 1252;
      case 'deff':
        defaultFont = p ?? 0;
      case 'paperw':
        _pw = (p ?? 12240) / 20;
      case 'paperh':
        _ph = (p ?? 15840) / 20;
      case 'margl':
        _ml = (p ?? 1800) / 20;
      case 'margr':
        _mr = (p ?? 1800) / 20;
      case 'margt':
        _mt = (p ?? 1440) / 20;
      case 'margb':
        _mb = (p ?? 1440) / 20;
      case 'uc':
        g.uc = p ?? 1;
      case 'u':
        var code = p ?? 0;
        if (code < 0) code += 65536;
        _text(String.fromCharCode(code));
        _skipFallback(g.uc);

      // Characters.
      case 'plain':
        g.char = _CharState()..font = defaultFont;
      case 'b':
        c.bold = p != 0;
      case 'i':
        c.italic = p != 0;
      case 'ul':
      case 'uld':
      case 'uldb':
      case 'uldash':
      case 'uldashd':
      case 'uldashdd':
      case 'ulth':
      case 'ulw':
      case 'ulwave':
      case 'uldouble':
      case 'ulhwave':
      case 'ulthd':
      case 'ulthdash':
      case 'ulldash':
        c.underline = p != 0;
      case 'ulnone':
        c.underline = false;
      case 'strike':
      case 'striked':
        c.strike = p != 0;
      case 'caps':
        c.caps = p != 0;
      case 'scaps':
        c.smallCaps = p != 0;
      case 'v':
        c.hidden = p != 0;
      case 'fs':
        c.fontSize = p ?? 24;
      case 'cf':
        c.color = p ?? 0;
      case 'highlight':
      case 'cb':
      case 'chcbpat':
        c.highlight = p ?? 0;
      case 'f':
        c.font = p ?? 0;
      case 'super':
        c.vert = 1;
      case 'sub':
        c.vert = 2;
      case 'nosupersub':
        c.vert = 0;
      case 'up':
        c.vert = (p ?? 6) > 0 ? 1 : 0;
      case 'dn':
        c.vert = (p ?? 6) > 0 ? 2 : 0;

      // Paragraphs.
      case 'pard':
        g.para = _ParaState();
      case 'par':
        _finishParagraph(force: true);
      case 'sect':
        _finishParagraph(force: false);
        blocks.add(DocPageBreak());
      case 'page':
        _finishParagraph(force: false);
        blocks.add(DocPageBreak());
      case 'line':
        _text('\n');
      case 'tab':
        _text('\t');
      case 'ql':
        para.align = 0;
      case 'qc':
        para.align = 1;
      case 'qr':
        para.align = 2;
      case 'qj':
      case 'qd':
        para.align = 3;
      case 'li':
        para.li = p ?? 0;
      case 'ri':
        para.ri = p ?? 0;
      case 'fi':
        para.fi = p ?? 0;
      case 'sb':
        para.sb = p ?? 0;
      case 'sa':
        para.sa = p ?? 0;
      case 'sl':
        para.sl = p ?? 0;
      case 'slmult':
        para.slMult = p == 1;
      case 's':
        para.style = p ?? 0;
      case 'ls':
        para.list = p ?? 0;
      case 'ilvl':
        para.ilvl = p ?? 0;
      case 'outlinelevel':
        para.outline = p ?? -1;
      case 'rtlpar':
        para.rtl = true;
      case 'ltrpar':
        para.rtl = false;
      case 'keepn':
        para.keepNext = true;
      case 'pagebb':
        para.pageBreakBefore = true;
      case 'intbl':
        para.inTable = true;

      // Special characters.
      case 'emdash':
        _text('—');
      case 'endash':
        _text('–');
      case 'bullet':
        _text('•');
      case 'lquote':
        _text('‘');
      case 'rquote':
        _text('’');
      case 'ldblquote':
        _text('“');
      case 'rdblquote':
        _text('”');
      case 'emspace':
        _text(' ');
      case 'enspace':
        _text(' ');

      // Tables.
      case 'trowd':
        _rowDefs = [];
        _rowHeader = false;
        _rowHeight = null;
      case 'trhdr':
        _rowHeader = true;
      case 'trrh':
        _rowHeight = p;
      case 'cellx':
        final def = _pendingCell ?? _CellDef(0);
        def.right = p ?? 0;
        _rowDefs.add(def);
        _pendingCell = null;
      case 'clmgf':
        (_pendingCell ??= _CellDef(0)).hMergeFirst = true;
      case 'clmrg':
        (_pendingCell ??= _CellDef(0)).hMerge = true;
      case 'clvmgf':
        (_pendingCell ??= _CellDef(0)).vMergeFirst = true;
      case 'clvmrg':
        (_pendingCell ??= _CellDef(0)).vMerge = true;
      case 'clcbpat':
        (_pendingCell ??= _CellDef(0)).shading = p ?? 0;
      case 'cell':
      case 'nestcell':
        _finishParagraph(force: false, intoCell: true);
        if (w == 'cell') _endCell();
      case 'row':
        _endRow();
      case 'nestrow':
        break;
    }
  }

  _CellDef? _pendingCell;

  void _skipFallback(int count) {
    var n = count;
    while (n > 0 && pos < s.length) {
      final c = s.codeUnitAt(pos);
      if (c == 0x5C) {
        if (pos + 1 < s.length && s.codeUnitAt(pos + 1) == 0x27) {
          pos += 4;
        } else if (pos + 1 < s.length && _isLetter(s.codeUnitAt(pos + 1))) {
          pos++;
          while (pos < s.length && _isLetter(s.codeUnitAt(pos))) {
            pos++;
          }
          while (pos < s.length && (s.codeUnitAt(pos) == 0x2D || _isDigit(s.codeUnitAt(pos)))) {
            pos++;
          }
          if (pos < s.length && s.codeUnitAt(pos) == 0x20) pos++;
        } else {
          pos += 2;
        }
      } else if (c == 0x7B || c == 0x7D) {
        return;
      } else {
        pos++;
      }
      n--;
    }
  }

  void _text(String t) {
    switch (g.dest) {
      case _Dest.skip:
      case _Dest.pict:
        return;
      case _Dest.fontTable:
        _fontName.write(t);
        return;
      case _Dest.colorTable:
        if (t.contains(';')) {
          colors.add(_r < 0 ? null : 0xFF000000 | (_r << 16) | (_g << 8) | _b);
          _r = _g = _b = -1;
        }
        return;
      case _Dest.styleSheet:
        _styleName.write(t);
        return;
      case _Dest.fieldInst:
        if (_fieldInst.isNotEmpty) {
          _fieldInst.last.write(t);
          final inst = _fieldInst.last.toString().trim();
          if (inst.toUpperCase().startsWith('HYPERLINK')) {
            final m = RegExp(r'"([^"]*)"').firstMatch(inst);
            if (m != null) _fieldLinks[_fieldLinks.length - 1] = m.group(1);
          }
        }
        return;
      case _Dest.listText:
        _listLabel.write(t);
        return;
      case _Dest.normal:
        break;
    }
    if (g.char.hidden) return;
    final style = _style(g.char);
    String? link;
    for (final l in _fieldLinks.reversed) {
      if (l != null) {
        link = l;
        break;
      }
    }
    final last = inlines.isEmpty ? null : inlines.last;
    if (last is DocText && last.style == style && last.link == link) {
      last.text += t;
    } else {
      inlines.add(DocText(t, style, link: link));
    }
  }

  DocRunStyle _style(_CharState c) {
    int? color(int idx) => idx > 0 && idx < colors.length ? colors[idx] : null;
    return DocRunStyle(
      bold: c.bold,
      italic: c.italic,
      underline: c.underline,
      strike: c.strike,
      allCaps: c.caps,
      smallCaps: c.smallCaps,
      color: color(c.color),
      highlight: c.highlight > 0 ? color(c.highlight) : null,
      fontSize: c.fontSize / 2,
      fontFamily: fonts[c.font >= 0 ? c.font : defaultFont],
      vertAlign: c.vert == 1
          ? DocVertAlign.superscript
          : c.vert == 2
              ? DocVertAlign.subscript
              : DocVertAlign.baseline,
    );
  }

  void _finishParagraph({required bool force, bool intoCell = false}) {
    if (!force && !intoCell && inlines.isEmpty && _listLabel.isEmpty) return;
    final pp = g.para;
    final styleName = (styleNames[pp.style] ?? '').toLowerCase();
    int? heading;
    final m = RegExp(r'^heading\s*([1-9])').firstMatch(styleName);
    if (m != null) heading = int.parse(m.group(1)!).clamp(1, 6);
    if (heading == null && pp.outline >= 0 && pp.outline < 9) {
      heading = (pp.outline + 1).clamp(1, 6);
    }
    DocListInfo? list;
    final label = _listLabel.toString().replaceAll('\t', '').trim();
    if (pp.list > 0 || label.isNotEmpty) {
      final ordered = RegExp(r'^[(]?[0-9a-zA-Z]{1,6}[.)]?$').hasMatch(label) &&
          !RegExp(r'^[oO]$').hasMatch(label);
      list = DocListInfo(
        ordered: ordered,
        level: pp.ilvl,
        label: label.isEmpty ? '•' : label,
        format: ordered ? 'decimal' : 'bullet',
      );
    }
    _listLabel.clear();
    final markStyle = _style(g.char);
    final p = DocParagraph(
      inlines: inlines,
      headingLevel: heading,
      styleId: styleNames[pp.style],
      align: const [DocAlign.left, DocAlign.center, DocAlign.right, DocAlign.justify][pp.align],
      indentLeft: pp.li / 20,
      indentRight: pp.ri / 20,
      firstLine: pp.fi / 20,
      spaceBefore: pp.sb / 20,
      spaceAfter: pp.sa / 20,
      lineSpacing: pp.sl != 0 && pp.slMult ? (pp.sl.abs() / 240).clamp(0.5, 5.0) : 1.0,
      lineExact: pp.sl < 0 ? -pp.sl / 20 : (!pp.slMult && pp.sl > 0 && pp.sl / 20 > 16 ? pp.sl / 20 : null),
      list: list,
      keepNext: pp.keepNext,
      pageBreakBefore: pp.pageBreakBefore,
      rtl: pp.rtl,
      markStyle: markStyle,
    );
    inlines = [];
    if (pp.inTable || intoCell) {
      _cellBlocks.add(p);
    } else {
      _closeTable();
      if (p.pageBreakBefore && blocks.isNotEmpty) blocks.add(DocPageBreak());
      blocks.add(p);
    }
  }

  void _endCell() {
    _row ??= DocTableRow();
    _row!.cells.add(DocTableCell(blocks: _cellBlocks));
    _cellBlocks = [];
  }

  void _endRow() {
    if (_cellBlocks.isNotEmpty || inlines.isNotEmpty) {
      _finishParagraph(force: false, intoCell: true);
      _endCell();
    }
    final row = _row ?? DocTableRow();
    _row = null;
    _table ??= DocTable();
    // Apply cell definitions (widths, merges, shading).
    final defs = _rowDefs;
    final cells = <DocTableCell>[];
    var left = 0;
    for (var i = 0; i < row.cells.length; i++) {
      final cell = row.cells[i];
      final def = i < defs.length ? defs[i] : null;
      if (def != null) {
        cell.width = (def.right - left).abs() / 20;
        left = def.right;
        if (def.shading > 0 && def.shading < colors.length) cell.shading = colors[def.shading];
        if (def.vMerge) cell.covered = true;
        if (def.hMerge && cells.isNotEmpty) {
          cells.last.colSpan++;
          continue;
        }
      }
      cells.add(cell);
    }
    row.cells = cells;
    row.header = _rowHeader;
    if (_rowHeight != null) {
      row.height = _rowHeight!.abs() / 20;
      row.exactHeight = _rowHeight! < 0;
    }
    _table!.rows.add(row);
  }

  void _closeTable() {
    final t = _table;
    if (t == null) return;
    _table = null;
    if (t.rows.isEmpty) return;
    // Resolve vertical merges: count covered cells below each start.
    for (var r = 0; r < t.rows.length; r++) {
      for (var c = 0; c < t.rows[r].cells.length; c++) {
        final cell = t.rows[r].cells[c];
        if (cell.covered) continue;
        var span = 1;
        for (var rr = r + 1; rr < t.rows.length; rr++) {
          final cells = t.rows[rr].cells;
          if (c < cells.length && cells[c].covered) {
            span++;
          } else {
            break;
          }
        }
        cell.rowSpan = span;
      }
    }
    // Column widths from the widest row.
    DocTableRow? widest;
    for (final r in t.rows) {
      if (widest == null || r.cells.length > widest.cells.length) widest = r;
    }
    if (widest != null && widest.cells.every((c) => (c.width ?? 0) > 0 && c.colSpan == 1)) {
      t.columnWidths = [for (final c in widest.cells) c.width!];
    }
    blocks.add(t);
  }

  void _commitPicture() {
    final hex = _pictHex.toString().replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    _pictHex.clear();
    if (hex.length < 16 || _pictType.isEmpty) return;
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    Uint8List data = bytes;
    var ext = _pictType;
    if (_pictType == 'dib') {
      // Prepend a BMP file header.
      final header = ByteData(14);
      header.setUint8(0, 0x42);
      header.setUint8(1, 0x4D);
      header.setUint32(2, 14 + bytes.length, Endian.little);
      final bd = ByteData.sublistView(bytes);
      final infoSize = bytes.length >= 4 ? bd.getUint32(0, Endian.little) : 40;
      final bitCount = bytes.length >= 16 ? bd.getUint16(14, Endian.little) : 24;
      var colorsUsed = bytes.length >= 36 ? bd.getUint32(32, Endian.little) : 0;
      if (colorsUsed == 0 && bitCount <= 8) colorsUsed = 1 << bitCount;
      header.setUint32(10, 14 + infoSize + colorsUsed * 4, Endian.little);
      data = Uint8List.fromList([...header.buffer.asUint8List(), ...bytes]);
      ext = 'bmp';
    }
    final id = 'rtf_image_${_imageNo++}';
    images[id] = loadImageData(data, '$id.$ext');
    var w = _picwGoal > 0 ? _picwGoal / 20 : _picw * 0.75;
    var h = _pichGoal > 0 ? _pichGoal / 20 : _pich * 0.75;
    w = w * _scaleX / 100;
    h = h * _scaleY / 100;
    // The picture belongs to the enclosing (normal) group.
    final saved = g.dest;
    g.dest = _Dest.normal;
    if (!g.char.hidden) {
      inlines.add(DocImage(imageId: id, width: w, height: h));
    }
    g.dest = saved;
  }
}
