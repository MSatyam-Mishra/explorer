import 'dart:io';
import 'dart:isolate';

import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../controller/spreadsheet_controller.dart';
import '../model/workbook.dart';
import '../readers/csv_codec.dart';
import '../readers/workbook_loader.dart';
import '../widgets/find_bar.dart';
import '../widgets/format_toolbar.dart';
import '../widgets/formula_bar.dart';
import '../widgets/grid_colors.dart';
import '../widgets/sheet_grid.dart';
import '../widgets/sheet_tabs.dart';
import '../widgets/side_panel.dart';
import '../widgets/status_bar.dart';
import '../widgets/text_prompt.dart';
import '../writers/xlsx_writer.dart';

/// Spreadsheet viewer/editor for .xlsx/.xlsm/.xltx/.xltm, .xls/.xlt,
/// .csv/.tsv/.tab/.psv and .ods/.ots files.
///
/// Pops with `true` when a new file was written next to the original (so the
/// explorer refreshes).
class SpreadsheetScreen extends StatefulWidget {
  const SpreadsheetScreen({super.key, required this.file});

  final File file;

  @override
  State<SpreadsheetScreen> createState() => _SpreadsheetScreenState();
}

enum _Menu {
  find,
  replace,
  goTo,
  freezeHere,
  freezeTopRow,
  freezeFirstColumn,
  unfreeze,
  sortAsc,
  sortDesc,
  insertRow,
  insertColumn,
  deleteRow,
  deleteColumn,
  fillDown,
  recalc,
  delimiter,
  header,
  saveCopy,
  exportCsv,
  openWith,
}

enum _CellMenu {
  cut,
  copy,
  paste,
  clear,
  clearAll,
  insertRowAbove,
  insertRowBelow,
  insertColLeft,
  insertColRight,
  deleteRows,
  deleteCols,
  fillDown,
  fillRight,
  sortAsc,
  sortDesc,
  merge,
  unmerge,
  freezeHere,
}

enum _TabMenu { rename, duplicate, moveLeft, moveRight, hide, unhide, delete }

class _SpreadsheetScreenState extends State<SpreadsheetScreen> {
  late File _file;
  SpreadsheetController? _ctrl;

  /// Original package bytes (xlsx family) used to keep unknown parts.
  Uint8List? _packageBytes;
  bool _loading = true;
  String? _error;
  bool _saving = false;
  bool _createdNewFile = false;
  bool _csvLossAccepted = false;
  bool _findOpen = false;
  bool _replaceMode = false;
  int _findKey = 0;

  final _gridFocus = FocusNode(debugLabel: 'sheet-grid');
  final _editorFocus = FocusNode(debugLabel: 'sheet-cell-editor');
  final _formulaFocus = FocusNode(debugLabel: 'sheet-formula-bar');

  @override
  void initState() {
    super.initState();
    _file = widget.file;
    _formulaFocus.addListener(_onFormulaFocus);
    _load();
  }

  @override
  void dispose() {
    _formulaFocus.removeListener(_onFormulaFocus);
    _gridFocus.dispose();
    _editorFocus.dispose();
    _formulaFocus.dispose();
    _ctrl?.removeListener(_onControllerChanged);
    _ctrl?.dispose();
    super.dispose();
  }

  bool _lastDirty = false;

  /// Rebuilds the screen only when the title's "unsaved" marker changes.
  void _onControllerChanged() {
    final d = _ctrl?.dirty ?? false;
    if (d != _lastDirty && mounted) {
      setState(() => _lastDirty = d);
    }
  }

  void _onFormulaFocus() {
    final c = _ctrl;
    if (c == null || !_formulaFocus.hasFocus) return;
    if (!c.editing) {
      c.beginEdit(origin: EditOrigin.formulaBar);
    } else if (c.editOrigin != EditOrigin.formulaBar) {
      c.beginEdit(origin: EditOrigin.formulaBar);
    }
  }

  String get _fileName => p.basename(_file.path);

  // ---------------------------------------------------------------------------
  // Loading

  /// Files at least this big first show their first rows (read-only) while
  /// the whole file is read in the background.
  static const _previewMinBytes = 1024 * 1024;

  /// Identifies the current load so results of a superseded one are dropped.
  int _loadGen = 0;

  /// True while [_ctrl] is a read-only preview of the file being loaded.
  bool _previewing = false;

