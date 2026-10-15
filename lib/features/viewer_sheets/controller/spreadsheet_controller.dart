import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../formula/evaluator.dart';
import '../formula/ref_rewriter.dart';
import '../model/input_parser.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import '../readers/csv_codec.dart';

part 'sheet_operations.dart';

enum EditOrigin { cell, formulaBar }

/// Count/sum/average of the current selection (like Excel's status bar).
class SelectionStats {
  const SelectionStats({
    required this.cells,
    required this.count,
    required this.numericCount,
    required this.sum,
    this.min,
    this.max,
  });

  final int cells;
  final int count;
  final int numericCount;
  final double sum;
  final double? min;
  final double? max;

  double? get average => numericCount == 0 ? null : sum / numericCount;
}

class FindOptions {
  const FindOptions({this.matchCase = false, this.wholeCell = false, this.allSheets = false});
  final bool matchCase;
  final bool wholeCell;
  final bool allSheets;
}

class FindMatch {
  const FindMatch(this.sheet, this.row, this.col);
  final SheetData sheet;
  final int row;
  final int col;
}

class _UndoEntry {
  _UndoEntry({
    required this.label,
    required this.undo,
    required this.redo,
    required this.selBefore,
    this.sheet,
    this.weight = 1,
  });

  final String label;
  final VoidCallback undo;
  final VoidCallback redo;
  final (int, int, int, int) selBefore;
  (int, int, int, int)? selAfter;

  final SheetData? sheet;

  /// Rough memory cost (cells held by snapshots).
  final int weight;
}

class _Clip {
  _Clip(this.sheet, this.range, this.cells, this.text, this.cut);
  final SheetData sheet;
  final CellRange range;
  final Map<(int, int), Cell> cells;
  final String text;
  final bool cut;
}

/// All editing state for one open workbook.
class SpreadsheetController extends ChangeNotifier {
  SpreadsheetController(this.workbook) : engine = FormulaEngine(workbook) {
    if (workbook.sheets.isEmpty) workbook.sheets.add(SheetData(name: 'Sheet1'));
    workbook.activeSheet = workbook.activeSheet.clamp(0, workbook.sheets.length - 1);
    _recomputeDisplaySize();
    _syncEditText();
  }

  final Workbook workbook;
  final FormulaEngine engine;
  final TextEditingController editText = TextEditingController();

  bool dirty = false;
  double zoom = 1.0;

  /// Bumped when extents, merges, panes or the active sheet change.
  int layoutVersion = 0;

  /// Bumped when any cell content or style changes.
  int contentVersion = 0;

  int selRow = 0;
  int selCol = 0;
  int anchorRow = 0;
  int anchorCol = 0;

  bool editing = false;
  EditOrigin editOrigin = EditOrigin.cell;
  String _editOriginal = '';

  /// Set by the grid to scroll a cell into view.
  void Function(int row, int col)? onRevealCell;

  final List<_UndoEntry> _undo = [];
  final List<_UndoEntry> _redo = [];
  _Clip? _clip;

  int _displayRows = 200;
  int _displayCols = 26;
  int _extraRows = 0;
  int _extraCols = 0;

  // Point mode (clicking cells while typing a formula inserts references).
  int? _pointStart;
  int? _pointEnd;
  int? _pointAnchorRow;
  int? _pointAnchorCol;

  SheetData get sheet => workbook.sheets[workbook.activeSheet];
  int get activeIndex => workbook.activeSheet;
  int get displayRows => _displayRows;
  int get displayCols => _displayCols;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;
  bool get isCsv => workbook.format == SpreadsheetFormat.csv;
  bool get hasClipboard => _clip != null;

  (int, int, int, int, int, int, Object)? _selKey;
  CellRange? _selCache;

  CellRange get selection {
    final key = (anchorRow, anchorCol, selRow, selCol, layoutVersion, contentVersion, sheet.merges);
    if (_selKey == key && _selCache != null) return _selCache!;
    _selKey = key;
    return _selCache = _computeSelection();
  }

  CellRange _computeSelection() {
    var r = CellRange(anchorRow, anchorCol, selRow, selCol);
    if (sheet.merges.isEmpty) return r;
    for (var pass = 0; pass < 3; pass++) {
      var changed = false;
      for (final m in sheet.merges) {
        if (m.intersects(r) && !r.containsRange(m)) {
          r = r.union(m);
          changed = true;
        }
      }
      if (!changed) break;
    }
    return r;
  }

  Cell? get activeCell => sheet.cell(selRow, selCol);
  CellStyle get activeStyle => activeCell?.style ?? CellStyle.plain;

