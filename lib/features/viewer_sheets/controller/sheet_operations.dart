part of 'spreadsheet_controller.dart';

/// Editing operations (all undoable).
extension SheetOperations on SpreadsheetController {
  /// The selection clamped to the used area (avoids touching a million
  /// empty cells for whole-row/column selections).
  CellRange get _usedSelection {
    final s = selection;
    final r2 = math.min(s.r2, math.max(sheet.usedRows - 1, s.r1));
    final c2 = math.min(s.c2, math.max(sheet.usedCols - 1, s.c1));
    return CellRange(s.r1, s.c1, r2, c2);
  }

  Iterable<int> _keysIn(CellRange r) sync* {
    final s = sheet;
    if (r.area <= s.cells.length * 2 || r.area <= 20000) {
      for (var y = r.r1; y <= r.r2; y++) {
        for (var x = r.c1; x <= r.c2; x++) {
          yield cellKey(y, x);
        }
      }
    } else {
      final keys = s.cells.keys.where((k) => r.contains(keyRow(k), keyCol(k))).toList();
      yield* keys;
    }
  }

  // --- clear & format --------------------------------------------------------

  void clearSelection({bool formats = false}) {
    if (editing) cancelEdit();
    final s = sheet;
    final after = <int, Cell?>{};
    for (final k in _keysIn(_usedSelection)) {
      final c = s.cells[k];
      if (c == null) continue;
      if (formats) {
        after[k] = null;
      } else if (c.hasContent) {
        after[k] = Cell(style: c.style);
      }
    }
    setCells(s, after, formats ? 'Clear all' : 'Clear contents');
  }

  void applyStyle(CellStyle Function(CellStyle) transform, String label) {
    if (editing) commitEdit();
    final s = sheet;
    final after = <int, Cell?>{};
    final range = _usedSelection;
    final sel = selection;
    final positional = range.area <= 200000;
    if (positional) {
      for (var y = range.r1; y <= range.r2; y++) {
        for (var x = range.c1; x <= range.c2; x++) {
          final k = cellKey(y, x);
          final c = s.cells[k];
          final next = transform(c?.style ?? CellStyle.plain);
          after[k] = c == null ? Cell(style: next) : c.withStyle(next);
        }
      }
    } else {
      s.cells.forEach((k, c) {
        if (sel.contains(keyRow(k), keyCol(k))) after[k] = c.withStyle(transform(c.style));
      });
    }
    // Make sure the active cell gets the style even outside the used area.
    final ak = cellKey(selRow, selCol);
    if (!after.containsKey(ak)) {
      final c = s.cells[ak];
      final next = transform(c?.style ?? CellStyle.plain);
      after[ak] = c == null ? Cell(style: next) : c.withStyle(next);
    }
    setCells(s, after, label);
  }

  void toggleBold() {
    final v = !activeStyle.bold;
    applyStyle((st) => st.copyWith(bold: v), v ? 'Bold' : 'Remove bold');
  }

  void toggleItalic() {
    final v = !activeStyle.italic;
    applyStyle((st) => st.copyWith(italic: v), v ? 'Italic' : 'Remove italic');
  }

  void toggleUnderline() {
    final v = !activeStyle.underline;
    applyStyle((st) => st.copyWith(underline: v), 'Underline');
  }

  void toggleWrap() {
    final v = !activeStyle.wrap;
    applyStyle((st) => st.copyWith(wrap: v), 'Wrap text');
  }

  void setFontColor(int? color) => applyStyle((st) => st.copyWith(fontColor: color), 'Text color');

  void setFillColor(int? color) => applyStyle((st) => st.copyWith(fillColor: color), 'Fill color');

  void setAlignment(HAlign a) => applyStyle((st) => st.copyWith(hAlign: a), 'Align');

  void setNumberFormat(String code) => applyStyle((st) => st.copyWith(numFmt: code), 'Number format');

