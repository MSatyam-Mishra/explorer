import 'dart:typed_data';

import '../formula/tokenizer.dart';
import '../model/cell.dart';

/// BIFF8 built-in function table: index -> (name, fixed arg count or -1).
const Map<int, (String, int)> biffFunctions = {
  0: ('COUNT', -1), 1: ('IF', -1), 2: ('ISNA', 1), 3: ('ISERROR', 1), //
  4: ('SUM', -1), 5: ('AVERAGE', -1), 6: ('MIN', -1), 7: ('MAX', -1),
  8: ('ROW', -1), 9: ('COLUMN', -1), 10: ('NA', 0), 11: ('NPV', -1),
  12: ('STDEV', -1), 13: ('DOLLAR', -1), 14: ('FIXED', -1), 15: ('SIN', 1),
  16: ('COS', 1), 17: ('TAN', 1), 18: ('ATAN', 1), 19: ('PI', 0),
  20: ('SQRT', 1), 21: ('EXP', 1), 22: ('LN', 1), 23: ('LOG10', 1),
  24: ('ABS', 1), 25: ('INT', 1), 26: ('SIGN', 1), 27: ('ROUND', 2),
  28: ('LOOKUP', -1), 29: ('INDEX', -1), 30: ('REPT', 2), 31: ('MID', 3),
  32: ('LEN', 1), 33: ('VALUE', 1), 34: ('TRUE', 0), 35: ('FALSE', 0),
  36: ('AND', -1), 37: ('OR', -1), 38: ('NOT', 1), 39: ('MOD', 2),
  40: ('DCOUNT', 3), 41: ('DSUM', 3), 42: ('DAVERAGE', 3), 43: ('DMIN', 3),
  44: ('DMAX', 3), 45: ('DSTDEV', 3), 46: ('VAR', -1), 47: ('DVAR', 3),
  48: ('TEXT', 2), 49: ('LINEST', -1), 50: ('TREND', -1), 51: ('LOGEST', -1),
  52: ('GROWTH', -1), 56: ('PV', -1), 57: ('FV', -1), 58: ('NPER', -1),
  59: ('PMT', -1), 60: ('RATE', -1), 61: ('MIRR', 3), 62: ('IRR', -1),
  63: ('RAND', 0), 64: ('MATCH', -1), 65: ('DATE', 3), 66: ('TIME', 3),
  67: ('DAY', 1), 68: ('MONTH', 1), 69: ('YEAR', 1), 70: ('WEEKDAY', -1),
  71: ('HOUR', 1), 72: ('MINUTE', 1), 73: ('SECOND', 1), 74: ('NOW', 0),
  75: ('AREAS', 1), 76: ('ROWS', 1), 77: ('COLUMNS', 1), 78: ('OFFSET', -1),
  82: ('SEARCH', -1), 83: ('TRANSPOSE', 1), 86: ('TYPE', 1), 97: ('ATAN2', 2),
  98: ('ASIN', 1), 99: ('ACOS', 1), 100: ('CHOOSE', -1), 101: ('HLOOKUP', -1),
  102: ('VLOOKUP', -1), 105: ('ISREF', 1), 109: ('LOG', -1), 111: ('CHAR', 1),
  112: ('LOWER', 1), 113: ('UPPER', 1), 114: ('PROPER', 1), 115: ('LEFT', -1),
  116: ('RIGHT', -1), 117: ('EXACT', 2), 118: ('TRIM', 1), 119: ('REPLACE', 4),
  120: ('SUBSTITUTE', -1), 121: ('CODE', 1), 124: ('FIND', -1), 125: ('CELL', -1),
  126: ('ISERR', 1), 127: ('ISTEXT', 1), 128: ('ISNUMBER', 1), 129: ('ISBLANK', 1),
  130: ('T', 1), 131: ('N', 1), 140: ('DATEVALUE', 1), 141: ('TIMEVALUE', 1),
  142: ('SLN', 3), 143: ('SYD', 4), 144: ('DDB', -1), 148: ('INDIRECT', -1),
  162: ('CLEAN', 1), 163: ('MDETERM', 1), 164: ('MINVERSE', 1), 165: ('MMULT', 2),
  167: ('IPMT', -1), 168: ('PPMT', -1), 169: ('COUNTA', -1), 183: ('PRODUCT', -1),
  184: ('FACT', 1), 189: ('DPRODUCT', 3), 190: ('ISNONTEXT', 1), 193: ('STDEVP', -1),
  194: ('VARP', -1), 195: ('DSTDEVP', 3), 196: ('DVARP', 3), 197: ('TRUNC', -1),
  198: ('ISLOGICAL', 1), 199: ('DCOUNTA', 3), 204: ('USDOLLAR', -1),
  205: ('FINDB', -1), 206: ('SEARCHB', -1), 207: ('REPLACEB', 4), 208: ('LEFTB', -1),
  209: ('RIGHTB', -1), 210: ('MIDB', 3), 211: ('LENB', 1), 212: ('ROUNDUP', 2),
  213: ('ROUNDDOWN', 2), 214: ('ASC', 1), 215: ('DBCS', 1), 216: ('RANK', -1),
  219: ('ADDRESS', -1), 220: ('DAYS360', -1), 221: ('TODAY', 0), 222: ('VDB', -1),
  227: ('MEDIAN', -1), 228: ('SUMPRODUCT', -1), 229: ('SINH', 1), 230: ('COSH', 1),
  231: ('TANH', 1), 232: ('ASINH', 1), 233: ('ACOSH', 1), 234: ('ATANH', 1),
  235: ('DGET', 3), 244: ('INFO', 1), 247: ('DB', -1), 252: ('FREQUENCY', 2),
  261: ('ERROR.TYPE', 1), 269: ('AVEDEV', -1), 270: ('BETADIST', -1),
  271: ('GAMMALN', 1), 272: ('BETAINV', -1), 273: ('BINOMDIST', 4),
  274: ('CHIDIST', 2), 275: ('CHIINV', 2), 276: ('COMBIN', 2), 277: ('CONFIDENCE', 3),
  278: ('CRITBINOM', 3), 279: ('EVEN', 1), 280: ('EXPONDIST', 3), 281: ('FDIST', 3),
  282: ('FINV', 3), 283: ('FISHER', 1), 284: ('FISHERINV', 1), 285: ('FLOOR', 2),
  286: ('GAMMADIST', 4), 287: ('GAMMAINV', 3), 288: ('CEILING', 2),
  289: ('HYPGEOMDIST', 4), 290: ('LOGNORMDIST', 3), 291: ('LOGINV', 3),
  292: ('NEGBINOMDIST', 3), 293: ('NORMDIST', 4), 294: ('NORMSDIST', 1),
  295: ('NORMINV', 3), 296: ('NORMSINV', 1), 297: ('STANDARDIZE', 3), 298: ('ODD', 1),
  299: ('PERMUT', 2), 300: ('POISSON', 3), 301: ('TDIST', 3), 302: ('WEIBULL', 4),
  303: ('SUMXMY2', 2), 304: ('SUMX2MY2', 2), 305: ('SUMX2PY2', 2), 306: ('CHITEST', 2),
  307: ('CORREL', 2), 308: ('COVAR', 2), 309: ('FORECAST', 3), 310: ('FTEST', 2),
  311: ('INTERCEPT', 2), 312: ('PEARSON', 2), 313: ('RSQ', 2), 314: ('STEYX', 2),
  315: ('SLOPE', 2), 316: ('TTEST', 4), 317: ('PROB', -1), 318: ('DEVSQ', -1),
  319: ('GEOMEAN', -1), 320: ('HARMEAN', -1), 321: ('SUMSQ', -1), 322: ('KURT', -1),
  323: ('SKEW', -1), 324: ('ZTEST', -1), 325: ('LARGE', 2), 326: ('SMALL', 2),
  327: ('QUARTILE', 2), 328: ('PERCENTILE', 2), 329: ('PERCENTRANK', -1),
  330: ('MODE', -1), 331: ('TRIMMEAN', 2), 332: ('TINV', 2), 336: ('CONCATENATE', -1),
  337: ('POWER', 2), 342: ('RADIANS', 1), 343: ('DEGREES', 1), 344: ('SUBTOTAL', -1),
  345: ('SUMIF', -1), 346: ('COUNTIF', 2), 347: ('COUNTBLANK', 1), 350: ('ISPMT', 4),
  354: ('ROMAN', -1), 358: ('GETPIVOTDATA', -1), 359: ('HYPERLINK', -1),
  360: ('PHONETIC', 1), 361: ('AVERAGEA', -1), 362: ('MAXA', -1), 363: ('MINA', -1),
  364: ('STDEVPA', -1), 365: ('VARPA', -1), 366: ('STDEVA', -1), 367: ('VARA', -1),
};

