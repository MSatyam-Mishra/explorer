import 'dart:convert';
import 'dart:typed_data';

import '../formula/ref_rewriter.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';

/// Minimal pull reader over UTF-8 XML bytes for the two hot parts of an
/// .xlsx package (worksheets and the shared strings table). It allocates
/// nothing per event; names, attributes and text are byte ranges that callers
/// decode only when they need them. Several times faster than the generic
/// `xml` event parser on large sheets.
class XmlByteReader {
  XmlByteReader(this.b) : n = b.length {
    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) _pos = 3;
  }

  static const eof = 0;
  static const startTag = 1;
  static const endTag = 2;
  static const text = 3;
  static const cdata = 4;

  final Uint8List b;
  final int n;
  int _pos = 0;

  /// Local name (namespace prefix removed) of the current start/end tag.
  int nameStart = 0;
  int nameEnd = 0;
  bool selfClosing = false;

  /// Text or CDATA content of the current event.
  int textStart = 0;
  int textEnd = 0;

  int _attrPos = 0;
  int _attrEnd = 0;

  /// Current attribute: local name and value range.
  int attrNameStart = 0;
  int attrNameEnd = 0;
  int valueStart = 0;
  int valueEnd = 0;

  int _indexOf(int byte, int from) {
    for (var i = from; i < n; i++) {
      if (b[i] == byte) return i;
    }
    return -1;
  }

  int _find(List<int> seq, int from) {
    final first = seq[0];
    for (var i = from; i <= n - seq.length; i++) {
      if (b[i] != first) continue;
      var ok = true;
      for (var k = 1; k < seq.length; k++) {
        if (b[i + k] != seq[k]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  bool _startsWith(List<int> seq, int at) {
    if (at + seq.length > n) return false;
    for (var k = 0; k < seq.length; k++) {
      if (b[at + k] != seq[k]) return false;
    }
    return true;
  }

  static const _cdataOpen = [0x3C, 0x21, 0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B]; // <![CDATA[
  static const _cdataClose = [0x5D, 0x5D, 0x3E]; // ]]>
  static const _commentOpen = [0x3C, 0x21, 0x2D, 0x2D]; // <!--
  static const _commentClose = [0x2D, 0x2D, 0x3E]; // -->
  static const _piClose = [0x3F, 0x3E]; // ?>

  static bool _isSpace(int u) => u == 0x20 || u == 0x0A || u == 0x0D || u == 0x09;

  /// Advances to the next event.
  int next() {
    while (_pos < n) {
      final p = _pos;
      if (b[p] != 0x3C) {
        final lt = _indexOf(0x3C, p);
        textStart = p;
        textEnd = lt < 0 ? n : lt;
        _pos = textEnd;
        return text;
      }
      final c1 = p + 1 < n ? b[p + 1] : 0;
      if (c1 == 0x2F) {
        // </name>
        var j = p + 2;
        var local = j;
        while (j < n && b[j] != 0x3E && !_isSpace(b[j])) {
          if (b[j] == 0x3A) local = j + 1;
          j++;
        }
        nameStart = local;
        nameEnd = j;
        final gt = _indexOf(0x3E, j);
        _pos = gt < 0 ? n : gt + 1;
        return endTag;
      }
      if (c1 == 0x3F) {
        final e = _find(_piClose, p + 2);
        _pos = e < 0 ? n : e + 2;
        continue;
      }
      if (c1 == 0x21) {
        if (_startsWith(_cdataOpen, p)) {
          final s = p + _cdataOpen.length;
          final e = _find(_cdataClose, s);
          textStart = s;
          textEnd = e < 0 ? n : e;
          _pos = e < 0 ? n : e + 3;
          return cdata;
        }
        if (_startsWith(_commentOpen, p)) {
          final e = _find(_commentClose, p + 4);
          _pos = e < 0 ? n : e + 3;
          continue;
        }
        // <!DOCTYPE ...> (an internal subset in brackets is skipped too).
        var j = p + 2;
        var depth = 0;
        while (j < n) {
          final u = b[j];
          if (u == 0x5B) depth++;
          if (u == 0x5D) depth--;
          if (u == 0x3E && depth <= 0) break;
          j++;
        }
        _pos = j + 1;
        continue;
      }
      // <name attr="..." ...> or <name .../>
      var j = p + 1;
      var local = j;
      while (j < n) {
        final u = b[j];
        if (u == 0x3E || u == 0x2F || _isSpace(u)) break;
        if (u == 0x3A) local = j + 1;
        j++;
      }
      nameStart = local;
      nameEnd = j;
      var k = j;
      while (k < n) {
        final u = b[k];
        if (u == 0x22 || u == 0x27) {
          final q = _indexOf(u, k + 1);
          k = q < 0 ? n : q + 1;
          continue;
        }
        if (u == 0x3E) break;
        k++;
      }
      selfClosing = k > j && b[k - 1] == 0x2F;
      _attrPos = j;
      _attrEnd = selfClosing ? k - 1 : k;
      _pos = k + 1;
      return startTag;
    }
    return eof;
  }

  /// Moves to the next attribute of the current start tag.
  bool nextAttr() {
    var k = _attrPos;
    final end = _attrEnd;
    while (k < end && _isSpace(b[k])) {
      k++;
    }
    if (k >= end) return false;
    var local = k;
    final s = k;
    while (k < end && b[k] != 0x3D && !_isSpace(b[k])) {
      if (b[k] == 0x3A) local = k + 1;
      k++;
    }
    attrNameStart = local < s ? s : local;
    attrNameEnd = k;
    while (k < end && b[k] != 0x22 && b[k] != 0x27) {
      k++;
    }
    if (k >= end) {
      _attrPos = end;
      return false;
    }
    final q = b[k];
    valueStart = k + 1;
    var e = valueStart;
    while (e < end && b[e] != q) {
      e++;
    }
    valueEnd = e;
    _attrPos = e + 1;
    return true;
  }

  /// Whether bytes [s, e) spell the ASCII string [name].
  bool same(int s, int e, String name) {
    if (e - s != name.length) return false;
    for (var i = 0; i < name.length; i++) {
      if (b[s + i] != name.codeUnitAt(i)) return false;
    }
    return true;
  }

  bool nameIs(String name) => same(nameStart, nameEnd, name);
  bool attrIs(String name) => same(attrNameStart, attrNameEnd, name);

  /// Decodes bytes [s, e) (UTF-8 plus XML entities unless [raw]).
  String str(int s, int e, {bool raw = false}) {
    var ascii = true;
    var amp = false;
    for (var i = s; i < e; i++) {
      final u = b[i];
      if (u >= 0x80) ascii = false;
      if (u == 0x26) amp = true;
    }
    final t = ascii
        ? String.fromCharCodes(b, s, e)
        : utf8.decode(Uint8List.sublistView(b, s, e), allowMalformed: true);
    return amp && !raw ? decodeXmlEntities(t) : t;
  }

  String get value => str(valueStart, valueEnd);
  String get content => str(textStart, textEnd);

  /// Non-negative integer in [s, e) ignoring anything but digits; -1 if none.
  int digits(int s, int e) {
    var v = 0;
    var any = false;
    for (var i = s; i < e; i++) {
      final u = b[i];
      if (u >= 0x30 && u <= 0x39) {
        v = v * 10 + (u - 0x30);
        any = true;
        if (v > 0x7FFFFFFF) return -1;
      }
    }
    return any ? v : -1;
  }
}

/// Decodes `&lt;`, `&#10;`, `&#x1F;` style references.
String decodeXmlEntities(String s) {
  var i = s.indexOf('&');
  if (i < 0) return s;
  final out = StringBuffer(s.substring(0, i));
  while (i < s.length) {
    final ch = s.codeUnitAt(i);
    if (ch != 0x26) {
      final next = s.indexOf('&', i);
      final end = next < 0 ? s.length : next;
      out.write(s.substring(i, end));
      i = end;
      continue;
    }
    final semi = s.indexOf(';', i);
    if (semi < 0 || semi - i > 12) {
      out.write('&');
      i++;
      continue;
    }
    final ent = s.substring(i + 1, semi);
    String? rep;
    switch (ent) {
      case 'lt':
        rep = '<';
      case 'gt':
        rep = '>';
      case 'amp':
        rep = '&';
      case 'quot':
        rep = '"';
      case 'apos':
        rep = "'";
      default:
        if (ent.startsWith('#x') || ent.startsWith('#X')) {
          final code = int.tryParse(ent.substring(2), radix: 16);
          if (code != null && code <= 0x10FFFF) rep = String.fromCharCode(code);
        } else if (ent.startsWith('#')) {
          final code = int.tryParse(ent.substring(1));
          if (code != null && code <= 0x10FFFF) rep = String.fromCharCode(code);
        }
    }
    if (rep == null) {
      out.write('&');
      i++;
      continue;
    }
    out.write(rep);
    i = semi + 1;
  }
  return out.toString();
}

final _escapedChar = RegExp(r'_x([0-9A-Fa-f]{4})_');

/// Decodes OOXML `_xHHHH_` escapes.
String decodeOoxmlEscapes(String s) {
  if (!s.contains('_x')) return s;
  return s.replaceAllMapped(_escapedChar, (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
}

/// Reads `xl/sharedStrings.xml` (phonetic runs skipped), stopping after
/// [limit] strings when given.
List<String> scanSharedStrings(Uint8List? bytes, {int? limit}) {
  final out = <String>[];
  if (bytes == null) return out;
  final x = XmlByteReader(bytes);
  String? cur;
  var inSi = false;
  var inT = false;
  var phonetic = 0;
  while (true) {
    final k = x.next();
    if (k == XmlByteReader.eof) break;
    if (k == XmlByteReader.startTag) {
      if (x.nameIs('si')) {
        if (x.selfClosing) {
          out.add('');
        } else {
          inSi = true;
          cur = null;
        }
      } else if (x.nameIs('rPh')) {
        if (!x.selfClosing) phonetic++;
      } else if (x.nameIs('t')) {
        if (phonetic == 0 && !x.selfClosing) inT = true;
      }
    } else if (k == XmlByteReader.endTag) {
      if (x.nameIs('si')) {
        out.add(decodeOoxmlEscapes(cur ?? ''));
        inSi = false;
        cur = null;
        if (limit != null && out.length >= limit) break;
      } else if (x.nameIs('t')) {
        inT = false;
      } else if (x.nameIs('rPh')) {
        phonetic--;
      }
    } else if (inT && inSi) {
      final s = x.str(x.textStart, x.textEnd, raw: k == XmlByteReader.cdata);
      cur = cur == null ? s : cur + s;
    }
  }
  return out;
}

/// Column width in Excel character units -> pixels.
double xlsxWidthToPx(double w) => (w * 7).roundToDouble().clamp(0, 2000).toDouble();

// Element codes for the worksheet scanner.
const _eC = 1, _eV = 2, _eF = 3, _eT = 4, _eIs = 5, _eRow = 6, _eCol = 7, _eRPh = 8;
const _ePane = 9, _eMergeCell = 10, _eSheetFormatPr = 11, _eSheetData = 12;

// Cell types.
const _tNum = 0, _tS = 1, _tStr = 2, _tInline = 3, _tB = 4, _tE = 5, _tD = 6;

int _elementCode(XmlByteReader x) {
  final s = x.nameStart;
  switch (x.nameEnd - s) {
    case 1:
      switch (x.b[s]) {
        case 0x63:
          return _eC;
        case 0x76:
          return _eV;
        case 0x66:
          return _eF;
        case 0x74:
          return _eT;
      }
    case 2:
      if (x.nameIs('is')) return _eIs;
    case 3:
      if (x.nameIs('row')) return _eRow;
      if (x.nameIs('col')) return _eCol;
      if (x.nameIs('rPh')) return _eRPh;
    case 4:
      if (x.nameIs('pane')) return _ePane;
    case 9:
      if (x.nameIs('mergeCell')) return _eMergeCell;
      if (x.nameIs('sheetData')) return _eSheetData;
    case 13:
      if (x.nameIs('sheetFormatPr')) return _eSheetFormatPr;
  }
  return 0;
}

/// Reads one worksheet part into [sheet]. Formula text is kept exactly as
/// stored in the file (including `_xlfn.` prefixes); shared formulas are
/// expanded per cell. With [maxRows] it stops before the first row at or
/// past that index (a quick preview) and returns true if it did so.
bool scanWorksheet(Uint8List bytes, SheetData sheet, List<String> sst, List<CellStyle> styles,
    {int? maxRows}) {
  final x = XmlByteReader(bytes);
  final b = x.b;
  var curRow = -1;
  var curCol = -1;
  var inSheetData = false;
  // Cell state.
  var inCell = false;
  var cr = 0;
  var cc = 0;
  var ct = _tNum;
  var cs = 0;
  var hasV = false;
  var vStart = 0;
  var vEnd = 0;
  String? vText; // set when the value isn't a single plain chunk
  var vChunks = 0;
  var hasF = false;
  String? fText;
  String? fType;
  String? fRef;
  var fSi = -1;
  StringBuffer? isBuf;
  var inV = false;
  var inF = false;
  var inIs = false;
  var inT = false;
  var phonetic = 0;
  final shared = <int, (FormulaShifter, int, int)>{};
  double? defaultRowPt;
  final defaultStyle = styles.first;

  String valueString() {
    if (vText != null) return vText!;
    return x.str(vStart, vEnd);
  }

  double? valueNumber() {
    if (vText == null) {
      // Fast path: optional minus and up to 15 digits.
      var i = vStart;
      var e = vEnd;
      while (i < e && XmlByteReader._isSpace(b[i])) {
        i++;
      }
      while (e > i && XmlByteReader._isSpace(b[e - 1])) {
        e--;
      }
      if (i >= e) return null;
      var neg = false;
      if (b[i] == 0x2D) {
        neg = true;
        i++;
      }
      if (e > i && e - i <= 15) {
        var v = 0;
        var ok = true;
        for (var k = i; k < e; k++) {
          final u = b[k];
          if (u < 0x30 || u > 0x39) {
            ok = false;
            break;
          }
          v = v * 10 + (u - 0x30);
        }
        if (ok) return neg ? -v.toDouble() : v.toDouble();
      }
    }
    final t = valueString().trim();
    return t.isEmpty ? null : double.tryParse(t);
  }

  void finishCell() {
    Object? value;
    switch (ct) {
      case _tS:
        final idx = vText == null ? x.digits(vStart, vEnd) : (int.tryParse(vText!.trim()) ?? -1);
        value = hasV && idx >= 0 && idx < sst.length ? sst[idx] : '';
      case _tStr:
        value = hasV ? decodeOoxmlEscapes(valueString()) : null;
      case _tInline:
        value = decodeOoxmlEscapes(isBuf?.toString() ?? '');
      case _tB:
        final t = hasV ? valueString().trim() : '';
        value = t == '1' || t == 'true';
      case _tE:
        final t = hasV ? valueString().trim() : '';
        value = t.isEmpty ? null : (CellError.tryParse(t) ?? CellError(t));
      case _tD:
        final dt = hasV ? DateTime.tryParse(valueString().trim()) : null;
        value = dt == null
            ? null
            : NumberFormats.dateTimeToSerial(DateTime.utc(
                dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.millisecond));
      default:
        value = hasV ? valueNumber() : null;
    }
    String? formula;
    String? arrayRef;
    if (hasF && fType != 'dataTable') {
      final text = fText ?? '';
      if (fType == 'shared' && fSi >= 0) {
        if (text.trim().isNotEmpty) {
          formula = text;
          shared[fSi] = (FormulaShifter(text), cr, cc);
        } else {
          final master = shared[fSi];
          if (master != null) formula = master.$1.shift(cr - master.$2, cc - master.$3);
        }
      } else if (text.trim().isNotEmpty) {
        formula = text;
        if (fType == 'array') arrayRef = fRef;
      }
    }
    if (value == null && formula == null && cs == 0) return;
    if (value is double && value == 0) value = 0.0;
    final style = cs >= 0 && cs < styles.length ? styles[cs] : defaultStyle;
    sheet.cells[cellKey(cr, cc)] = Cell(value: value, formula: formula, style: style, arrayRef: arrayRef);
  }

  void appendText(int kind) {
    final rawChunk = kind == XmlByteReader.cdata;
    if (inV) {
      vChunks++;
      if (vChunks == 1 && !rawChunk) {
        vStart = x.textStart;
        vEnd = x.textEnd;
        // Entities need decoding; keep the fast path for plain values.
        for (var i = vStart; i < vEnd; i++) {
          if (b[i] == 0x26 || b[i] >= 0x80) {
            vText = x.content;
            break;
          }
        }
      } else {
        final prev = vText ?? (vChunks > 1 ? x.str(vStart, vEnd) : '');
        vText = prev + x.str(x.textStart, x.textEnd, raw: rawChunk);
      }
    }
    if (inF) {
      final s = x.str(x.textStart, x.textEnd, raw: rawChunk);
      fText = fText == null ? s : fText! + s;
    }
    if (inT) {
      (isBuf ??= StringBuffer()).write(x.str(x.textStart, x.textEnd, raw: rawChunk));
    }
  }

  while (true) {
    final k = x.next();
    if (k == XmlByteReader.eof) break;
    if (k == XmlByteReader.text || k == XmlByteReader.cdata) {
      if (inV || inF || inT) appendText(k);
      continue;
    }
    final code = _elementCode(x);
    if (code == 0) continue;
    if (k == XmlByteReader.endTag) {
      switch (code) {
        case _eC:
          if (inCell) finishCell();
          inCell = false;
          inV = false;
          inF = false;
          inIs = false;
        case _eV:
          inV = false;
        case _eF:
          inF = false;
        case _eIs:
          inIs = false;
        case _eT:
          inT = false;
        case _eRPh:
          phonetic--;
        case _eRow:
          curCol = -1;
        case _eSheetData:
          inSheetData = false;
      }
      continue;
    }
    // Start tags.
    switch (code) {
      case _eSheetData:
        if (!x.selfClosing) inSheetData = true;
      case _eC:
        if (!inSheetData) continue;
        var hasRef = false;
        var row = 0;
        var col = 0;
        ct = _tNum;
        cs = 0;
        while (x.nextAttr()) {
          final an = x.attrNameEnd - x.attrNameStart;
          if (an != 1) continue;
          final a = b[x.attrNameStart];
          if (a == 0x72) {
            // r="B12"
            var i = x.valueStart;
            final e = x.valueEnd;
            var c = 0;
            while (i < e) {
              final u = b[i];
              if (u >= 0x41 && u <= 0x5A) {
                c = c * 26 + (u - 0x40);
              } else if (u >= 0x61 && u <= 0x7A) {
                c = c * 26 + (u - 0x60);
              } else if (u != 0x24) {
                break;
              }
              i++;
            }
            var r = 0;
            var ok = c > 0 && i < e;
            for (; i < e && ok; i++) {
              final u = b[i];
              if (u >= 0x30 && u <= 0x39) {
                r = r * 10 + (u - 0x30);
                if (r > kMaxRows) ok = false;
              } else if (u != 0x24) {
                ok = false;
              }
            }
            if (ok && r > 0) {
              hasRef = true;
              row = r - 1;
              col = c - 1;
            }
          } else if (a == 0x74) {
            // t="s" | "str" | "inlineStr" | "b" | "e" | "d" | "n"
            final vs = x.valueStart;
            final vl = x.valueEnd - vs;
            if (vl == 1) {
              ct = switch (b[vs]) {
                0x73 => _tS,
                0x62 => _tB,
                0x65 => _tE,
                0x64 => _tD,
                _ => _tNum,
              };
            } else if (x.same(vs, x.valueEnd, 'str')) {
              ct = _tStr;
            } else if (x.same(vs, x.valueEnd, 'inlineStr')) {
              ct = _tInline;
            } else {
              ct = _tNum;
            }
          } else if (a == 0x73) {
            cs = x.digits(x.valueStart, x.valueEnd);
            if (cs < 0) cs = 0;
          }
        }
        if (hasRef) {
          cr = row;
          cc = col;
          if (curRow < 0) curRow = cr;
        } else {
          cr = curRow < 0 ? 0 : curRow;
          cc = curCol + 1;
        }
        curCol = cc;
        hasV = false;
        vText = null;
        vChunks = 0;
        vStart = vEnd = 0;
        hasF = false;
        fText = null;
        fType = null;
        fRef = null;
        fSi = -1;
        isBuf = null;
        if (cr >= kMaxRows || cc >= kMaxCols) {
          inCell = false;
          continue;
        }
        inCell = true;
        if (x.selfClosing) {
          finishCell();
          inCell = false;
        }
      case _eV:
        if (inCell) {
          hasV = true;
          inV = !x.selfClosing;
        }
      case _eF:
        if (inCell) {
          hasF = true;
          while (x.nextAttr()) {
            if (x.attrIs('t')) {
              fType = x.value;
            } else if (x.attrIs('ref')) {
              fRef = x.value;
            } else if (x.attrIs('si')) {
              fSi = x.digits(x.valueStart, x.valueEnd);
            }
          }
          inF = !x.selfClosing;
        }
      case _eIs:
        if (inCell) inIs = !x.selfClosing;
      case _eRPh:
        if (!x.selfClosing) phonetic++;
      case _eT:
        if (inIs && phonetic == 0 && !x.selfClosing) inT = true;
      case _eRow:
        if (!inSheetData) continue;
        var r = -1;
        String? ht;
        var custom = false;
        var hidden = false;
        while (x.nextAttr()) {
          if (x.attrIs('r')) {
            r = x.digits(x.valueStart, x.valueEnd);
          } else if (x.attrIs('ht')) {
            ht = x.value;
          } else if (x.attrIs('customHeight')) {
            custom = x.same(x.valueStart, x.valueEnd, '1') || x.same(x.valueStart, x.valueEnd, 'true');
          } else if (x.attrIs('hidden')) {
            hidden = x.same(x.valueStart, x.valueEnd, '1') || x.same(x.valueStart, x.valueEnd, 'true');
          }
        }
        curRow = r < 0 ? curRow + 1 : r - 1;
        curCol = -1;
        if (maxRows != null && curRow >= maxRows) return true;
        if (curRow >= 0 && curRow < kMaxRows) {
          final h = double.tryParse(ht ?? '');
          if (h != null && (custom || defaultRowPt == null || (h - defaultRowPt).abs() > 0.01)) {
            sheet.rowHeights[curRow] = (h * 4 / 3).roundToDouble();
          }
          if (hidden) sheet.hiddenRows.add(curRow);
        }
      case _eCol:
        if (inSheetData) continue;
        int? min;
        int? max;
        double? w;
        var hidden = false;
        while (x.nextAttr()) {
          if (x.attrIs('min')) {
            min = int.tryParse(x.value);
          } else if (x.attrIs('max')) {
            max = int.tryParse(x.value);
          } else if (x.attrIs('width')) {
            w = double.tryParse(x.value);
          } else if (x.attrIs('hidden')) {
            hidden = x.same(x.valueStart, x.valueEnd, '1') || x.same(x.valueStart, x.valueEnd, 'true');
          }
        }
        if (min != null && max != null && min >= 1) {
          final px = w == null ? null : xlsxWidthToPx(w);
          final last = max > 2048 ? 2048 : max;
          for (var c = min - 1; c < last && c < kMaxCols; c++) {
            if (px != null) sheet.colWidths[c] = px;
            if (hidden) sheet.hiddenCols.add(c);
          }
          if (max >= kMaxCols && px != null && !hidden) sheet.defaultColWidth = px;
        }
      case _eSheetFormatPr:
        double? dh;
        double? dw;
        double? base;
        while (x.nextAttr()) {
          if (x.attrIs('defaultRowHeight')) {
            dh = double.tryParse(x.value);
          } else if (x.attrIs('defaultColWidth')) {
            dw = double.tryParse(x.value);
          } else if (x.attrIs('baseColWidth')) {
            base = double.tryParse(x.value);
          }
        }
        if (dh != null && dh > 0) {
          defaultRowPt = dh;
          sheet.defaultRowHeight = (dh * 4 / 3).roundToDouble();
        }
        if (dw != null && dw > 0) {
          sheet.defaultColWidth = xlsxWidthToPx(dw);
        } else if (base != null && base > 0) {
          sheet.defaultColWidth = xlsxWidthToPx(base + 1.14);
        }
      case _ePane:
        String? state;
        double? xs;
        double? ys;
        while (x.nextAttr()) {
          if (x.attrIs('state')) {
            state = x.value;
          } else if (x.attrIs('xSplit')) {
            xs = double.tryParse(x.value);
          } else if (x.attrIs('ySplit')) {
            ys = double.tryParse(x.value);
          }
        }
        if (state == 'frozen' || state == 'frozenSplit') {
          sheet.frozenCols = (xs ?? 0).round().clamp(0, 1000);
          sheet.frozenRows = (ys ?? 0).round().clamp(0, 10000);
        }
      case _eMergeCell:
        while (x.nextAttr()) {
          if (x.attrIs('ref')) {
            final range = CellRange.parse(x.value);
            if (range != null && !range.isSingle) sheet.merges.add(range);
          }
        }
    }
  }
  return false;
}
