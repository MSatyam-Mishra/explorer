import 'dart:convert';
import 'dart:typed_data';

import 'package:explorer/core/formats/cfb_reader.dart';

import '../model/number_format.dart';
import '../model/workbook.dart';

/// RFC 4180 style delimited text reader/writer.
abstract final class CsvCodec {
  static const candidates = [',', ';', '\t', '|'];

  /// Decodes bytes, remembering the encoding so saving can keep it.
  static (String, TextEncodingKind) decode(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return (utf8.decode(bytes.sublist(3), allowMalformed: true), TextEncodingKind.utf8Bom);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return (decodeTextBytes(bytes), TextEncodingKind.utf16le);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return (decodeTextBytes(bytes), TextEncodingKind.utf16be);
    }
    try {
      return (utf8.decode(bytes), TextEncodingKind.utf8);
    } on FormatException {
      return (decodeCp1252(bytes), TextEncodingKind.cp1252);
    }
  }

  static Uint8List encode(String text, TextEncodingKind kind) {
    switch (kind) {
      case TextEncodingKind.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case TextEncodingKind.utf8Bom:
        return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
      case TextEncodingKind.utf16le:
        final out = BytesBuilder()..add([0xFF, 0xFE]);
        for (final u in text.codeUnits) {
          out
            ..addByte(u & 0xFF)
            ..addByte(u >> 8);
        }
        return out.takeBytes();
      case TextEncodingKind.utf16be:
        final out = BytesBuilder()..add([0xFE, 0xFF]);
        for (final u in text.codeUnits) {
          out
            ..addByte(u >> 8)
            ..addByte(u & 0xFF);
        }
        return out.takeBytes();
      case TextEncodingKind.cp1252:
        final encoded = _encodeCp1252(text);
        // Fall back to UTF-8 with BOM when characters don't fit cp1252.
        return encoded ?? Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
    }
  }

  static Uint8List? _encodeCp1252(String text) {
    const high = [
      0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
      0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
      0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ];
    final reverse = <int, int>{for (var i = 0; i < high.length; i++) high[i]: 0x80 + i};
    final out = Uint8List(text.length);
    var i = 0;
    for (final u in text.codeUnits) {
      if (u < 0x80 || (u >= 0xA0 && u <= 0xFF)) {
        out[i++] = u;
      } else {
        final b = reverse[u];
        if (b == null) return null;
        out[i++] = b;
      }
    }
    return out;
  }

  /// Parses delimited [text] into rows of fields.
  static List<List<String>> parse(String text, String delimiter, {int? maxRows}) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    final d = delimiter.codeUnitAt(0);
    var inQuotes = false;
    var fieldStart = true;
    var i = 0;
    final n = text.length;
    while (i < n) {
      final c = text.codeUnitAt(i);
      if (inQuotes) {
        if (c == 0x22) {
          if (i + 1 < n && text.codeUnitAt(i + 1) == 0x22) {
            field.writeCharCode(0x22);
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.writeCharCode(c);
        i++;
        continue;
      }
      if (c == 0x22 && fieldStart) {
        inQuotes = true;
        fieldStart = false;
        i++;
        continue;
      }
      if (c == d) {
        row.add(field.toString());
        field.clear();
        fieldStart = true;
        i++;
        continue;
      }
      if (c == 0x0D || c == 0x0A) {
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
        fieldStart = true;
        if (c == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
        i++;
        if (maxRows != null && rows.length >= maxRows) return rows;
        continue;
      }
      field.writeCharCode(c);
      fieldStart = false;
      i++;
    }
    if (field.isNotEmpty || row.isNotEmpty || !fieldStart) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  /// Picks the delimiter that splits the first lines most consistently.
  static String detectDelimiter(String text, {String? hint}) {
    final sample = text.length > 65536 ? text.substring(0, 65536) : text;
    String? best;
    var bestScore = -1.0;
    final order = [if (hint != null) hint, ...candidates.where((c) => c != hint)];
    for (final d in order) {
      final rows = parse(sample, d, maxRows: 60);
      if (rows.length > 1 && sample.length == 65536) rows.removeLast();
      if (rows.isEmpty) continue;
      final counts = <int, int>{};
      for (final r in rows) {
        if (r.length == 1 && r.first.isEmpty) continue;
        counts[r.length] = (counts[r.length] ?? 0) + 1;
      }
      if (counts.isEmpty) continue;
      final mode = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
      if (mode.key <= 1) continue;
      final consistency = mode.value / rows.length;
      var score = consistency * 10 + (mode.key > 20 ? 20 : mode.key) * 0.1;
      if (d == hint) score += 1.5;
      if (score > bestScore + 1e-9) {
        bestScore = score;
        best = d;
      }
    }
    return best ?? hint ?? ',';
  }

  static String? hintForExtension(String ext) {
    switch (ext.toLowerCase().replaceFirst('.', '')) {
      case 'tsv':
      case 'tab':
        return '\t';
      case 'psv':
        return '|';
      case 'csv':
        return ',';
    }
    return null;
  }

  static final _plainNumber = RegExp(r'^-?(0|[1-9]\d*)(\.\d+)?$');

  /// Converts a field to a cell: plain decimal numbers become numbers (with
  /// a format that keeps trailing zeros), everything else stays text.
  static Cell? fieldToCell(String f) {
    if (f.isEmpty) return null;
    if (f.length <= 17 && _plainNumber.hasMatch(f)) {
      final digits = f.replaceAll(RegExp(r'[-.]'), '').replaceFirst(RegExp(r'^0+'), '');
      if (digits.length <= 15) {
        final v = double.parse(f);
        final dot = f.indexOf('.');
        if (dot >= 0) {
          final decimals = f.length - dot - 1;
          if (NumberFormats.numberToPlainString(v) != f) {
            return Cell(value: v, style: CellStyle(numFmt: '0.${'0' * decimals}'));
          }
        }
        return Cell(value: v);
      }
    }
    return Cell(value: f);
  }

  /// Builds a workbook from delimited text.
  static Workbook read(Uint8List bytes, {required String sheetName, String? delimiter,
      String? extHint, bool? hasHeader}) {
    final (text, enc) = decode(bytes);
    final d = delimiter ?? detectDelimiter(text, hint: hintForExtension(extHint ?? ''));
    final rows = parse(text, d);
    final newline = text.contains('\r\n') ? '\r\n' : (text.contains('\n') ? '\n' : '\r\n');
    final sheet = SheetData(name: sheetName.isEmpty ? 'Sheet1' : sheetName);
    var maxLen = List<int>.filled(0, 0, growable: true);
    for (var r = 0; r < rows.length && r < kMaxRows; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length && c < kMaxCols; c++) {
        final cell = fieldToCell(row[c]);
        if (cell != null) sheet.cells[cellKey(r, c)] = cell;
        if (r < 200) {
          if (maxLen.length <= c) maxLen.addAll(List.filled(c + 1 - maxLen.length, 0));
          final l = row[c].length;
          if (l > maxLen[c]) maxLen[c] = l;
        }
      }
    }
    // Widen columns to fit typical content.
    for (var c = 0; c < maxLen.length; c++) {
      final w = (maxLen[c] * 7.5 + 12).clamp(kDefaultColWidth, 320.0);
      if (w > kDefaultColWidth) sheet.colWidths[c] = w.toDouble();
    }
    final header = hasHeader ?? _guessHeader(rows);
    if (header) sheet.frozenRows = 1;
    sheet.invalidateBounds();
    return Workbook(
      sheets: [sheet],
      format: SpreadsheetFormat.csv,
      csv: CsvSettings(delimiter: d, hasHeader: header, encoding: enc, newline: newline),
    );
  }

  static bool _guessHeader(List<List<String>> rows) {
    if (rows.length < 2) return false;
    final first = rows.first;
    if (first.length < 2) return false;
    final allText = first.every((f) => f.isNotEmpty && !_plainNumber.hasMatch(f));
    if (!allText) return false;
    final second = rows[1];
    return second.any((f) => _plainNumber.hasMatch(f));
  }

  static String quote(String field, String delimiter) {
    final needs = field.contains(delimiter) ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r') ||
        (field.isNotEmpty && (field.startsWith(' ') || field.endsWith(' ')));
    if (!needs) return field;
    return '"${field.replaceAll('"', '""')}"';
  }

  /// Text for a cell when exporting (displayed value, like Excel does).
  static String cellText(Cell? cell, {bool date1904 = false}) {
    if (cell == null) return '';
    final v = cell.value;
    if (v == null) return '';
    if (v is double) {
      if (cell.style.numFmt == 'General') return NumberFormats.numberToPlainString(v);
      return NumberFormats.format(v, cell.style.numFmt, date1904: date1904).text.trim();
    }
    return NumberFormats.format(v, cell.style.numFmt, date1904: date1904).text;
  }

  /// Writes [sheet] as delimited text.
  static String write(SheetData sheet, {required String delimiter, String newline = '\r\n',
      bool date1904 = false}) {
    final rows = sheet.usedRows;
    final cols = sheet.usedCols;
    final b = StringBuffer();
    for (var r = 0; r < rows; r++) {
      var last = -1;
      for (var c = cols - 1; c >= 0; c--) {
        final cell = sheet.cells[cellKey(r, c)];
        if (cell != null && cell.value != null) {
          last = c;
          break;
        }
      }
      // Keep a rectangular shape for readers that expect it.
      final width = cols;
      for (var c = 0; c < width; c++) {
        if (c > 0) b.write(delimiter);
        if (c <= last) {
          b.write(quote(cellText(sheet.cells[cellKey(r, c)], date1904: date1904), delimiter));
        }
      }
      b.write(newline);
    }
    return b.toString();
  }
}
