import 'cell.dart';

export 'cell.dart';

enum SheetVisibility { visible, hidden, veryHidden }

/// Source/target file formats.
enum SpreadsheetFormat {
  xlsx,
  xlsm,
  xltx,
  xltm,
  xls,
  csv,
  ods;

  bool get isXlsxFamily =>
      this == xlsx || this == xlsm || this == xltx || this == xltm;
  bool get isMacroEnabled => this == xlsm || this == xltm;

  /// Formats this app can write back in place.
  bool get canOverwrite => isXlsxFamily || this == csv;

  /// Whether multiple sheets can be kept when saving in place.
  bool get supportsSheets => this != csv;

  static SpreadsheetFormat? fromExtension(String ext) {
    switch (ext.toLowerCase().replaceFirst('.', '')) {
      case 'xlsx':
        return xlsx;
      case 'xlsm':
        return xlsm;
      case 'xltx':
        return xltx;
      case 'xltm':
        return xltm;
      case 'xls':
      case 'xlt':
        return xls;
      case 'csv':
      case 'tsv':
      case 'tab':
      case 'psv':
      case 'txt':
        return csv;
      case 'ods':
      case 'ots':
        return ods;
    }
    return null;
  }

  String get label => switch (this) {
        xlsx => 'Excel workbook',
        xlsm => 'Excel macro-enabled workbook',
        xltx => 'Excel template',
        xltm => 'Excel macro-enabled template',
        xls => 'Excel 97-2003 workbook',
        csv => 'Delimited text',
        ods => 'OpenDocument spreadsheet',
      };
}

/// Text encoding detected for delimited files, so saving keeps it.
enum TextEncodingKind { utf8, utf8Bom, utf16le, utf16be, cp1252 }

/// Settings for CSV/TSV files.
class CsvSettings {
  CsvSettings({
    this.delimiter = ',',
    this.hasHeader = false,
    this.encoding = TextEncodingKind.utf8,
    this.newline = '\r\n',
  });

  String delimiter;
  bool hasHeader;
  TextEncodingKind encoding;
  String newline;

  CsvSettings copy() => CsvSettings(
        delimiter: delimiter,
        hasHeader: hasHeader,
        encoding: encoding,
        newline: newline,
      );

  static String delimiterLabel(String d) => switch (d) {
        ',' => 'Comma',
        ';' => 'Semicolon',
        '\t' => 'Tab',
        '|' => 'Pipe',
        _ => d,
      };
}

/// Default sizes, in logical pixels at 100% zoom.
const double kDefaultColWidth = 64;
const double kDefaultRowHeight = 20;

/// One worksheet: a sparse cell map plus layout.
class SheetData {
  SheetData({
    required this.name,
    Map<int, Cell>? cells,
    Map<int, double>? colWidths,
    Map<int, double>? rowHeights,
    Set<int>? hiddenRows,
    Set<int>? hiddenCols,
    List<CellRange>? merges,
    this.defaultColWidth = kDefaultColWidth,
    this.defaultRowHeight = kDefaultRowHeight,
    this.frozenRows = 0,
    this.frozenCols = 0,
    this.visibility = SheetVisibility.visible,
    this.sourcePath,
    this.sourceIndex,
    this.sourceName,
    this.structureChanged = false,
  })  : cells = cells ?? <int, Cell>{},
        colWidths = colWidths ?? <int, double>{},
        rowHeights = rowHeights ?? <int, double>{},
        hiddenRows = hiddenRows ?? <int>{},
        hiddenCols = hiddenCols ?? <int>{},
        merges = merges ?? <CellRange>[];

  String name;
  Map<int, Cell> cells;
  Map<int, double> colWidths;
  Map<int, double> rowHeights;
  Set<int> hiddenRows;
  Set<int> hiddenCols;
  List<CellRange> merges;
  double defaultColWidth;
  double defaultRowHeight;
  int frozenRows;
  int frozenCols;
  SheetVisibility visibility;

  /// Part path inside the original xlsx package (`xl/worksheets/sheet1.xml`).
  String? sourcePath;

  /// Position of this sheet in the original workbook (for defined names).
  int? sourceIndex;

  /// Name of the sheet when it was loaded (to rewrite defined names).
  String? sourceName;

  /// True once rows/columns were inserted or deleted; the xlsx writer then
  /// drops range-bound extras (tables, conditional formats) of this sheet.
  bool structureChanged;

  int _maxRow = -1;
  int _maxCol = -1;
  bool _boundsDirty = true;

  Cell? cell(int row, int col) => cells[cellKey(row, col)];

  Object? valueAt(int row, int col) => cells[cellKey(row, col)]?.value;

  void setCell(int row, int col, Cell? cell) {
    final key = cellKey(row, col);
    if (cell == null) {
      if (cells.remove(key) != null && (row >= _maxRow || col >= _maxCol)) {
        _boundsDirty = true;
      }
      return;
    }
    cells[key] = cell;
    if (!_boundsDirty) {
      if (row > _maxRow) _maxRow = row;
      if (col > _maxCol) _maxCol = col;
    }
  }