  /// Adds (delta > 0) or removes decimals from the active format.
  void changeDecimals(int delta) {
    var code = activeStyle.numFmt;
    if (code == 'General') {
      final v = activeCell?.value;
      var decimals = 0;
      if (v is double) {
        final s = NumberFormats.numberToPlainString(v);
        final dot = s.indexOf('.');
        decimals = dot < 0 || s.contains('E') ? 0 : s.length - dot - 1;
      }
      code = decimals > 0 ? '0.${'0' * decimals}' : '0';
    }
    final m = RegExp(r'0(\.0+)?').allMatches(code.split(';').first).lastOrNull;
    if (m == null) return;
    final decs = (m.group(1)?.length ?? 1) - 1;
    final next = math.max(0, decs + delta);
    final replacement = next == 0 ? '0' : '0.${'0' * next}';
    final newCode = code.replaceRange(m.start, m.end, replacement);
    // Apply to every section of multi-section formats.
    final sections = newCode.split(';');
    if (sections.length > 1) {
      for (var i = 1; i < sections.length; i++) {
        final mm = RegExp(r'0(\.0+)?').allMatches(sections[i]).lastOrNull;
        if (mm != null) sections[i] = sections[i].replaceRange(mm.start, mm.end, replacement);
      }
    }
    setNumberFormat(sections.join(';'));
  }

  // --- fill & sort -------------------------------------------------------------

  void fillDown() {
    if (editing) commitEdit();
    final sel = _usedSelection;
    final s = sheet;
    final src = sel.rowCount == 1 ? sel.r1 - 1 : sel.r1;
    if (src < 0) return;
    final from = sel.rowCount == 1 ? sel.r1 : sel.r1 + 1;
    final after = <int, Cell?>{};
    for (var c = sel.c1; c <= sel.c2; c++) {
      final cell = s.cell(src, c);
      for (var r = from; r <= sel.r2; r++) {
        after[cellKey(r, c)] = _shifted(cell, r - src, 0);
      }
    }
    setCells(s, after, 'Fill down');
  }

  void fillRight() {
    if (editing) commitEdit();
    final sel = _usedSelection;
    final s = sheet;
    final src = sel.colCount == 1 ? sel.c1 - 1 : sel.c1;
    if (src < 0) return;
    final from = sel.colCount == 1 ? sel.c1 : sel.c1 + 1;
    final after = <int, Cell?>{};
    for (var r = sel.r1; r <= sel.r2; r++) {
      final cell = s.cell(r, src);
      for (var c = from; c <= sel.c2; c++) {
        after[cellKey(r, c)] = _shifted(cell, 0, c - src);
      }
    }
    setCells(s, after, 'Fill right');
  }

  Cell? _shifted(Cell? cell, int dr, int dc) {
    if (cell == null) return null;
    if (cell.formula == null) return cell;
    return Cell(value: cell.value, formula: FormulaRefs.shift(cell.formula!, dr, dc), style: cell.style);
  }

