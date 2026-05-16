import 'dart:io';

import 'package:excel/excel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class ExcelViewerScreen extends StatefulWidget {
  final File file;

  const ExcelViewerScreen({super.key, required this.file});

  @override
  State<ExcelViewerScreen> createState() => _ExcelViewerScreenState();
}

class _ExcelViewerScreenState extends State<ExcelViewerScreen> {
  Excel? _excel;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadExcel();
  }

  Future<void> _loadExcel() async {
    try {
      final bytes = await widget.file.readAsBytes();
      var excel = Excel.decodeBytes(bytes);

      setState(() {
        _excel = excel;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Error loading excel: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to load Excel file: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_excel == null || _excel!.tables.isEmpty) {
      return const Center(child: Text('No sheets found in this Excel file.'));
    }

    // If only one table, just show it. If multiple, use DefaultTabController.
    final tables = _excel!.tables.keys.toList();

    if (tables.isEmpty) {
      return const Center(child: Text('Empty Excel file'));
    }

    return DefaultTabController(
      length: tables.length,
      child: Column(
        children: [
          Container(
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            child: TabBar(
              isScrollable: true,
              tabs: tables.map((name) => Tab(text: name)).toList(),
              labelColor: Theme.of(context).primaryColor,
              unselectedLabelColor: Colors.grey,
            ),
          ),
          Expanded(
            child: TabBarView(
              children: tables.map((name) {
                return _buildSheet(_excel!.tables[name]!);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSheet(Sheet sheet) {
    if (sheet.maxRows == 0) {
      return const Center(child: Text('Empty Sheet'));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: _buildColumns(sheet),
          rows: _buildRows(sheet),
          headingRowColor: MaterialStateProperty.all(
            Theme.of(context).colorScheme.surfaceVariant,
          ),
          border: TableBorder.all(
            color: Colors.grey.withOpacity(0.3),
            width: 1,
          ),
        ),
      ),
    );
  }

  List<DataColumn> _buildColumns(Sheet sheet) {
    // Determine max columns based on the first few rows to ensure we cover headers
    // But Sheet.maxColumns usually gives the max used columns.
    // However, we need to be careful if rows have different lengths.
    // We'll trust sheet.maxColumns

    final int colCount = sheet.maxColumns;

    // For simplicity, we'll name columns A, B, C... or use the first row as header if preferred.
    // Excel usually has A, B, C headers separate from data, but often the first row IS the header data.
    // Let's use the first row as headers if available, otherwise generic headers.

    // Actually, looking at typical Excel viewer behavior, it's safer to generate A, B, C... headers
    // AND display the first row as data, unless we implement a toggle.
    // But standard DataTable requires fixed columns.

    // Let's generate A, B, C... headers.

    return List.generate(colCount, (index) {
      return DataColumn(
        label: Text(
          _getExcelColumnName(index),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    });
  }

  String _getExcelColumnName(int columnIndex) {
    // Convert 0 -> A, 1 -> B, ... 26 -> AA
    String name = '';
    int index = columnIndex;

    while (index >= 0) {
      name = String.fromCharCode((index % 26) + 65) + name;
      index = (index / 26).floor() - 1;
    }
    return name;
  }

  List<DataRow> _buildRows(Sheet sheet) {
    // sheet.rows gives us a List<List<Data?>>
    // We should iterate carefully.

    // Limit rows for performance if needed, but DataTable acts weird with huge data.
    // For a simple viewer, we'll try to render all, but maybe limit to 100 or paginate.
    // However, the user wants "Excel Support", usually implies full viewing or at least reasonable.
    // Let's render up to 500 rows for now to avoid freezing UI on massive files.

    final rowsToRender = sheet.rows.take(500).toList();
    final int maxCols = sheet.maxColumns;

    return rowsToRender.map((row) {
      // row is List<Data?>
      // We need to match maxCols. Padded with Scroll/Empty if needed.

      final cells = List<DataCell>.generate(maxCols, (index) {
        if (index < row.length) {
          final cell = row[index];
          return DataCell(
            Text(
              cell?.value?.toString() ?? '',
              overflow: TextOverflow.ellipsis,
            ),
          );
        } else {
          return const DataCell(Text(''));
        }
      });

      return DataRow(cells: cells);
    }).toList();
  }
}