  void invalidateBounds() => _boundsDirty = true;

  void _computeBounds() {
    var mr = -1;
    var mc = -1;
    for (final k in cells.keys) {
      final r = k ~/ kMaxCols;
      final c = k % kMaxCols;
      if (r > mr) mr = r;
      if (c > mc) mc = c;
    }
    for (final m in merges) {
      if (m.r2 > mr) mr = m.r2;
      if (m.c2 > mc) mc = m.c2;
    }
    _maxRow = mr;
    _maxCol = mc;
    _boundsDirty = false;
  }

  /// Number of rows in use (last used row + 1).
  int get usedRows {
    if (_boundsDirty) _computeBounds();
    return _maxRow + 1;
  }

  /// Number of columns in use (last used column + 1).
  int get usedCols {
    if (_boundsDirty) _computeBounds();
    return _maxCol + 1;
  }

  double colWidth(int col) =>
      hiddenCols.contains(col) ? 0 : (colWidths[col] ?? defaultColWidth);

  double rowHeight(int row) =>
      hiddenRows.contains(row) ? 0 : (rowHeights[row] ?? defaultRowHeight);

  /// The merged range containing (row, col), if any.
  CellRange? mergeAt(int row, int col) {
    for (final m in merges) {
      if (m.contains(row, col)) return m;
    }
    return null;
  }

  SheetData clone({String? name}) => SheetData(
        name: name ?? this.name,
        cells: Map.of(cells),
        colWidths: Map.of(colWidths),
        rowHeights: Map.of(rowHeights),
        hiddenRows: Set.of(hiddenRows),
        hiddenCols: Set.of(hiddenCols),
        merges: List.of(merges),
        defaultColWidth: defaultColWidth,
        defaultRowHeight: defaultRowHeight,
        frozenRows: frozenRows,
        frozenCols: frozenCols,
        visibility: visibility,
        sourcePath: sourcePath,
        sourceIndex: sourceIndex,
        sourceName: sourceName,
        structureChanged: structureChanged,
      );

  /// Replaces this sheet's content with [o]'s (keeps object identity).
  void restoreFrom(SheetData o) {
    name = o.name;
    cells = Map.of(o.cells);
    colWidths = Map.of(o.colWidths);
    rowHeights = Map.of(o.rowHeights);
    hiddenRows = Set.of(o.hiddenRows);
    hiddenCols = Set.of(o.hiddenCols);
    merges = List.of(o.merges);
    defaultColWidth = o.defaultColWidth;
    defaultRowHeight = o.defaultRowHeight;
    frozenRows = o.frozenRows;
    frozenCols = o.frozenCols;
    visibility = o.visibility;
    sourcePath = o.sourcePath;
    sourceIndex = o.sourceIndex;
    sourceName = o.sourceName;
    structureChanged = o.structureChanged;
    _boundsDirty = true;
  }
}

/// A whole workbook as loaded from any supported format.
class Workbook {
  Workbook({
    required this.sheets,
    required this.format,
    this.date1904 = false,
    this.activeSheet = 0,
    this.csv,
    List<String>? warnings,
  }) : warnings = warnings ?? <String>[];

  final List<SheetData> sheets;
  SpreadsheetFormat format;
  bool date1904;
  int activeSheet;

  /// Only for delimited files.
  CsvSettings? csv;

  /// Non-fatal notes from the reader (skipped chart sheets etc).
  final List<String> warnings;

  SheetData? sheetByName(String name) {
    final lower = name.toLowerCase();
    for (final s in sheets) {
      if (s.name.toLowerCase() == lower) return s;
    }
    return null;
  }

  int indexOfSheetName(String name) {
    final lower = name.toLowerCase();
    for (var i = 0; i < sheets.length; i++) {
      if (sheets[i].name.toLowerCase() == lower) return i;
    }
    return -1;
  }

  /// A sheet name not used yet, based on [base].
  String uniqueSheetName(String base) {
    if (sheetByName(base) == null) return base;
    var n = 2;
    while (sheetByName('$base ($n)') != null) {
      n++;
    }
    return '$base ($n)';
  }
}

/// Characters Excel forbids in sheet names.
final RegExp invalidSheetNameChars = RegExp(r'[\\/?*\[\]:]');

/// Returns an error message, or null when [name] is a valid sheet name.
String? validateSheetName(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Name can\'t be empty';
  if (n.length > 31) return 'Use 31 characters or fewer';
  if (invalidSheetNameChars.hasMatch(n)) {
    return 'Name can\'t contain \\ / ? * [ ] :';
  }
  if (n.startsWith("'") || n.endsWith("'")) {
    return 'Name can\'t start or end with an apostrophe';
  }
  return null;
}