  String get selectionLabel {
    final s = selection;
    final m = sheet.mergeAt(selRow, selCol);
    if (s.isSingle || (m != null && m == s)) return cellName(selRow, selCol);
    if (s.r1 == 0 && s.r2 >= kMaxRows - 1) {
      return '${columnName(s.c1)}:${columnName(s.c2)}';
    }
    if (s.c1 == 0 && s.c2 >= kMaxCols - 1) return '${s.r1 + 1}:${s.r2 + 1}';
    return '${s.rowCount}R x ${s.colCount}C';
  }

  @override
  void dispose() {
    editText.dispose();
    super.dispose();
  }

  void _notify() => notifyListeners();

  // ---------------------------------------------------------------------------
  // Display extents

  void _recomputeDisplaySize() {
    final s = sheet;
    var rows = math.max(s.usedRows + 100, 200) + _extraRows;
    rows = ((rows + 99) ~/ 100) * 100;
    final cols = math.max(s.usedCols + 10, 26) + _extraCols;
    final r = math.min(rows, kMaxRows);
    final c = math.min(cols, kMaxCols);
    if (r != _displayRows || c != _displayCols) {
      _displayRows = r;
      _displayCols = c;
      layoutVersion++;
    }
  }

  void _ensureCapacity(int row, int col) {
    var changed = false;
    if (row >= _displayRows - 20 && _displayRows < kMaxRows) {
      _extraRows += math.max(200, row - _displayRows + 220);
      changed = true;
    }
    if (col >= _displayCols - 3 && _displayCols < kMaxCols) {
      _extraCols += math.max(10, col - _displayCols + 13);
      changed = true;
    }
    if (changed) _recomputeDisplaySize();
  }

  void _afterContentChange() {
    contentVersion++;
    dirty = true;
    _recomputeDisplaySize();
  }

  // ---------------------------------------------------------------------------
  // Selection

  void _syncEditText() {
    if (editing) return;
    final t = cellEditText(sheet.cell(selRow, selCol), date1904: workbook.date1904);
    if (editText.text != t) {
      editText.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    }
  }

  /// Selects a cell; [extend] keeps the anchor (shift-click / drag).
  void select(int row, int col, {bool extend = false, bool reveal = true}) {
    // An invalid formula keeps the editor open (the caller shows why).
    if (editing && commitEdit() != null) return;
    row = row.clamp(0, kMaxRows - 1);
    col = col.clamp(0, kMaxCols - 1);
    if (!extend) {
      final m = sheet.mergeAt(row, col);
      if (m != null) {
        row = m.r1;
        col = m.c1;
      }
      anchorRow = row;
      anchorCol = col;
    }
    selRow = row;
    selCol = col;
    _ensureCapacity(row, col);
    _syncEditText();
    _notify();
    if (reveal) onRevealCell?.call(row, col);
  }

  void selectRange(CellRange r, {bool reveal = false}) {
    if (editing && commitEdit() != null) return;
    anchorRow = r.r1;
    anchorCol = r.c1;
    selRow = r.r2;
    selCol = r.c2;
    // Keep the active cell at the top-left like Excel.
    final tmpR = selRow;
    final tmpC = selCol;
    selRow = anchorRow;
    selCol = anchorCol;
    anchorRow = tmpR;
    anchorCol = tmpC;
    _syncEditText();
    _notify();
    if (reveal) onRevealCell?.call(r.r1, r.c1);
  }

  void selectAll() => selectRange(CellRange(0, 0, kMaxRows - 1, kMaxCols - 1));

  void selectColumns(int c1, int c2) => selectRange(CellRange(0, c1, kMaxRows - 1, c2));

  void selectRows(int r1, int r2) => selectRange(CellRange(r1, 0, r2, kMaxCols - 1));

  /// Moves the active cell (arrow keys, Enter, Tab).
  void move(int dr, int dc, {bool extend = false, bool jump = false}) {
    if (editing && commitEdit() != null) return;
    var r = selRow;
    var c = selCol;
    if (!extend) {
      final m = sheet.mergeAt(selRow, selCol);
      if (m != null) {
        if (dr > 0) r = m.r2;
        if (dc > 0) c = m.c2;
      }
    }
    if (jump) {
      (r, c) = _jumpTarget(r, c, dr, dc);
    } else {
      r += dr;
      c += dc;
      // Skip hidden rows/columns.
      var guard = 0;
      while (dr != 0 && sheet.hiddenRows.contains(r) && guard++ < 10000) {
        r += dr;
      }
      guard = 0;
      while (dc != 0 && sheet.hiddenCols.contains(c) && guard++ < 10000) {
        c += dc;
      }
    }
    select(r, c, extend: extend);
  }