  /// Sorts the selected rows (or the data region) by the active column.
  /// Returns an error message when sorting isn't possible.
  String? sort({required bool ascending}) {
    if (editing) commitEdit();
    final s = sheet;
    var sel = selection;
    if (sel.isSingle || (sel.r2 >= kMaxRows - 1)) {
      final headerRows = s.frozenRows > 0 ? s.frozenRows : (workbook.csv?.hasHeader == true ? 1 : 0);
      sel = CellRange(headerRows, 0, math.max(s.usedRows - 1, headerRows), math.max(s.usedCols - 1, 0));
    } else {
      sel = CellRange(sel.r1, sel.c1, math.min(sel.r2, s.usedRows - 1), math.min(sel.c2, s.usedCols - 1));
    }
    if (sel.rowCount < 2) return 'Nothing to sort.';
    for (final m in s.merges) {
      if (m.intersects(sel)) return 'Can\'t sort a range with merged cells.';
    }
    final keyCol = selCol.clamp(sel.c1, sel.c2);
    final rows = [for (var r = sel.r1; r <= sel.r2; r++) r];
    int rank(Object? v) => v is double
        ? 0
        : v is String
            ? 1
            : v is bool
                ? 2
                : v is CellError
                    ? 3
                    : 4;
    int cmp(int a, int b) {
      final va = s.cell(a, keyCol)?.value;
      final vb = s.cell(b, keyCol)?.value;
      final ra = rank(va);
      final rb = rank(vb);
      if (ra == 4 || rb == 4) return ra == rb ? a.compareTo(b) : (ra == 4 ? 1 : -1);
      var c = 0;
      if (ra != rb) {
        c = ra.compareTo(rb);
      } else if (va is double && vb is double) {
        c = va.compareTo(vb);
      } else if (va is String && vb is String) {
        c = va.toLowerCase().compareTo(vb.toLowerCase());
      } else if (va is bool && vb is bool) {
        c = (va ? 1 : 0).compareTo(vb ? 1 : 0);
      }
      if (!ascending) c = -c;
      return c != 0 ? c : a.compareTo(b);
    }

    final sorted = List<int>.of(rows)..sort(cmp);
    final after = <int, Cell?>{};
    for (var i = 0; i < sorted.length; i++) {
      final dest = sel.r1 + i;
      final src = sorted[i];
      for (var c = sel.c1; c <= sel.c2; c++) {
        after[cellKey(dest, c)] = _shifted(s.cell(src, c), dest - src, 0);
      }
    }
    setCells(s, after, ascending ? 'Sort A to Z' : 'Sort Z to A');
    return null;
  }

  // --- insert / delete rows & columns ----------------------------------------------

  void insertRows({bool below = false}) {
    final sel = selection;
    final count = sel.r2 >= kMaxRows - 1 ? 1 : sel.rowCount;
    final at = below ? sel.r2 + 1 : sel.r1;
    _insertDelete(rows: true, at: at, delta: count, label: count == 1 ? 'Insert row' : 'Insert $count rows');
  }

  void insertColumns({bool right = false}) {
    final sel = selection;
    final count = sel.c2 >= kMaxCols - 1 ? 1 : sel.colCount;
    final at = right ? sel.c2 + 1 : sel.c1;
    _insertDelete(rows: false, at: at, delta: count, label: count == 1 ? 'Insert column' : 'Insert $count columns');
  }

  void deleteRows() {
    final sel = selection;
    final r2 = math.min(sel.r2, math.max(sheet.usedRows - 1, sel.r1));
    final count = r2 - sel.r1 + 1;
    _insertDelete(rows: true, at: sel.r1, delta: -count, label: count == 1 ? 'Delete row' : 'Delete $count rows');
  }

  void deleteColumns() {
    final sel = selection;
    final c2 = math.min(sel.c2, math.max(sheet.usedCols - 1, sel.c1));
    final count = c2 - sel.c1 + 1;
    _insertDelete(rows: false, at: sel.c1, delta: -count, label: count == 1 ? 'Delete column' : 'Delete $count columns');
  }

  void _insertDelete({required bool rows, required int at, required int delta, required String label}) {
    final target = sheet;
    _structural(label, [target, ..._formulaSheets], () {
      _shiftSheet(target, rows: rows, at: at, delta: delta);
      for (final s in workbook.sheets) {
        final updates = <int, Cell>{};
        s.cells.forEach((k, c) {
          final f = c.formula;
          if (f == null) return;
          final nf = FormulaRefs.insertDelete(f,
              formulaSheet: s.name, targetSheet: target.name, rows: rows, at: at, delta: delta);
          if (nf != f) updates[k] = Cell(value: c.value, formula: nf, style: c.style, arrayRef: c.arrayRef);
        });
        s.cells.addAll(updates);
      }
      target.structureChanged = true;
      engine.invalidate();
      try {
        engine.recalcAll();
      } catch (_) {}
    }, focus: target);
    if (delta < 0) {
      select(rows ? at : selRow, rows ? selCol : at);
    }
  }