const _biffErrors = {
  0x00: '#NULL!', 0x07: '#DIV/0!', 0x0F: '#VALUE!', 0x17: '#REF!', //
  0x1D: '#NAME?', 0x24: '#NUM!', 0x2A: '#N/A',
};

String biffErrorCode(int code) => _biffErrors[code] ?? '#N/A';

class _Unsupported implements Exception {}

/// Converts BIFF8 parsed-expression tokens to formula text. Returns null for
/// constructs it doesn't understand (the cell then keeps only its value).
class BiffFormulaDecoder {
  BiffFormulaDecoder({required this.sheetNameForXti});

  /// Maps an EXTERNSHEET index to a sheet name (null when external).
  final String? Function(int ixti) sheetNameForXti;

  String? decode(Uint8List rgce, {required int row, required int col, bool shared = false}) {
    try {
      return _decode(rgce, row, col, shared);
    } on _Unsupported {
      return null;
    } on RangeError {
      return null;
    }
  }

  String _decode(Uint8List d, int baseRow, int baseCol, bool shared) {
    final bd = ByteData.sublistView(d);
    final stack = <String>[];
    var i = 0;
    String pop() {
      if (stack.isEmpty) throw _Unsupported();
      return stack.removeLast();
    }

    String cellRef(int rw, int colField, {bool relativeOffsets = false}) {
      final colRel = (colField & 0x4000) != 0;
      final rowRel = (colField & 0x8000) != 0;
      var c = colField & 0xFF;
      var r = rw;
      if (relativeOffsets) {
        if (rowRel) r = (baseRow + (rw >= 0x8000 ? rw - 0x10000 : rw)) & 0xFFFF;
        if (colRel) c = (baseCol + (c >= 0x80 ? c - 0x100 : c)) & 0xFF;
      }
      if (r < 0 || r >= kMaxRows || c < 0) throw _Unsupported();
      return '${colRel ? '' : r'$'}${columnName(c)}${rowRel ? '' : r'$'}${r + 1}';
    }

    while (i < d.length) {
      final ptg = d[i];
      i++;
      final base = ptg >= 0x20 ? (ptg & 0x1F) | 0x20 : ptg;
      switch (base) {
        case 0x03:
        case 0x04:
        case 0x05:
        case 0x06:
        case 0x07:
        case 0x08:
        case 0x09:
        case 0x0A:
        case 0x0B:
        case 0x0C:
        case 0x0D:
        case 0x0E:
          const ops = {
            0x03: '+', 0x04: '-', 0x05: '*', 0x06: '/', 0x07: '^', 0x08: '&', //
            0x09: '<', 0x0A: '<=', 0x0B: '=', 0x0C: '>=', 0x0D: '>', 0x0E: '<>',
          };
          final b = pop();
          final a = pop();
          stack.add('$a${ops[base]}$b');
        case 0x0F: // intersection
          final b = pop();
          final a = pop();
          stack.add('$a $b');
        case 0x10: // union
          final b = pop();
          final a = pop();
          stack.add('$a,$b');
        case 0x11: // range
          final b = pop();
          final a = pop();
          stack.add('$a:$b');
        case 0x12:
          stack.add('+${pop()}');
        case 0x13:
          stack.add('-${pop()}');
        case 0x14:
          stack.add('${pop()}%');
        case 0x15:
          stack.add('(${pop()})');
        case 0x16:
          stack.add('');
        case 0x17: // ptgStr
          final cch = d[i];
          final flags = d[i + 1];
          i += 2;
          String s;
          if ((flags & 1) != 0) {
            final units = <int>[];
            for (var k = 0; k < cch; k++) {
              units.add(bd.getUint16(i + k * 2, Endian.little));
            }
            s = String.fromCharCodes(units);
            i += cch * 2;
          } else {
            s = String.fromCharCodes(d.sublist(i, i + cch));
            i += cch;
          }
          stack.add('"${s.replaceAll('"', '""')}"');
        case 0x19: // ptgAttr
          final grbit = d[i];
          i++;
          if ((grbit & 0x04) != 0) {
            final cases = bd.getUint16(i, Endian.little);
            i += 2 + (cases + 1) * 2;
          } else {
            i += 2;
          }
          if ((grbit & 0x10) != 0) stack.add('SUM(${pop()})');
        case 0x1C:
          stack.add(biffErrorCode(d[i]));
          i++;
        case 0x1D:
          stack.add(d[i] != 0 ? 'TRUE' : 'FALSE');
          i++;
        case 0x1E:
          stack.add(bd.getUint16(i, Endian.little).toString());
          i += 2;
        case 0x1F:
          final v = bd.getFloat64(i, Endian.little);
          i += 8;
          stack.add(v == v.truncateToDouble() && v.abs() < 1e15
              ? v.toInt().toString()
              : v.toString());
        case 0x21: // ptgFunc
          final idx = bd.getUint16(i, Endian.little);
          i += 2;
          final f = biffFunctions[idx];
          if (f == null || f.$2 < 0) throw _Unsupported();
          final args = <String>[];
          for (var k = 0; k < f.$2; k++) {
            args.insert(0, pop());
          }
          stack.add('${f.$1}(${args.join(',')})');
        case 0x22: // ptgFuncVar
          final argc = d[i] & 0x7F;
          final idx = bd.getUint16(i + 1, Endian.little) & 0x7FFF;
          i += 3;
          final f = biffFunctions[idx];
          if (f == null) throw _Unsupported();
          final args = <String>[];
          for (var k = 0; k < argc; k++) {
            args.insert(0, pop());
          }
          stack.add('${f.$1}(${args.join(',')})');
        case 0x24: // ptgRef
          final rw = bd.getUint16(i, Endian.little);
          final col = bd.getUint16(i + 2, Endian.little);
          i += 4;
          stack.add(cellRef(rw, col));
        case 0x25: // ptgArea
          final r1 = bd.getUint16(i, Endian.little);
          final r2 = bd.getUint16(i + 2, Endian.little);
          final c1 = bd.getUint16(i + 4, Endian.little);
          final c2 = bd.getUint16(i + 6, Endian.little);
          i += 8;
          stack.add('${cellRef(r1, c1)}:${cellRef(r2, c2)}');
        case 0x26: // ptgMemArea
          i += 6;
        case 0x27: // ptgMemErr
          i += 6;
        case 0x28: // ptgMemNoMem
          i += 6;
        case 0x29: // ptgMemFunc
          i += 2;
        case 0x2A: // ptgRefErr
          i += 4;
          stack.add('#REF!');
        case 0x2B: // ptgAreaErr
          i += 8;
          stack.add('#REF!');
        case 0x2C: // ptgRefN
          if (!shared) throw _Unsupported();
          final rw = bd.getUint16(i, Endian.little);
          final col = bd.getUint16(i + 2, Endian.little);
          i += 4;
          stack.add(cellRef(rw, col, relativeOffsets: true));
        case 0x2D: // ptgAreaN
          if (!shared) throw _Unsupported();
          final r1 = bd.getUint16(i, Endian.little);
          final r2 = bd.getUint16(i + 2, Endian.little);
          final c1 = bd.getUint16(i + 4, Endian.little);
          final c2 = bd.getUint16(i + 6, Endian.little);
          i += 8;
          stack.add(
              '${cellRef(r1, c1, relativeOffsets: true)}:${cellRef(r2, c2, relativeOffsets: true)}');
        case 0x3A: // ptgRef3d
          final ixti = bd.getUint16(i, Endian.little);
          final rw = bd.getUint16(i + 2, Endian.little);
          final col = bd.getUint16(i + 4, Endian.little);
          i += 6;
          final sheet = sheetNameForXti(ixti);
          if (sheet == null) throw _Unsupported();
          stack.add('${quoteSheetName(sheet)}!${cellRef(rw, col, relativeOffsets: shared)}');
        case 0x3B: // ptgArea3d
          final ixti = bd.getUint16(i, Endian.little);
          final r1 = bd.getUint16(i + 2, Endian.little);
          final r2 = bd.getUint16(i + 4, Endian.little);
          final c1 = bd.getUint16(i + 6, Endian.little);
          final c2 = bd.getUint16(i + 8, Endian.little);
          i += 10;
          final sheet = sheetNameForXti(ixti);
          if (sheet == null) throw _Unsupported();
          stack.add('${quoteSheetName(sheet)}!${cellRef(r1, c1, relativeOffsets: shared)}:'
              '${cellRef(r2, c2, relativeOffsets: shared)}');
        case 0x3C: // ptgRefErr3d
          i += 6;
          stack.add('#REF!');
        case 0x3D: // ptgAreaErr3d
          i += 10;
          stack.add('#REF!');
        default:
          // ptgExp, ptgTbl, ptgArray, ptgName, ptgNameX, ptgExtend...
          throw _Unsupported();
      }
    }
    if (stack.length != 1) throw _Unsupported();
    return stack.single;
  }
}