  (int, int) _jumpTarget(int r, int c, int dr, int dc) {
    bool filled(int y, int x) => sheet.cell(y, x)?.hasContent ?? false;
    final maxR = math.max(sheet.usedRows, 1) - 1;
    final maxC = math.max(sheet.usedCols, 1) - 1;
    var y = r;
    var x = c;
    final startFilled = filled(y, x);
    final nextFilled = filled(y + dr, x + dc);
    if (startFilled && nextFilled) {
      while (filled(y + dr, x + dc)) {
        y += dr;
        x += dc;
        if (y < 0 || x < 0) break;
      }
      return (y.clamp(0, kMaxRows - 1), x.clamp(0, kMaxCols - 1));
    }
    while (true) {
      y += dr;
      x += dc;
      if (y < 0 || x < 0) return (math.max(y, 0), math.max(x, 0));
      if (y > maxR && dr > 0) return (dr > 0 && maxR > r ? maxR : y, x);
      if (x > maxC && dc > 0) return (y, dc > 0 && maxC > c ? maxC : x);
      if (filled(y, x)) return (y, x);
    }
  }

  // ---------------------------------------------------------------------------
  // Editing

  void beginEdit({String? initial, EditOrigin origin = EditOrigin.cell}) {
    if (editing) {
      if (editOrigin != origin) {
        editOrigin = origin;
        _notify();
      }
      return;
    }
    editing = true;
    editOrigin = origin;
    _editOriginal = cellEditText(activeCell, date1904: workbook.date1904);
    final t = initial ?? _editOriginal;
    // Keep the caret where the user tapped when the text is unchanged.
    if (!(initial == null && editText.text == t && editText.selection.isValid)) {
      editText.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    }
    _pointStart = null;
    _notify();
    onRevealCell?.call(selRow, selCol);
  }

  void cancelEdit() {
    if (!editing) return;
    editing = false;
    _pointStart = null;
    _syncEditText();
    _notify();
  }

  /// Commits the editor. Returns an error message (and keeps editing) when
  /// the formula is invalid.
  String? commitEdit({int dr = 0, int dc = 0}) {
    if (!editing) {
      if (dr != 0 || dc != 0) move(dr, dc);
      return null;
    }
    final text = editText.text;
    if (text != _editOriginal) {
      final existing = activeCell;
      final cell = parseCellInput(text, existing?.style ?? CellStyle.plain,
          date1904: workbook.date1904);
      if (cell?.formula != null && !engine.isValid(cell!.formula!)) {
        return 'There\'s a problem with this formula.';
      }
      editing = false;
      _pointStart = null;
      setCells(sheet, {cellKey(selRow, selCol): cell}, 'Edit ${cellName(selRow, selCol)}');
    } else {
      editing = false;
      _pointStart = null;
    }
    if (dr != 0 || dc != 0) {
      move(dr, dc);
    } else {
      _syncEditText();
      _notify();
    }
    return null;
  }

  /// While typing a formula, clicking a cell inserts its reference.
  bool get canPointReference {
    if (!editing) return false;
    final t = editText.text;
    if (!t.startsWith('=')) return false;
    final sel = editText.selection;
    final pos = sel.isValid ? sel.start : t.length;
    if (_pointStart != null && _pointEnd == pos) return true;
    var i = pos - 1;
    while (i >= 0 && t[i] == ' ') {
      i--;
    }
    if (i < 0) return false;
    return '=+-*/^(,;:&<>'.contains(t[i]);
  }