  static int _shiftIndex(int i, int at, int delta) {
    if (delta > 0) return i >= at ? i + delta : i;
    final k = -delta;
    if (i < at) return i;
    if (i < at + k) return -1;
    return i - k;
  }

  void _shiftSheet(SheetData s, {required bool rows, required int at, required int delta}) {
    final max = rows ? kMaxRows : kMaxCols;
    final cells = <int, Cell>{};
    s.cells.forEach((k, c) {
      var r = keyRow(k);
      var col = keyCol(k);
      if (rows) {
        r = _shiftIndex(r, at, delta);
      } else {
        col = _shiftIndex(col, at, delta);
      }
      if (r < 0 || col < 0 || (rows ? r : col) >= max) return;
      cells[cellKey(r, col)] = c;
    });
    s.cells = cells;
    Map<int, double> shiftMap(Map<int, double> m) {
      final out = <int, double>{};
      m.forEach((i, v) {
        final n = _shiftIndex(i, at, delta);
        if (n >= 0 && n < max) out[n] = v;
      });
      return out;
    }

    Set<int> shiftSet(Set<int> m) => {
          for (final i in m)
            if (_shiftIndex(i, at, delta) >= 0) _shiftIndex(i, at, delta),
        };
    if (rows) {
      s.rowHeights = shiftMap(s.rowHeights);
      s.hiddenRows = shiftSet(s.hiddenRows);
      if (s.frozenRows > at) s.frozenRows = math.max(at, s.frozenRows + delta);
    } else {
      s.colWidths = shiftMap(s.colWidths);
      s.hiddenCols = shiftSet(s.hiddenCols);
      if (s.frozenCols > at) s.frozenCols = math.max(at, s.frozenCols + delta);
    }
    final merges = <CellRange>[];
    for (final m in s.merges) {
      var a1 = rows ? m.r1 : m.c1;
      var a2 = rows ? m.r2 : m.c2;
      if (delta > 0) {
        if (a1 >= at) a1 += delta;
        if (a2 >= at) a2 += delta;
      } else {
        final k = -delta;
        final end = at + k;
        final n1 = a1 >= end ? a1 - k : (a1 >= at ? at : a1);
        final n2 = a2 >= end ? a2 - k : (a2 >= at ? at - 1 : a2);
        if (n2 < n1) continue;
        a1 = n1;
        a2 = n2;
      }
      final r = rows ? CellRange(a1, m.c1, a2, m.c2) : CellRange(m.r1, a1, m.r2, a2);
      if (!r.isSingle) merges.add(r);
    }
    s.merges = merges;
    s.invalidateBounds();
  }

  // --- merge -----------------------------------------------------------------------

  void mergeSelection() {
    final sel = selection;
    if (sel.isSingle || sel.area > 100000) return;
    final s = sheet;
    _structural('Merge cells', [s], () {
      s.merges.removeWhere((m) => m.intersects(sel));
      // Keep only the top-left value like Excel.
      for (final k in s.cells.keys.toList()) {
        final r = keyRow(k);
        final c = keyCol(k);
        if (sel.contains(r, c) && !(r == sel.r1 && c == sel.c1)) {
          final cell = s.cells[k]!;
          s.cells[k] = Cell(style: cell.style);
        }
      }
      s.merges.add(sel);
      s.invalidateBounds();
    }, focus: s);
  }

  void unmergeSelection() {
    final sel = selection;
    final s = sheet;
    if (!s.merges.any((m) => m.intersects(sel))) return;
    _structural('Unmerge cells', [s], () {
      s.merges.removeWhere((m) => m.intersects(sel));
    }, focus: s);
  }

  bool get selectionHasMerge => sheet.merges.any((m) => m.intersects(selection));

  // --- clipboard -------------------------------------------------------------------

