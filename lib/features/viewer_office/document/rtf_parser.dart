import 'dart:typed_data';

import '../common/code_pages.dart';
import 'doc_model.dart';
import 'docx_parser.dart' show loadImageData, mapSymbolChar;

/// Parses RTF into a [DocModel]. [onPreview], when given, receives a model
/// holding the first pages' blocks of a long document as soon as they're
/// parsed (at most once).
DocModel parseRtfBytes(
  Uint8List bytes, {
  void Function(DocModel preview)? onPreview,
}) => _RtfParser(bytes, onPreview).parse();

/// Offset of the opening `{\rtf` after leading whitespace, or -1 when
/// [bytes] isn't RTF. Shared by the format sniffer and the parser.
int rtfStart(List<int> bytes) {
  var i = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    i = 3; // UTF-8 BOM written by some tools
  }
  // Whitespace (as String.trimLeft sees it on the Latin-1 view) and stray
  // control bytes.
  while (i < bytes.length &&
      (bytes[i] <= 0x20 || bytes[i] == 0x85 || bytes[i] == 0xA0)) {
    i++;
  }
  const sig = [0x7B, 0x5C, 0x72, 0x74, 0x66]; // {\rtf
  if (i + sig.length > bytes.length) return -1;
  for (var k = 0; k < sig.length; k++) {
    if (bytes[i + k] != sig[k]) return -1;
  }
  return i;
}

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
  _RtfParser(Uint8List bytes, this.onPreview)
    : s = String.fromCharCodes(bytes),
      start = rtfStart(bytes);

  final String s;
  final int start;
  final void Function(DocModel preview)? onPreview;
  int pos = 0;

  final List<_Group> stack = [];
  late _Group g;

  int codePage = 1252;
  final Map<int, String> fonts = {};
  final Map<int, int> fontCharset = {};
  final Map<int, int> fontCodePage = {};
  bool? _charsetsMeaningful;
  int defaultFont = 0;

  /// Content the RTF writer can't reproduce was skipped (see
  /// [DocModel.warnUnwritable]).
  bool _unwritable = false;
  bool _encodingLoss = false;
  bool _previewSent = false;
  int _chars = 0;
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

  // Text of the run being collected; becomes a DocText when the formatting
  // or link changes, before any other inline, and at paragraph end. (Growing
  // DocText.text per character is quadratic in the paragraph length.)
  final StringBuffer _runBuf = StringBuffer();
  DocRunStyle? _runStyle;
  String? _runLink;

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
    if (start < 0) {
      throw const FormatException('Not an RTF document');
    }
    pos = start;
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
      } else if (g.dest == _Dest.pict) {
        // Hex picture data: copy up to the next control/group character.
        var e = pos + 1;
        while (e < len) {
          final ch = s.codeUnitAt(e);
          if (ch == 0x5C || ch == 0x7B || ch == 0x7D) break;
          e++;
        }
        _pictHex.write(s.substring(pos, e));
        pos = e;
      } else if (c >= 0x80) {
        _pendingBytes.add(c);
        pos++;
      } else if (c < 0x20 && c != 0x09 && !_awaitingTrailByte()) {
        pos++; // stray control byte (e.g. a NUL after the final brace)
      } else if (_awaitingTrailByte()) {
        // DBCS trail byte written as a literal character (`\'82a`).
        _pendingBytes.add(c);
        pos++;
      } else {
        _flushBytes();
        // Plain text runs to the next special character.
        var e = pos + 1;
        if (c >= 0x20) {
          while (e < len) {
            final ch = s.codeUnitAt(e);
            if (ch < 0x20 ||
                ch >= 0x80 ||
                ch == 0x5C ||
                ch == 0x7B ||
                ch == 0x7D) {
              break;
            }
            e++;
          }
        }
        _text(s.substring(pos, e));
        pos = e;
      }
    }
    _flushBytes();
    _finishParagraph(force: false);
    _closeTable();
    return _model(blocks, images);
  }

  DocModel _model(List<DocBlock> blocks, Map<String, DocImageData> images) {
    page = DocPageSetup(
      width: _pw,
      height: _ph,
      marginLeft: _ml,
      marginRight: _mr,
      marginTop: _mt,
      marginBottom: _mb,
    );
    final base = DocRunStyle(fontSize: 12, fontFamily: fonts[defaultFont]);
    final models = blocks.isEmpty ? <DocBlock>[DocParagraph()] : blocks;
    return DocModel(
      format: 'rtf',
      blocks: models,
      images: images,
      page: page,
      baseStyle: _commonBase(models) ?? base,
      warnings: [
        if (_unwritable) DocModel.warnUnwritable,
        if (_encodingLoss) DocModel.warnEncoding,
      ],
    );
  }

  /// Hands a long document's first blocks to [onPreview] once enough for
  /// the first pages are parsed.
  void _maybePreview() {
    final cb = onPreview;
    if (cb == null || _previewSent || _table != null) return;
    if (blocks.length < 60 && _chars < 6000) return;
    _previewSent = true;
    // Only worth it when a good part of the file is still unparsed.
    if (s.length - pos < 150000) return;
    cb(_model(List.of(blocks), Map.of(images)));
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
          styles[key] = DocRunStyle(
            fontFamily: i.style.fontFamily,
            fontSize: i.style.fontSize,
          );
        }
      }
    }
    if (counts.isEmpty) return null;
    final best = counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
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

  int get _activeFont => g.char.font >= 0 ? g.char.font : defaultFont;

  /// Code page of text in [font]: its `\cpg`, else its charset, else the
  /// document's `\ansicpg`. Charset 0 means Western only when the writer
  /// tags fonts with real charsets; some writers put `\fcharset0` on every
  /// font of a non-Western document.
  int _codePageFor(int font) {
    final cpg = fontCodePage[font];
    if (cpg != null && cpg > 0) return cpg;
    final cs = fontCharset[font];
    if (cs != null && cs != 0) {
      final cp = codePageForCharset(cs);
      if (cp != null) return cp;
    }
    if (cs == 0) {
      final meaningful = _charsetsMeaningful ??= fontCharset.values.any(
        (c) => c != 0 && c != 1 && c != 2,
      );
      if (meaningful) return 1252;
    }
    return codePage;
  }

  int get _textCodePage =>
      _codePageFor(g.dest == _Dest.fontTable ? _curFont : _activeFont);

  /// Whether the pending bytes end with a DBCS lead byte still missing its
  /// trail byte.
  bool _awaitingTrailByte() {
    if (_pendingBytes.isEmpty) return false;
    final cp = _textCodePage;
    if (!isDbcsCodePage(cp)) return false;
    var i = 0;
    while (i < _pendingBytes.length) {
      i += isDbcsLeadByte(cp, _pendingBytes[i]) ? 2 : 1;
    }
    return i > _pendingBytes.length;
  }

  void _flushBytes() {
    if (_pendingBytes.isEmpty) return;
    final bytes = [
      for (final b in _pendingBytes)
        if (b >= 0x20 || b == 0x09) b,
    ];
    _pendingBytes.clear();
    if (bytes.isEmpty) return;
    final font = g.dest == _Dest.fontTable ? _curFont : _activeFont;
    final cs = fontCharset[font];
    final fontName = fonts[font] ?? '';
    final lower = fontName.toLowerCase();
    if (cs == 2 || lower.contains('symbol') || lower.contains('wingdings')) {
      _text(bytes.map((b) => mapSymbolChar(0xF000 + b, fontName)).join());
      return;
    }
    final cp = _codePageFor(font);
    if (!canDecodeCodePage(cp) && g.dest == _Dest.normal) {
      _encodingLoss = true;
      // Saving would replace the characters with U+FFFD for good.
      _unwritable = true;
    }
    _text(decodeCodePage(cp, bytes));
  }

  void _control() {
    pos++; // backslash
    if (pos >= s.length) return;
    final c = s.codeUnitAt(pos);
    if (_isLetter(c)) {
      final wordStart = pos;
      while (pos < s.length && _isLetter(s.codeUnitAt(pos))) {
        pos++;
      }
      final word = s.substring(wordStart, pos);
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
      // Pending \'hh bytes precede this word in the text — including `\u`,
      // whose character must come after them.
      _flushBytes();
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
            if (g.dest == _Dest.normal ||
                g.dest == _Dest.listText ||
                g.dest == _Dest.fontTable ||
                g.dest == _Dest.styleSheet ||
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
        if (_awaitingTrailByte()) {
          _pendingBytes.add(c); // escaped DBCS trail byte (`\'83\\`)
        } else {
          _flushBytes();
          _text(String.fromCharCode(c));
        }
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

  static bool _isLetter(int c) =>
      (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A);
  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static const _skipDestinations = {
    'info',
    'header',
    'headerl',
    'headerr',
    'headerf',
    'footer',
    'footerl',
    'footerr',
    'footerf',
    'footnote',
    'annotation',
    'filetbl',
    'listtable',
    'listoverridetable',
    'revtbl',
    'rsidtbl',
    'xmlnstbl',
    'mmathPr',
    'generator',
    'themedata',
    'colorschememapping',
    'latentstyles',
    'datastore',
    'defchp',
    'defpap',
    'pgdsctbl',
    'objdata',
    'objclass',
    'bkmkstart',
    'bkmkend',
    'nonshppict',
    'shpinst',
    'userprops',
    'docvar',
    'template',
    'fchars',
    'lchars',
    'comment',
    'author',
    'title',
    'subject',
    'operator',
    'keywords',
    'doccomm',
    'company',
    'category',
    'manager',
    'hlinkbase',
    'upr',
    'pn',
    'pnseclvl',
    'atnid',
    'atnauthor',
    'atndate',
    'atnref',
    'xe',
    'tc',
    'txe',
    'falt',
    'panose',
    'fontemb',
    'fontfile',
    'blipuid',
    'passwordhash',
    'wgrffmtfilter',
    'ftnsep',
    'ftnsepc',
    'ftncn',
    'aftnsep',
    'aftnsepc',
    'aftncn',
    'formfield',
    'pgptbl',
    'protusertbl',
    'listpicture',
    'background',
    'docinfo',
    'sp',
    'sn',
    'sv',
    'oldcprops',
    'oldpprops',
    'oldsprops',
    'oldtprops',
    'mmath',
    'nesttableprops',
    'pntxta',
    'pntxtb',
    'ud',
    'factoidname',
    'ebcend',
    'ebcstart',
    'bkmkcolf',
    'bkmkcoll',
    'listname',
    'leveltext',
    'levelnumbers',
    'fname',
  };

  /// Skipped destinations holding content the RTF writer can't write back.
  static const _unwritableDestinations = {
    'header',
    'headerl',
    'headerr',
    'headerf',
    'footer',
    'footerl',
    'footerr',
    'footerf',
    'footnote',
    'annotation',
    'shpinst',
    'objdata',
    // Word lists (listtable) are written back with their labels and start
    // numbers; old-style WordPad numbering (\pn) isn't.
    'pn',
    'formfield',
    'xe',
    'tc',
  };

  /// Skips `\binN` data. Only ever forward: a negative N would move the
  /// parser back onto the same token and loop forever.
  void _skipBinary(int? p) {
    if (p == null || p <= 0) return;
    pos = p >= s.length - pos ? s.length : pos + p;
  }

  void _word(String w, int? p) {
    final starred = _starred;
    _starred = false;
    if (g.dest == _Dest.skip) {
      if (w == 'bin') _skipBinary(p);
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
        // Only hyperlinks are written back; other fields (page numbers,
        // TOC, dates, references) would become static text.
        final inst = _fieldInst.isEmpty
            ? ''
            : _fieldInst.last.toString().trim().toUpperCase();
        if (inst.isNotEmpty && !inst.startsWith('HYPERLINK')) {
          _unwritable = true;
        }
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
        _skipBinary(p);
        return;
    }
    if (_skipDestinations.contains(w)) {
      if (_unwritableDestinations.contains(w)) _unwritable = true;
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
          _charsetsMeaningful = null;
        case 'cpg':
          if (_curFont >= 0 && p != null) fontCodePage[_curFont] = p;
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
        // A break character inside the paragraph; its text continues after.
        _finishParagraph(force: false);
        blocks.add(DocPageBreak(joinNext: true));
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
          while (pos < s.length &&
              (s.codeUnitAt(pos) == 0x2D || _isDigit(s.codeUnitAt(pos)))) {
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
        // One entry per ';' (text arrives in runs, e.g. ";;" for two).
        for (var k = 0; k < t.length; k++) {
          if (t.codeUnitAt(k) != 0x3B) continue;
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
    _chars += t.length;
    if (_runBuf.isNotEmpty && (style != _runStyle || link != _runLink)) {
      _flushRun();
    }
    if (_runBuf.isEmpty) {
      _runStyle = style;
      _runLink = link;
    }
    _runBuf.write(t);
  }

  /// Turns the collected run text into an inline (merging with the previous
  /// text inline when the formatting matches).
  void _flushRun() {
    if (_runBuf.isEmpty) return;
    final text = _runBuf.toString();
    _runBuf.clear();
    final last = inlines.isEmpty ? null : inlines.last;
    if (last is DocText && last.style == _runStyle && last.link == _runLink) {
      last.text += text;
    } else {
      inlines.add(DocText(text, _runStyle!, link: _runLink));
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
    _flushRun();
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
      final number = ListLabel.parse(label, previous: _lastLabel[pp.ilvl]);
      _lastLabel[pp.ilvl] = number;
      list = DocListInfo(
        ordered: number != null,
        level: pp.ilvl,
        label: label.isEmpty ? '•' : label,
        format: number?.format ?? 'bullet',
      );
    }
    _listLabel.clear();
    final markStyle = _style(g.char);
    final p = DocParagraph(
      inlines: inlines,
      headingLevel: heading,
      styleId: styleNames[pp.style],
      align: const [
        DocAlign.left,
        DocAlign.center,
        DocAlign.right,
        DocAlign.justify,
      ][pp.align],
      indentLeft: pp.li / 20,
      indentRight: pp.ri / 20,
      firstLine: pp.fi / 20,
      spaceBefore: pp.sb / 20,
      spaceAfter: pp.sa / 20,
      lineSpacing: pp.sl != 0 && pp.slMult
          ? (pp.sl.abs() / 240).clamp(0.5, 5.0)
          : 1.0,
      lineExact: pp.sl < 0
          ? -pp.sl / 20
          : (!pp.slMult && pp.sl > 0 && pp.sl / 20 > 16 ? pp.sl / 20 : null),
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
      // \pagebb is kept on the paragraph; the layout and writers honour it.
      blocks.add(p);
      _maybePreview();
    }
  }

  /// Last numbered label per list level (to tell letters from roman
  /// numerals).
  final Map<int, ListLabel?> _lastLabel = {};

  void _endCell() {
    _row ??= DocTableRow();
    _row!.cells.add(DocTableCell(blocks: _cellBlocks));
    _cellBlocks = [];
  }

  void _endRow() {
    _flushRun();
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
        if (def.shading > 0 && def.shading < colors.length) {
          cell.shading = colors[def.shading];
        }
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
    if (widest != null &&
        widest.cells.every((c) => (c.width ?? 0) > 0 && c.colSpan == 1)) {
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
      final bitCount = bytes.length >= 16
          ? bd.getUint16(14, Endian.little)
          : 24;
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
      _flushRun();
      inlines.add(DocImage(imageId: id, width: w, height: h));
    }
    g.dest = saved;
  }
}