  Future<void> _load({CsvLoadOptions? csv}) async {
    final gen = ++_loadGen;
    if (!_loading || _error != null || _previewing) {
      setState(() {
        _loading = true;
        _previewing = false;
        _error = null;
      });
    }
    try {
      final bytes = await _file.readAsBytes();
      if (!mounted || gen != _loadGen) return;
      final name = _fileName;
      final full = _parseInBackground(bytes, name, csv);
      if (bytes.length >= _previewMinBytes) {
        // Runs in parallel; ignored if the full workbook is ready first.
        _previewInBackground(bytes, name, csv).then((wb) {
          if (wb != null && mounted && gen == _loadGen && _loading) _showPreview(wb);
        }, onError: (Object _) {});
      }
      final wb = await full;
      if (!mounted || gen != _loadGen) return;
      _install(wb, bytes);
    } on SpreadsheetReadException catch (e) {
      _failLoad(gen, e.message);
    } on FileSystemException {
      _failLoad(gen, 'This file can\'t be read. Check that it still exists and that the app may access it.');
    } catch (_) {
      _failLoad(gen, 'This file couldn\'t be opened. It may be damaged or in a format that isn\'t supported.');
    }
  }

  void _failLoad(int gen, String message) {
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _loading = false;
      _previewing = false;
      _error = message;
    });
  }

  void _replaceController(SpreadsheetController next) {
    final old = _ctrl;
    old?.removeListener(_onControllerChanged);
    next.addListener(_onControllerChanged);
    _ctrl = next;
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _showPreview(Workbook wb) {
    final next = SpreadsheetController(wb)
      ..readOnly = true
      ..onReadOnly = () => _toast('Still opening the file. You can edit in a moment.');
    setState(() {
      _replaceController(next);
      _previewing = true;
      _lastDirty = false;
    });
  }

  void _install(Workbook wb, Uint8List bytes) {
    final preview = _previewing ? _ctrl : null;
    final next = SpreadsheetController(wb);
    if (preview != null) next.adoptViewFrom(preview);
    _lastDirty = false;
    setState(() {
      _replaceController(next);
      _packageBytes = wb.format.isXlsxFamily ? bytes : null;
      _loading = false;
      _previewing = false;
      // Matches found in the preview point at its (discarded) sheets.
      if (preview != null) _findOpen = false;
    });
    if (wb.warnings.isNotEmpty) _toast(wb.warnings.first);
    if (preview == null || !_formulaFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _gridFocus.requestFocus();
      });
    }
  }

  /// False (with a message) while the file is still being read.
  bool _readyToSave() {
    if (!_loading) return true;
    _toast('Still opening the file. Try again in a moment.');
    return false;
  }

  // ---------------------------------------------------------------------------
  // Messages

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  Future<bool> _confirm(String title, String message, String action, {bool destructive = false}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // ---------------------------------------------------------------------------
  // Saving

  bool _commitPending() {
    final c = _ctrl;
    if (c == null || !c.editing) return true;
    final err = c.commitEdit();
    if (err != null) {
      _toast(err);
      return false;
    }
    return true;
  }

  Future<File> _uniqueFile(String dir, String base, String ext) async {
    var f = File(p.join(dir, '$base$ext'));
    var n = 1;
    while (await f.exists()) {
      f = File(p.join(dir, '$base ($n)$ext'));
      n++;
    }
    return f;
  }

  Future<void> _writeBytes(File target, Uint8List bytes) async {
    final tmp = File('${target.path}.saving~');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      await target.writeAsBytes(bytes, flush: true);
    }
  }

  /// Points each sheet at its part in the package just written. [saved] is
  /// the sheet list and names as they were when the save started (edits made
  /// while it ran aren't in the file, so they must not be marked as saved).
  void _syncAfterXlsxSave(SpreadsheetController c, XlsxWriteResult result,
      List<(SheetData, String)> saved, int serial) {
    if (result.sheetPaths.length != saved.length) return;
    final unchanged = c.editSerial == serial;
    for (var i = 0; i < saved.length; i++) {
      final (sheet, name) = saved[i];
      sheet
        ..sourcePath = result.sheetPaths[i]
        ..sourceIndex = i
        ..sourceName = name;
      if (unchanged) sheet.structureChanged = false;
    }
  }

  List<(SheetData, String)> _sheetSnapshot(SpreadsheetController c) =>
      [for (final s in c.workbook.sheets) (s, s.name)];

  Future<XlsxWriteResult> _buildXlsx(SpreadsheetController c, SpreadsheetFormat target) =>
      _writeXlsxInBackground(c.workbook, _packageBytes, target);

  /// Save (Ctrl+S): overwrite when possible, otherwise "Save as .xlsx".
  Future<bool> _save() async {
    final c = _ctrl;
    if (c == null || _saving || !_readyToSave()) return false;
    if (!_commitPending()) return false;
    final fmt = c.workbook.format;
    if (fmt.isXlsxFamily) return _overwriteXlsx(c);
    if (fmt == SpreadsheetFormat.csv) return _saveCsv(c);
    return _saveAsXlsx(c, switchToNew: true);
  }

  Future<bool> _overwriteXlsx(SpreadsheetController c) async {
    setState(() => _saving = true);
    try {
      final serial = c.editSerial;
      final saved = _sheetSnapshot(c);
      final result = await _buildXlsx(c, c.workbook.format);
      await _writeBytes(_file, result.bytes);
      if (!mounted) return true;
      _packageBytes = result.bytes;
      _syncAfterXlsxSave(c, result, saved, serial);
      c.markSaved(atSerial: serial);
      setState(() {});
      _toast(c.dirty ? 'Saved. Changes made while saving aren\'t saved yet.' : 'Saved');
      return true;
    } catch (e) {
      _toast('Couldn\'t save: ${_describe(e)}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveAsXlsx(SpreadsheetController c, {required bool switchToNew}) async {
    if (!_readyToSave() || !_commitPending()) return false;
    setState(() => _saving = true);
    try {
      final dir = p.dirname(_file.path);
      final base = p.basenameWithoutExtension(_file.path);
      final target = await _uniqueFile(dir, base, '.xlsx');
      final serial = c.editSerial;
      final saved = _sheetSnapshot(c);
      final result = await _buildXlsx(c, SpreadsheetFormat.xlsx);
      await _writeBytes(target, result.bytes);
      if (!mounted) return true;
      _createdNewFile = true;
      if (switchToNew) {
        _file = target;
        _packageBytes = result.bytes;
        c.workbook.format = SpreadsheetFormat.xlsx;
        c.workbook.csv = null;
        _syncAfterXlsxSave(c, result, saved, serial);
        c.markSaved(atSerial: serial);
      }
      setState(() {});
      _toast('Saved as ${p.basename(target.path)}');
      return true;
    } catch (e) {
      _toast('Couldn\'t save: ${_describe(e)}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveCsv(SpreadsheetController c, {File? target}) async {
    final wb = c.workbook;
    final csv = wb.csv ?? CsvSettings();
    final sheet = c.sheet;
    if (target == null && !_csvLossAccepted) {
      final hasFormulas = sheet.cells.values.any((x) => x.formula != null);
      final hasStyles = sheet.cells.values.any((x) => !x.style.isDefaultLook && x.style.numFmt == 'General');
      if (wb.sheets.length > 1 || hasFormulas || hasStyles) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Save as delimited text?'),
            content: Text(
              '${wb.sheets.length > 1 ? 'Only the sheet "${sheet.name}" is saved. ' : ''}'
              'Formulas are saved as their results and formatting is lost.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, 'xlsx'), child: const Text('Save as .xlsx')),
              FilledButton(onPressed: () => Navigator.pop(context, 'csv'), child: const Text('Save')),
            ],
          ),
        );
        if (!mounted || choice == null) return false;
        if (choice == 'xlsx') return _saveAsXlsx(c, switchToNew: true);
        _csvLossAccepted = true;
      }
    }
    setState(() => _saving = true);
    try {
      final delimiter = csv.delimiter;
      final newline = csv.newline;
      final date1904 = wb.date1904;
      final encoding = target == null ? csv.encoding : TextEncodingKind.utf8Bom;
      final serial = c.editSerial;
      final bytes = await _writeCsvInBackground(sheet, delimiter, newline, date1904, encoding);
      await _writeBytes(target ?? _file, bytes);
      if (!mounted) return true;
      if (target == null) {
        c.markSaved(atSerial: serial);
        _toast(c.dirty ? 'Saved. Changes made while saving aren\'t saved yet.' : 'Saved');
      } else {
        _createdNewFile = true;
        _toast('Exported ${p.basename(target.path)}');
      }
      setState(() {});
      return true;
    } catch (e) {
      _toast('Couldn\'t save: ${_describe(e)}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _exportCsv() async {
    final c = _ctrl;
    if (c == null || !_readyToSave() || !_commitPending()) return;
    final dir = p.dirname(_file.path);
    final base = p.basenameWithoutExtension(_file.path);
    final name = c.workbook.sheets.length > 1 ? '$base - ${c.sheet.name}' : base;
    final target = await _uniqueFile(dir, name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'), '.csv');
    if (!mounted) return;
    await _saveCsv(c, target: target);
  }

  String _describe(Object e) {
    if (e is FileSystemException) {
      final os = e.osError?.message;
      return os == null || os.isEmpty ? 'the file couldn\'t be written' : os;
    }
    return 'something went wrong';
  }

  // ---------------------------------------------------------------------------
  // Leaving

  Future<void> _onPop() async {
    final c = _ctrl;
    if (c != null && c.editing) {
      if (c.commitEdit() != null) c.cancelEdit();
    }
    if (c != null && c.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unsaved changes'),
          content: Text('Save your changes to "$_fileName"?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('Discard')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'save') {
        final ok = await _save();
        if (!ok || !mounted) return;
        if (c.dirty) return;
      }
    }
    if (mounted) Navigator.of(context).pop(_createdNewFile ? true : null);
  }

  // ---------------------------------------------------------------------------
  // Commands

  KeyEventResult _onScreenKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    if (!ctrl) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.keyS) {
      _save();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyF) {
      _openFind(replace: false);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyH) {
      _openFind(replace: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openFind({required bool replace}) {
    setState(() {
      if (!_findOpen) _findKey++;
      _findOpen = true;
      _replaceMode = replace;
    });
  }

  void _closeFind() {
    setState(() => _findOpen = false);
    _gridFocus.requestFocus();
  }

  void _commit(int dr, int dc) {
    final c = _ctrl;
    if (c == null) return;
    final err = c.commitEdit(dr: dr, dc: dc);
    if (err != null) {
      _toast(err);
    } else {
      _gridFocus.requestFocus();
    }
  }

  void _cancelEdit() {
    _ctrl?.cancelEdit();
    _gridFocus.requestFocus();
  }

  Future<void> _goTo() async {
    final c = _ctrl;
    if (c == null) return;
    final text = await showTextPrompt(
      context,
      title: 'Go to',
      initial: c.selectionLabel.contains('R x') ? cellName(c.selRow, c.selCol) : c.selectionLabel,
      label: 'Cell or range',
      helper: 'e.g. B12, A1:C10 or Sheet2!A1',
      action: 'Go',
      validate: (v) => _parseGoTo(c, v) == null ? 'Enter a cell like B12 or Sheet2!A1' : null,
    );
    if (text == null || !mounted) return;
    final target = _parseGoTo(c, text);
    if (target == null) return;
    if (target.$1 != c.activeIndex) c.activateSheet(target.$1);
    final r = target.$2;
    if (r.isSingle) {
      c.select(r.r1, r.c1);
    } else {
      c.selectRange(r, reveal: true);
    }
    _gridFocus.requestFocus();
  }

  (int, CellRange)? _parseGoTo(SpreadsheetController c, String text) {
    var t = text.trim();
    var sheetIndex = c.activeIndex;
    final bang = t.lastIndexOf('!');
    if (bang > 0) {
      var name = t.substring(0, bang);
      if (name.startsWith("'") && name.endsWith("'") && name.length >= 2) {
        name = name.substring(1, name.length - 1).replaceAll("''", "'");
      }
      sheetIndex = c.workbook.indexOfSheetName(name);
      if (sheetIndex < 0) return null;
      t = t.substring(bang + 1);
    }
    final r = CellRange.parse(t);
    if (r == null) return null;
    return (sheetIndex, r);
  }

  Future<void> _chooseDelimiter() async {
    final c = _ctrl;
    final csv = c?.workbook.csv;
    if (c == null || csv == null) return;
    final d = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Delimiter'),
        children: [
          for (final cand in CsvCodec.candidates)
            ListTile(
              leading: Icon(cand == csv.delimiter ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(CsvSettings.delimiterLabel(cand)),
              onTap: () => Navigator.pop(context, cand),
            ),
        ],
      ),
    );
    if (d == null || d == csv.delimiter || !mounted) return;
    if (c.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Use ${CsvSettings.delimiterLabel(d).toLowerCase()}s'),
          content: const Text('Re-read the file with this delimiter (your changes are discarded), '
              'or keep your changes and use it when saving?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('When saving')),
            FilledButton(onPressed: () => Navigator.pop(context, 'reload'), child: const Text('Re-read')),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'save') {
        csv.delimiter = d;
        c.dirty = true;
        setState(() {});
        return;
      }
    }
    await _load(csv: CsvLoadOptions(delimiter: d, hasHeader: csv.hasHeader));
  }

  Future<void> _openWith() async {
    final c = _ctrl;
    if (c != null && c.dirty) _toast('Unsaved changes aren\'t included. Save first to share them.');
    try {
      final r = await OpenFilex.open(_file.path);
      if (r.type != ResultType.done && mounted) {
        _toast(r.type == ResultType.noAppToOpen ? 'No app found to open this file.' : 'Couldn\'t open the file.');
      }
    } catch (_) {
      _toast('Couldn\'t open the file.');
    }
  }

  Future<void> _onMenu(_Menu m) async {
    final c = _ctrl;
    if (c == null) return;
    switch (m) {
      case _Menu.find:
        _openFind(replace: false);
      case _Menu.replace:
        _openFind(replace: true);
      case _Menu.goTo:
        await _goTo();
      case _Menu.freezeHere:
        c.setFrozen(c.selRow, c.selCol);
      case _Menu.freezeTopRow:
        c.setFrozen(1, 0);
      case _Menu.freezeFirstColumn:
        c.setFrozen(0, 1);
      case _Menu.unfreeze:
        c.setFrozen(0, 0);
      case _Menu.sortAsc:
        final e = c.sort(ascending: true);
        if (e != null) _toast(e);
      case _Menu.sortDesc:
        final e = c.sort(ascending: false);
        if (e != null) _toast(e);
      case _Menu.insertRow:
        c.insertRows();
      case _Menu.insertColumn:
        c.insertColumns();
      case _Menu.deleteRow:
        c.deleteRows();
      case _Menu.deleteColumn:
        c.deleteColumns();
      case _Menu.fillDown:
        c.fillDown();
      case _Menu.recalc:
        c.recalculate();
      case _Menu.delimiter:
        await _chooseDelimiter();
      case _Menu.header:
        c.setCsvHeader(!(c.workbook.csv?.hasHeader ?? false));
      case _Menu.saveCopy:
        await _saveAsXlsx(c, switchToNew: false);
      case _Menu.exportCsv:
        await _exportCsv();
      case _Menu.openWith:
        await _openWith();
    }
  }

  Future<void> _showCellMenu(Offset global) async {
    final c = _ctrl;
    if (c == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size);
    final hasMerge = c.selectionHasMerge;
    PopupMenuItem<_CellMenu> item(_CellMenu v, IconData icon, String label, {bool enabled = true}) =>
        PopupMenuItem(
          value: v,
          enabled: enabled,
          height: 40,
          child: Row(children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        );
    final choice = await showMenu<_CellMenu>(
      context: context,
      position: rect,
      items: [
        item(_CellMenu.cut, Icons.content_cut_rounded, 'Cut'),
        item(_CellMenu.copy, Icons.content_copy_rounded, 'Copy'),
        item(_CellMenu.paste, Icons.content_paste_rounded, 'Paste'),
        item(_CellMenu.clear, Icons.backspace_outlined, 'Clear contents'),
        item(_CellMenu.clearAll, Icons.format_clear_rounded, 'Clear all'),
        const PopupMenuDivider(),
        item(_CellMenu.insertRowAbove, Icons.keyboard_arrow_up_rounded, 'Insert row above'),
        item(_CellMenu.insertRowBelow, Icons.keyboard_arrow_down_rounded, 'Insert row below'),
        item(_CellMenu.insertColLeft, Icons.keyboard_arrow_left_rounded, 'Insert column left'),
        item(_CellMenu.insertColRight, Icons.keyboard_arrow_right_rounded, 'Insert column right'),
        item(_CellMenu.deleteRows, Icons.table_rows_outlined, 'Delete rows'),
        item(_CellMenu.deleteCols, Icons.view_column_outlined, 'Delete columns'),
        const PopupMenuDivider(),
        item(_CellMenu.fillDown, Icons.south_rounded, 'Fill down'),
        item(_CellMenu.fillRight, Icons.east_rounded, 'Fill right'),
        item(_CellMenu.sortAsc, Icons.arrow_upward_rounded, 'Sort A to Z'),
        item(_CellMenu.sortDesc, Icons.arrow_downward_rounded, 'Sort Z to A'),
        if (hasMerge)
          item(_CellMenu.unmerge, Icons.call_split_rounded, 'Unmerge cells')
        else
          item(_CellMenu.merge, Icons.merge_type_rounded, 'Merge cells', enabled: !c.selection.isSingle),
        item(_CellMenu.freezeHere, Icons.ac_unit_rounded, 'Freeze panes here'),
      ],
    );
    if (choice == null || !mounted) return;
    String? msg;
    switch (choice) {
      case _CellMenu.cut:
        msg = await c.copySelection(cut: true);
      case _CellMenu.copy:
        msg = await c.copySelection();
      case _CellMenu.paste:
        msg = await c.paste();
      case _CellMenu.clear:
        c.clearSelection();
      case _CellMenu.clearAll:
        c.clearSelection(formats: true);
      case _CellMenu.insertRowAbove:
        c.insertRows();
      case _CellMenu.insertRowBelow:
        c.insertRows(below: true);
      case _CellMenu.insertColLeft:
        c.insertColumns();
      case _CellMenu.insertColRight:
        c.insertColumns(right: true);
      case _CellMenu.deleteRows:
        c.deleteRows();
      case _CellMenu.deleteCols:
        c.deleteColumns();
      case _CellMenu.fillDown:
        c.fillDown();
      case _CellMenu.fillRight:
        c.fillRight();
      case _CellMenu.sortAsc:
        msg = c.sort(ascending: true);
      case _CellMenu.sortDesc:
        msg = c.sort(ascending: false);
      case _CellMenu.merge:
        c.mergeSelection();
      case _CellMenu.unmerge:
        c.unmergeSelection();
      case _CellMenu.freezeHere:
        c.setFrozen(c.selRow, c.selCol);
    }
    if (msg != null) _toast(msg);
    if (mounted) _gridFocus.requestFocus();
  }

  Future<void> _showTabMenu(int index, Offset global) async {
    final c = _ctrl;
    if (c == null || !c.workbook.format.supportsSheets) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size);
    final s = c.workbook.sheets[index];
    final hidden = s.visibility != SheetVisibility.visible;
    final choice = await showMenu<_TabMenu>(
      context: context,
      position: rect,
      items: [
        const PopupMenuItem(value: _TabMenu.rename, child: Text('Rename')),
        const PopupMenuItem(value: _TabMenu.duplicate, child: Text('Duplicate')),
        PopupMenuItem(value: _TabMenu.moveLeft, enabled: index > 0, child: const Text('Move left')),
        PopupMenuItem(
          value: _TabMenu.moveRight,
          enabled: index < c.workbook.sheets.length - 1,
          child: const Text('Move right'),
        ),
        if (hidden)
          const PopupMenuItem(value: _TabMenu.unhide, child: Text('Unhide'))
        else
          const PopupMenuItem(value: _TabMenu.hide, child: Text('Hide')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _TabMenu.delete,
          child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    String? msg;
    switch (choice) {
      case _TabMenu.rename:
        final name = await showTextPrompt(
          context,
          title: 'Rename sheet',
          initial: s.name,
          label: 'Sheet name',
          action: 'Rename',
          validate: (v) {
            final err = validateSheetName(v);
            if (err != null) return err;
            final other = c.workbook.sheetByName(v);
            if (other != null && !identical(other, s)) return 'A sheet with this name already exists';
            return null;
          },
        );
        if (name != null && mounted) msg = c.renameSheet(c.workbook.sheets.indexOf(s), name);
      case _TabMenu.duplicate:
        c.duplicateSheet(index);
      case _TabMenu.moveLeft:
        c.moveSheet(index, -1);
      case _TabMenu.moveRight:
        c.moveSheet(index, 1);
      case _TabMenu.hide:
        msg = c.setSheetHidden(index, true);
      case _TabMenu.unhide:
        msg = c.setSheetHidden(index, false);
      case _TabMenu.delete:
        final ok = await _confirm(
          'Delete sheet?',
          'Delete "${s.name}"? You can undo this until you close the file.',
          'Delete',
          destructive: true,
        );
        if (ok && mounted) msg = c.deleteSheet(c.workbook.sheets.indexOf(s));
    }
    if (msg != null) _toast(msg);
  }

  // ---------------------------------------------------------------------------
  // UI

  Widget _topActions(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    final c = _ctrl;
    final compact = WindowSize.of(context).isCompact;
    final buttons = <Widget>[];
    if (c != null) {
      if (!compact) {
        buttons.addAll([
          ListenableBuilder(
            listenable: c,
            builder: (context, _) => ExplorerTopBar.iconButton(
              context: context,
              icon: AppIcons.huge(HugeIcons.strokeRoundedUndo,
                  color: c.canUndo ? iconColor : iconColor.withValues(alpha: 0.35)),
              tooltip: 'Undo',
              onPressed: c.canUndo ? c.undo : null,
            ),
          ),
          ListenableBuilder(
            listenable: c,
            builder: (context, _) => ExplorerTopBar.iconButton(
              context: context,
              icon: AppIcons.huge(HugeIcons.strokeRoundedRedo,
                  color: c.canRedo ? iconColor : iconColor.withValues(alpha: 0.35)),
              tooltip: 'Redo',
              onPressed: c.canRedo ? c.redo : null,
            ),
          ),
          ExplorerTopBar.iconButton(
            context: context,
            icon: AppIcons.huge(HugeIcons.strokeRoundedSearch01, color: iconColor),
            tooltip: 'Find & replace',
            onPressed: () => _openFind(replace: false),
          ),
        ]);
      }
      buttons.add(ListenableBuilder(
        listenable: c,
        builder: (context, _) => _saving
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 13),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : ExplorerTopBar.iconButton(
                context: context,
                icon: Badge(
                  isLabelVisible: c.dirty,
                  smallSize: 7,
                  child: AppIcons.huge(HugeIcons.strokeRoundedFloppyDisk, color: iconColor),
                ),
                tooltip: c.workbook.format.canOverwrite ? 'Save' : 'Save as .xlsx',
                onPressed: _save,
              ),
      ));
      buttons.add(_moreMenu(context, iconColor, compact));
    } else {
      buttons.add(ExplorerTopBar.iconButton(
        context: context,
        icon: AppIcons.huge(HugeIcons.strokeRoundedLinkSquare02, color: iconColor),
        tooltip: 'Open in another app',
        onPressed: _openWith,
      ));
    }
    return ExplorerTopBar.actions(context, buttons);
  }

  Widget _moreMenu(BuildContext context, Color iconColor, bool compact) {
    final c = _ctrl!;
    final isCsv = c.workbook.format == SpreadsheetFormat.csv;
    final frozen = c.sheet.frozenRows > 0 || c.sheet.frozenCols > 0;
    PopupMenuItem<_Menu> item(_Menu v, IconData icon, String label) => PopupMenuItem(
          value: v,
          height: 42,
          child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 14), Expanded(child: Text(label))]),
        );
    return PopupMenuButton<_Menu>(
      tooltip: 'More options',
      icon: AppIcons.huge(HugeIcons.strokeRoundedMoreVertical, color: iconColor),
      onSelected: _onMenu,
      itemBuilder: (context) => [
        if (compact) item(_Menu.find, Icons.search_rounded, 'Find'),
        item(_Menu.replace, Icons.find_replace_rounded, 'Find & replace'),
        item(_Menu.goTo, Icons.my_location_rounded, 'Go to cell…'),
        const PopupMenuDivider(),
        item(_Menu.sortAsc, Icons.arrow_upward_rounded, 'Sort A to Z'),
        item(_Menu.sortDesc, Icons.arrow_downward_rounded, 'Sort Z to A'),
        item(_Menu.fillDown, Icons.south_rounded, 'Fill down'),
        item(_Menu.insertRow, Icons.table_rows_outlined, 'Insert row'),
        item(_Menu.insertColumn, Icons.view_column_outlined, 'Insert column'),
        item(_Menu.deleteRow, Icons.remove_circle_outline_rounded, 'Delete row'),
        item(_Menu.deleteColumn, Icons.remove_circle_outline_rounded, 'Delete column'),
        const PopupMenuDivider(),
        item(_Menu.freezeHere, Icons.ac_unit_rounded, 'Freeze at selection'),
        item(_Menu.freezeTopRow, Icons.border_top_rounded, 'Freeze top row'),
        item(_Menu.freezeFirstColumn, Icons.border_left_rounded, 'Freeze first column'),
        if (frozen) item(_Menu.unfreeze, Icons.grid_off_rounded, 'Unfreeze panes'),
        item(_Menu.recalc, Icons.functions_rounded, 'Recalculate'),
        if (isCsv) ...[
          const PopupMenuDivider(),
          item(_Menu.delimiter, Icons.space_bar_rounded,
              'Delimiter: ${CsvSettings.delimiterLabel(c.workbook.csv?.delimiter ?? ',')}'),
          CheckedPopupMenuItem(
            value: _Menu.header,
            checked: c.workbook.csv?.hasHeader ?? false,
            child: const Text('First row is header'),
          ),
        ],
        const PopupMenuDivider(),
        item(_Menu.saveCopy, Icons.save_as_outlined, 'Save a copy as .xlsx'),
        item(_Menu.exportCsv, Icons.description_outlined, 'Export sheet as CSV'),
        item(_Menu.openWith, Icons.open_in_new_rounded, 'Open in another app'),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: DockedGlossyTopBar.contentTopInset(context)),
      child: Center(
        child: ReadableWidth(
          maxWidth: 460,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.grid_off_rounded, size: 56, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('Can\'t open this spreadsheet', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(_error ?? '', style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Try again'),
                    ),
                    FilledButton.icon(
                      onPressed: _openWith,
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open in another app'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// First frame while the file is read: an empty grid, not a spinner.
  Widget _buildSkeleton(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(height: DockedGlossyTopBar.contentTopInset(context)),
        Material(
          color: theme.colorScheme.surface.withValues(alpha: 0.94),
          child: SizedBox(height: WindowSize.of(context).isCompact ? 40 : 44, width: double.infinity),
        ),
        const LinearProgressIndicator(minHeight: 1),
        Expanded(
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: _SkeletonGridPainter(GridColors.of(context)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditor(BuildContext context, SpreadsheetController c) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final ws = WindowSize.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final compact = ws.isCompact;
    final hideChrome = compact && keyboard;
    final surface = theme.colorScheme.surface.withValues(alpha: 0.94);
    final canSheets = c.workbook.format.supportsSheets;

    final formulaBar = FormulaBar(
      controller: c,
      focusNode: _formulaFocus,
      onCommit: _commit,
      onCancel: _cancelEdit,
      onGoTo: _goTo,
      dense: compact,
    );
    final toolbar = FormatToolbar(controller: c, showUndoRedo: compact);

    Widget topBars;
    if (width >= 1100) {
      topBars = Row(
        children: [
          Expanded(flex: 5, child: formulaBar),
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
          Expanded(flex: 6, child: SizedBox(height: 44, child: toolbar)),
        ],
      );
    } else {
      topBars = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          formulaBar,
          if (!hideChrome) ...[
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            SizedBox(height: 44, child: toolbar),
          ],
        ],
      );
    }

    final grid = SheetGrid(
      controller: c,
      focusNode: _gridFocus,
      editorFocusNode: _editorFocus,
      onContextMenu: _showCellMenu,
      onMessage: _toast,
    );

    return Focus(
      onKeyEvent: _onScreenKey,
      child: Column(
        children: [
          SizedBox(height: DockedGlossyTopBar.contentTopInset(context)),
          Material(color: surface, child: topBars),
          if (_findOpen)
            FindReplaceBar(
              key: ValueKey(_findKey),
              controller: c,
              replaceMode: _replaceMode,
              onClose: _closeFind,
              onMessage: _toast,
            ),
          if (_previewing)
            const LinearProgressIndicator(minHeight: 1)
          else
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: AdaptiveSplitView(
              secondaryOnLeading: false,
              secondaryWidth: 300,
              primary: grid,
              secondary: SheetSidePanel(
                controller: c,
                onTabMenu: _showTabMenu,
                onAdd: canSheets ? c.addSheet : null,
              ),
            ),
          ),
          if (!hideChrome)
            Material(
              color: surface,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
                    SheetStatusBar(controller: c),
                    SheetTabs(
                      controller: c,
                      onTabMenu: _showTabMenu,
                      onAdd: canSheets ? c.addSheet : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onPop();
      },
      child: ExplorerScaffold(
        title: '${c?.dirty == true ? '• ' : ''}$_fileName',
        trailing: _topActions(context),
        body: _error != null
            ? _buildError(context)
            : (c != null && (!_loading || _previewing))
                ? _buildEditor(context, c)
                : _buildSkeleton(context),
      ),
    );
  }
}

// Isolate entry points live at top level so their closures can't capture the
// widget state (which isn't sendable to another isolate).

Future<Workbook> _parseInBackground(Uint8List bytes, String name, CsvLoadOptions? csv) =>
    Isolate.run(() => loadWorkbook(bytes, fileName: name, csv: csv));

Future<Workbook?> _previewInBackground(Uint8List bytes, String name, CsvLoadOptions? csv) =>
    Isolate.run(() => loadWorkbookPreview(bytes, fileName: name, csv: csv));

/// Header bands and grid lines at default sizes (no text, so it costs
/// nothing to lay out on the first frame).
class _SkeletonGridPainter extends CustomPainter {
  _SkeletonGridPainter(this.colors);

  final GridColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    const headerH = 22.0;
    const headerW = 40.0;
    const colW = kDefaultColWidth;
    const rowH = kDefaultRowHeight;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.paper);
    final header = Paint()..color = colors.header;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, headerH), header);
    canvas.drawRect(Rect.fromLTWH(0, 0, headerW, size.height), header);
    final grid = Paint()
      ..color = colors.gridLine
      ..strokeWidth = 1;
    final line = Paint()
      ..color = colors.headerLine
      ..strokeWidth = 1;
    for (var x = headerW + colW; x < size.width; x += colW) {
      canvas.drawLine(Offset(x, headerH), Offset(x, size.height), grid);
      canvas.drawLine(Offset(x, 0), Offset(x, headerH), line);
    }
    for (var y = headerH + rowH; y < size.height; y += rowH) {
      canvas.drawLine(Offset(headerW, y), Offset(size.width, y), grid);
      canvas.drawLine(Offset(0, y), Offset(headerW, y), line);
    }
    canvas.drawLine(const Offset(0, headerH), Offset(size.width, headerH), line);
    canvas.drawLine(const Offset(headerW, 0), Offset(headerW, size.height), line);
  }

  @override
  bool shouldRepaint(covariant _SkeletonGridPainter old) => old.colors != colors;
}

Future<XlsxWriteResult> _writeXlsxInBackground(
        Workbook wb, Uint8List? original, SpreadsheetFormat target) =>
    Isolate.run(() => XlsxWriter.writePackage(wb, original: original, target: target));

Future<Uint8List> _writeCsvInBackground(SheetData sheet, String delimiter, String newline,
        bool date1904, TextEncodingKind encoding) =>
    Isolate.run(() => CsvCodec.encode(
          CsvCodec.write(sheet, delimiter: delimiter, newline: newline, date1904: date1904),
          encoding,
        ));