  /// Copies the selection as tab-separated text (pasteable into other apps).
  Future<String?> copySelection({bool cut = false}) async {
    if (editing) commitEdit();
    final sel = _usedSelection;
    if (sel.area > 2000000) return 'The selection is too large to copy.';
    final s = sheet;
    final cells = <(int, int), Cell>{};
    final b = StringBuffer();
    for (var r = sel.r1; r <= sel.r2; r++) {
      if (r > sel.r1) b.write('\r\n');
      for (var c = sel.c1; c <= sel.c2; c++) {
        if (c > sel.c1) b.write('\t');
        final cell = s.cell(r, c);
        if (cell != null) cells[(r - sel.r1, c - sel.c1)] = cell;
        final t = CsvCodec.cellText(cell, date1904: workbook.date1904);
        b.write(t.contains('\t') || t.contains('\n') || t.contains('"')
            ? '"${t.replaceAll('"', '""')}"'
            : t);
      }
    }
    b.write('\r\n');
    final text = b.toString();
    _clip = _Clip(s, sel, cells, text, cut);
    await Clipboard.setData(ClipboardData(text: text));
    return null;
  }

  /// Pastes from the system clipboard. Returns an error message or null.
  Future<String?> paste() async {
    if (editing) commitEdit();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return 'The clipboard is empty.';
    final s = sheet;
    final sel = selection;
    final after = <int, Cell?>{};
    var rows = 1;
    var cols = 1;
    final clip = _clip;
    if (clip != null && clip.text == text) {
      rows = clip.range.rowCount;
      cols = clip.range.colCount;
      final fillAll = rows == 1 && cols == 1 && !sel.isSingle;
      final targetRows = fillAll ? sel.rowCount : rows;
      final targetCols = fillAll ? sel.colCount : cols;
      if (clip.cut && identical(clip.sheet, s)) {
        // Clear the source first so overlapping moves work.
        for (final e in clip.cells.entries) {
          after[cellKey(clip.range.r1 + e.key.$1, clip.range.c1 + e.key.$2)] = null;
        }
      }
      for (var dr = 0; dr < targetRows; dr++) {
        for (var dc = 0; dc < targetCols; dc++) {
          final src = clip.cells[(fillAll ? 0 : dr, fillAll ? 0 : dc)];
          final r = sel.r1 + dr;
          final c = sel.c1 + dc;
          if (r >= kMaxRows || c >= kMaxCols) continue;
          final shiftR = r - (clip.range.r1 + (fillAll ? 0 : dr));
          final shiftC = c - (clip.range.c1 + (fillAll ? 0 : dc));
          after[cellKey(r, c)] = clip.cut ? src : _shifted(src, shiftR, shiftC);
        }
      }
      rows = targetRows;
      cols = targetCols;
      if (clip.cut) _clip = null;
      if (!identical(clip.sheet, s) && clip.cut) {
        // Cut from another sheet: clear the source there.
        setCells(clip.sheet, <int, Cell?>{
          for (final e in clip.cells.entries)
            cellKey(clip.range.r1 + e.key.$1, clip.range.c1 + e.key.$2): null,
        }, 'Cut');
      }
    } else {
      var t = text;
      if (t.endsWith('\r\n')) {
        t = t.substring(0, t.length - 2);
      } else if (t.endsWith('\n')) {
        t = t.substring(0, t.length - 1);
      }
      final parsed = CsvCodec.parse(t, '\t');
      if (parsed.length * (parsed.isEmpty ? 0 : parsed.first.length) > 2000000) {
        return 'The clipboard content is too large to paste.';
      }
      rows = parsed.length;
      cols = 0;
      for (var dr = 0; dr < parsed.length; dr++) {
        final row = parsed[dr];
        if (row.length > cols) cols = row.length;
        for (var dc = 0; dc < row.length; dc++) {
          final r = sel.r1 + dr;
          final c = sel.c1 + dc;
          if (r >= kMaxRows || c >= kMaxCols) continue;
          final existing = s.cell(r, c);
          after[cellKey(r, c)] = parseCellInput(row[dc], existing?.style ?? CellStyle.plain,
              date1904: workbook.date1904);
        }
      }
    }
    setCells(s, after, 'Paste');
    if (rows > 1 || cols > 1) {
      final r2 = math.min(sel.r1 + rows - 1, kMaxRows - 1);
      final c2 = math.min(sel.c1 + cols - 1, kMaxCols - 1);
      anchorRow = r2;
      anchorCol = c2;
      selRow = sel.r1;
      selCol = sel.c1;
      _ensureCapacity(r2, c2);
      _notify();
    }
    return null;
  }