  void pointReference(int row, int col, {bool extend = false}) {
    final t = editText.text;
    final sel = editText.selection;
    var pos = sel.isValid ? sel.start : t.length;
    String ref;
    if (extend && _pointAnchorRow != null) {
      ref = CellRange(_pointAnchorRow!, _pointAnchorCol!, row, col).toA1();
    } else {
      ref = cellName(row, col);
      _pointAnchorRow = row;
      _pointAnchorCol = col;
    }
    var start = pos;
    var end = pos;
    if (_pointStart != null && _pointEnd == pos) {
      start = _pointStart!;
      end = _pointEnd!;
    }
    final next = t.replaceRange(start, end, ref);
    pos = start + ref.length;
    _pointStart = start;
    _pointEnd = pos;
    editText.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: pos));
  }

  // ---------------------------------------------------------------------------
  // Cell changes + undo

  (int, int, int, int) get _selState => (anchorRow, anchorCol, selRow, selCol);

  void _restoreSel((int, int, int, int) s) {
    anchorRow = s.$1;
    anchorCol = s.$2;
    selRow = s.$3;
    selCol = s.$4;
  }

  static bool _isRemovable(Cell? c) =>
      c == null ||
      (c.isBlank && c.style.isDefaultLook && (c.style.baseXf == null || c.style.baseXf == 0));

  void _writeCells(SheetData s, Map<int, Cell?> cells) {
    cells.forEach((k, c) {
      if (_isRemovable(c)) {
        s.setCell(keyRow(k), keyCol(k), null);
      } else {
        s.setCell(keyRow(k), keyCol(k), c);
      }
    });
    try {
      engine.cellsChanged(s, cells.keys);
    } catch (_) {
      engine.invalidate();
    }
  }

  /// Writes cells with undo support.
  void setCells(SheetData s, Map<int, Cell?> after, String label) {
    if (after.isEmpty) return;
    final before = <int, Cell?>{for (final k in after.keys) k: s.cells[k]};
    final selBefore = _selState;
    _writeCells(s, after);
    _push(_UndoEntry(
      label: label,
      undo: () => _writeCells(s, before),
      redo: () => _writeCells(s, after),
      selBefore: selBefore,
      sheet: s,
      weight: after.length,
    ));
    _afterContentChange();
    _syncEditText();
    _notify();
  }

  void _push(_UndoEntry e) {
    _undo.add(e);
    _redo.clear();
    var total = 0;
    for (final x in _undo) {
      total += x.weight;
    }
    while (_undo.length > 100 || (total > 3000000 && _undo.length > 1)) {
      total -= _undo.removeAt(0).weight;
    }
  }

  void undo() {
    if (editing) cancelEdit();
    if (_undo.isEmpty) return;
    final e = _undo.removeLast();
    e.selAfter ??= _selState;
    e.undo();
    _redo.add(e);
    _afterUndoRedo(e, e.selBefore);
  }

  void redo() {
    if (editing) cancelEdit();
    if (_redo.isEmpty) return;
    final e = _redo.removeLast();
    e.redo();
    _undo.add(e);
    _afterUndoRedo(e, e.selAfter ?? e.selBefore);
  }

  void _afterUndoRedo(_UndoEntry e, (int, int, int, int) sel) {
    final idx = e.sheet == null ? -1 : workbook.sheets.indexOf(e.sheet!);
    if (idx >= 0 && idx != workbook.activeSheet) {
      workbook.activeSheet = idx;
      layoutVersion++;
    }
    workbook.activeSheet = workbook.activeSheet.clamp(0, workbook.sheets.length - 1);
    _restoreSel(sel);
    contentVersion++;
    dirty = true;
    layoutVersion++;
    _recomputeDisplaySize();
    _syncEditText();
    _notify();
    onRevealCell?.call(selRow, selCol);
  }

  /// Runs a structural change, snapshotting [snapshot] sheets and the sheet
  /// list for undo. Redo replays [mutate].
  void _structural(String label, Iterable<SheetData> snapshot, void Function() mutate,
      {SheetData? focus}) {
    if (editing) commitEdit();
    final list = List<SheetData>.of(workbook.sheets);
    final clones = {for (final s in snapshot.toSet()) s: s.clone()};
    final active = workbook.activeSheet;
    final selBefore = _selState;
    var weight = 1;
    for (final c in clones.values) {
      weight += c.cells.length;
    }
    mutate();
    engine.invalidate();
    _push(_UndoEntry(
      label: label,
      undo: () {
        workbook.sheets
          ..clear()
          ..addAll(list);
        clones.forEach((s, c) => s.restoreFrom(c));
        workbook.activeSheet = active.clamp(0, workbook.sheets.length - 1);
        engine.invalidate();
      },
      redo: () {
        mutate();
        engine.invalidate();
      },
      selBefore: selBefore,
      sheet: focus,
      weight: weight,
    ));
    layoutVersion++;
    _afterContentChange();
    _syncEditText();
    _notify();
  }

  /// Sheets holding formulas (they may need reference rewrites).
  Iterable<SheetData> get _formulaSheets =>
      workbook.sheets.where((s) => s.cells.values.any((c) => c.formula != null));

  // ---------------------------------------------------------------------------
  // Display helpers

  FormattedValue display(Cell? cell) {
    if (cell == null || cell.value == null) return const FormattedValue('');
    return NumberFormats.format(cell.value, cell.style.numFmt, date1904: workbook.date1904);
  }

  SelectionStats? _statsCache;
  (CellRange, int, int)? _statsKey;

  SelectionStats selectionStats() {
    final sel = selection;
    final key = (sel, contentVersion, activeIndex);
    if (_statsKey == key && _statsCache != null) return _statsCache!;
    var count = 0;
    var numeric = 0;
    var sum = 0.0;
    double? mn;
    double? mx;
    void visit(Cell? c) {
      final v = c?.value;
      if (v == null) return;
      count++;
      if (v is double) {
        numeric++;
        sum += v;
        mn = mn == null ? v : math.min(mn!, v);
        mx = mx == null ? v : math.max(mx!, v);
      }
    }

    final s = sheet;
    final r2 = math.min(sel.r2, s.usedRows - 1);
    final c2 = math.min(sel.c2, s.usedCols - 1);
    if (r2 >= sel.r1 && c2 >= sel.c1) {
      final area = (r2 - sel.r1 + 1) * (c2 - sel.c1 + 1);
      if (area <= s.cells.length) {
        for (var r = sel.r1; r <= r2; r++) {
          for (var c = sel.c1; c <= c2; c++) {
            visit(s.cells[cellKey(r, c)]);
          }
        }
      } else {
        s.cells.forEach((k, c) {
          if (sel.contains(keyRow(k), keyCol(k))) visit(c);
        });
      }
    }
    _statsKey = key;
    return _statsCache = SelectionStats(
      cells: sel.area,
      count: count,
      numericCount: numeric,
      sum: sum,
      min: mn,
      max: mx,
    );
  }

  // ---------------------------------------------------------------------------
  // View

  void setZoom(double z) {
    final v = z.clamp(0.4, 3.0);
    if ((v - zoom).abs() < 0.001) return;
    zoom = v;
    layoutVersion++;
    _notify();
  }

  void activateSheet(int index) {
    if (index < 0 || index >= workbook.sheets.length || index == workbook.activeSheet) return;
    if (editing && commitEdit() != null) cancelEdit();
    workbook.activeSheet = index;
    anchorRow = anchorCol = selRow = selCol = 0;
    _extraRows = _extraCols = 0;
    layoutVersion++;
    _recomputeDisplaySize();
    _syncEditText();
    _notify();
    onRevealCell?.call(0, 0);
  }

  /// Live column resize; [record] adds an undo step from [from].
  void setColumnWidth(int col, double width, {double? from, bool record = false}) {
    final s = sheet;
    final w = width.clamp(4.0, 2000.0).toDouble();
    s.colWidths[col] = w;
    if (record && from != null && (from - w).abs() > 0.5) {
      _push(_UndoEntry(
        label: 'Column width',
        undo: () => s.colWidths[col] = from,
        redo: () => s.colWidths[col] = w,
        selBefore: _selState,
        sheet: s,
      ));
      dirty = true;
    }
    layoutVersion++;
    _notify();
  }

  void autoFitColumn(int col, double Function(String text, CellStyle style) measure) {
    final s = sheet;
    var w = 24.0;
    final rows = math.min(s.usedRows, 5000);
    for (var r = 0; r < rows; r++) {
      final c = s.cell(r, col);
      if (c == null || c.value == null) continue;
      final t = display(c).text;
      if (t.isEmpty) continue;
      w = math.max(w, measure(t, c.style) + 12);
    }
    setColumnWidth(col, math.min(w, 600), from: s.colWidth(col), record: true);
  }

  void setFrozen(int rows, int cols) {
    final s = sheet;
    final before = (s.frozenRows, s.frozenCols);
    if (before == (rows, cols)) return;
    void apply((int, int) v) {
      s.frozenRows = v.$1;
      s.frozenCols = v.$2;
    }

    apply((rows, cols));
    _push(_UndoEntry(
      label: rows == 0 && cols == 0 ? 'Unfreeze panes' : 'Freeze panes',
      undo: () => apply(before),
      redo: () => apply((rows, cols)),
      selBefore: _selState,
      sheet: s,
    ));
    dirty = true;
    layoutVersion++;
    _notify();
  }

  /// Recalculates every formula (volatile functions like TODAY included).
  void recalculate() {
    if (editing) commitEdit();
    try {
      engine.recalcAll();
    } catch (_) {}
    contentVersion++;
    _syncEditText();
    _notify();
  }

  /// Marks the workbook as saved.
  void markSaved() {
    dirty = false;
    _notify();
  }

  /// CSV only: show the first row as a header (frozen, bold).
  void setCsvHeader(bool value) {
    final csv = workbook.csv;
    if (csv == null) return;
    csv.hasHeader = value;
    sheet.frozenRows = value ? 1 : 0;
    layoutVersion++;
    _notify();
  }
}