  // --- find & replace ------------------------------------------------------------

  bool _matches(String hay, String needle, FindOptions o) {
    if (o.wholeCell) {
      return o.matchCase ? hay == needle : hay.toLowerCase() == needle.toLowerCase();
    }
    return o.matchCase ? hay.contains(needle) : hay.toLowerCase().contains(needle.toLowerCase());
  }

  List<FindMatch> findAll(String query, FindOptions o) {
    if (query.isEmpty) return const [];
    final out = <FindMatch>[];
    final sheets = o.allSheets ? workbook.sheets : [sheet];
    for (final s in sheets) {
      final keys = s.cells.keys.toList()..sort();
      for (final k in keys) {
        final c = s.cells[k]!;
        if (!c.hasContent) continue;
        final raw = cellEditText(c, date1904: workbook.date1904);
        final shown = display(c).text;
        if (_matches(raw, query, o) || _matches(shown, query, o)) {
          out.add(FindMatch(s, keyRow(k), keyCol(k)));
        }
        if (out.length >= 100000) return out;
      }
    }
    return out;
  }

  void goToMatch(FindMatch m) {
    final idx = workbook.sheets.indexOf(m.sheet);
    if (idx < 0) return;
    if (idx != workbook.activeSheet) activateSheet(idx);
    select(m.row, m.col);
  }

  String _replaceIn(String text, String query, String replacement, FindOptions o) {
    if (o.wholeCell) return replacement;
    if (o.matchCase) return text.replaceAll(query, replacement);
    return text.replaceAll(RegExp(RegExp.escape(query), caseSensitive: false), replacement);
  }

  Cell? _replacedCell(SheetData s, FindMatch m, String query, String replacement, FindOptions o) {
    final c = s.cell(m.row, m.col);
    if (c == null) return null;
    final raw = cellEditText(c, date1904: workbook.date1904);
    if (!_matches(raw, query, o)) return null;
    final next = _replaceIn(raw, query, replacement, o);
    if (next == raw) return null;
    return parseCellInput(next, c.style, date1904: workbook.date1904) ?? Cell(style: c.style);
  }

  bool replaceOne(FindMatch m, String query, String replacement, FindOptions o) {
    final cell = _replacedCell(m.sheet, m, query, replacement, o);
    if (cell == null) return false;
    setCells(m.sheet, {cellKey(m.row, m.col): cell}, 'Replace');
    return true;
  }

  int replaceAll(String query, String replacement, FindOptions o) {
    final matches = findAll(query, o);
    final bySheet = <SheetData, Map<int, Cell?>>{};
    for (final m in matches) {
      final cell = _replacedCell(m.sheet, m, query, replacement, o);
      if (cell == null) continue;
      bySheet.putIfAbsent(m.sheet, () => {})[cellKey(m.row, m.col)] = cell;
    }
    var n = 0;
    bySheet.forEach((s, after) {
      n += after.length;
      setCells(s, after, 'Replace all');
    });
    return n;
  }

  // --- sheets ------------------------------------------------------------------------

  void addSheet() {
    final s = SheetData(name: workbook.uniqueSheetName('Sheet${workbook.sheets.length + 1}'));
    final at = workbook.activeSheet + 1;
    _structural('Add sheet', const [], () {
      workbook.sheets.insert(at.clamp(0, workbook.sheets.length), s);
      workbook.activeSheet = workbook.sheets.indexOf(s);
    }, focus: s);
    anchorRow = anchorCol = selRow = selCol = 0;
    _syncEditText();
    _notify();
  }

  /// Returns an error message or null.
  String? renameSheet(int index, String name) {
    final n = name.trim();
    final err = validateSheetName(n);
    if (err != null) return err;
    final s = workbook.sheets[index];
    if (s.name == n) return null;
    final other = workbook.sheetByName(n);
    if (other != null && !identical(other, s)) return 'A sheet with this name already exists';
    final old = s.name;
    _structural('Rename sheet', _formulaSheets, () {
      s.name = n;
      for (final sh in workbook.sheets) {
        final updates = <int, Cell>{};
        sh.cells.forEach((k, c) {
          final f = c.formula;
          if (f == null) return;
          final nf = FormulaRefs.renameSheet(f, old, n);
          if (nf != f) updates[k] = Cell(value: c.value, formula: nf, style: c.style, arrayRef: c.arrayRef);
        });
        sh.cells.addAll(updates);
      }
    }, focus: s);
    return null;
  }

  String? deleteSheet(int index) {
    final visible = workbook.sheets.where((s) => s.visibility == SheetVisibility.visible).length;
    final s = workbook.sheets[index];
    if (workbook.sheets.length <= 1 || (visible <= 1 && s.visibility == SheetVisibility.visible)) {
      return 'A workbook must keep at least one visible sheet.';
    }
    final name = s.name;
    _structural('Delete sheet', _formulaSheets, () {
      workbook.sheets.remove(s);
      for (final sh in workbook.sheets) {
        final updates = <int, Cell>{};
        sh.cells.forEach((k, c) {
          final f = c.formula;
          if (f == null) return;
          final nf = FormulaRefs.deleteSheet(f, name);
          if (nf != f) updates[k] = Cell(value: c.value, formula: nf, style: c.style, arrayRef: c.arrayRef);
        });
        sh.cells.addAll(updates);
      }
      var a = workbook.activeSheet;
      if (a >= workbook.sheets.length) a = workbook.sheets.length - 1;
      if (workbook.sheets[a].visibility != SheetVisibility.visible) {
        a = workbook.sheets.indexWhere((x) => x.visibility == SheetVisibility.visible);
      }
      workbook.activeSheet = math.max(a, 0);
      try {
        engine.invalidate();
        engine.recalcAll();
      } catch (_) {}
    });
    anchorRow = anchorCol = selRow = selCol = 0;
    _syncEditText();
    _notify();
    return null;
  }

  void duplicateSheet(int index) {
    final src = workbook.sheets[index];
    final copy = src.clone(name: workbook.uniqueSheetName(src.name.length > 26 ? src.name.substring(0, 26) : src.name))
      ..sourcePath = null
      ..sourceIndex = null
      ..sourceName = null
      ..visibility = SheetVisibility.visible;
    _structural('Duplicate sheet', const [], () {
      workbook.sheets.insert(index + 1, copy);
      workbook.activeSheet = index + 1;
    }, focus: copy);
    anchorRow = anchorCol = selRow = selCol = 0;
    _syncEditText();
    _notify();
  }

  void moveSheet(int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= workbook.sheets.length) return;
    final s = workbook.sheets[index];
    final active = sheet;
    _structural('Move sheet', const [], () {
      workbook.sheets.removeAt(index);
      workbook.sheets.insert(to, s);
      workbook.activeSheet = workbook.sheets.indexOf(active);
    });
  }

  String? setSheetHidden(int index, bool hidden) {
    final s = workbook.sheets[index];
    if (hidden) {
      final visible = workbook.sheets.where((x) => x.visibility == SheetVisibility.visible).length;
      if (visible <= 1) return 'A workbook must keep at least one visible sheet.';
    }
    final before = s.visibility;
    final after = hidden ? SheetVisibility.hidden : SheetVisibility.visible;
    _structural(hidden ? 'Hide sheet' : 'Unhide sheet', const [], () {
      s.visibility = after;
      if (hidden && identical(sheet, s)) {
        final v = workbook.sheets.indexWhere((x) => x.visibility == SheetVisibility.visible);
        if (v >= 0) workbook.activeSheet = v;
      }
    });
    if (before == after) return null;
    return null;
  }
}
