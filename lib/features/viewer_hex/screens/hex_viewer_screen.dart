import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Read-only hex dump for any file. Pages are read lazily so multi-gigabyte
/// files open instantly.
class HexViewerScreen extends StatefulWidget {
  const HexViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<HexViewerScreen> createState() => _HexViewerScreenState();
}

class _HexViewerScreenState extends State<HexViewerScreen> {
  static const _pageSize = 64 * 1024;

  RandomAccessFile? _raf;
  int _length = 0;
  String? _error;
  final Map<int, Uint8List> _pages = {};
  final Set<int> _loading = {};
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final raf = await widget.file.open();
      final length = await raf.length();
      if (!mounted) {
        await raf.close();
        return;
      }
      setState(() {
        _raf = raf;
        _length = length;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _raf?.close();
    _scroll.dispose();
    super.dispose();
  }

  Uint8List? _page(int index) {
    final cached = _pages[index];
    if (cached != null) return cached;
    if (_loading.add(index)) {
      _readPage(index);
    }
    return null;
  }

  // RandomAccessFile allows one pending operation at a time, so reads are
  // chained.
  Future<void> _pending = Future.value();

  void _readPage(int index) {
    _pending = _pending.then((_) async {
      final raf = _raf;
      if (raf == null || !mounted) return;
      await raf.setPosition(index * _pageSize);
      final bytes = await raf.read(_pageSize);
      if (!mounted) return;
      if (_pages.length > 64) _pages.remove(_pages.keys.first);
      setState(() {
        _pages[index] = bytes;
        _loading.remove(index);
      });
    });
  }

  Future<void> _jumpToOffset(int bytesPerRow, double rowHeight) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to offset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. 1024 or 0x400',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final text = value.trim().toLowerCase();
    final offset = text.startsWith('0x')
        ? int.tryParse(text.substring(2), radix: 16)
        : int.tryParse(text);
    if (offset == null || !_scroll.hasClients) return;
    final row = offset.clamp(0, _length) ~/ bytesPerRow;
    _scroll.jumpTo(
      (row * rowHeight).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final bytesPerRow = width >= 720 ? 16 : 8;
    const rowHeight = 22.0;
    final iconColor = ClearGlassForeground.icon(context);
    final rows = (_length + bytesPerRow - 1) ~/ bytesPerRow;
    final topInset = DockedGlossyTopBar.contentTopInset(context);

    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      trailing: ExplorerTopBar.actions(context, [
        ExplorerTopBar.iconButton(
          context: context,
          icon: Icon(Icons.pin_drop_outlined, color: iconColor),
          tooltip: 'Go to offset',
          onPressed: _raf == null
              ? null
              : () => _jumpToOffset(bytesPerRow, rowHeight),
        ),
      ]),
      body: _error != null
          ? Center(child: Text('Cannot read file: $_error'))
          : _raf == null
              ? const Center(child: CircularProgressIndicator())
              : Scrollbar(
                  controller: _scroll,
                  interactive: true,
                  thumbVisibility: true,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(
                      12,
                      topInset + 8,
                      12,
                      24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    itemExtent: rowHeight,
                    itemCount: rows,
                    itemBuilder: (context, row) =>
                        _buildRow(context, row, bytesPerRow),
                  ),
                ),
    );
  }

  Widget _buildRow(BuildContext context, int row, int bytesPerRow) {
    final scheme = Theme.of(context).colorScheme;
    final start = row * bytesPerRow;
    final page = _page(start ~/ _pageSize);
    final style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier'],
      fontSize: 13,
      color: scheme.onSurface,
    );
    final offset = start.toRadixString(16).padLeft(8, '0').toUpperCase();
    if (page == null) {
      return Text(offset, style: style.copyWith(color: scheme.outline));
    }
    final hex = StringBuffer();
    final ascii = StringBuffer();
    for (var i = 0; i < bytesPerRow; i++) {
      final pos = start + i;
      final inPage = pos - (start ~/ _pageSize) * _pageSize;
      if (pos >= _length || inPage >= page.length) {
        hex.write('   ');
        continue;
      }
      final b = page[inPage];
      hex.write('${b.toRadixString(16).padLeft(2, '0').toUpperCase()} ');
      ascii.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text.rich(
        TextSpan(
          style: style,
          children: [
            TextSpan(text: '$offset  ', style: TextStyle(color: scheme.outline)),
            TextSpan(text: '$hex '),
            TextSpan(text: ascii.toString(), style: TextStyle(color: scheme.primary)),
          ],
        ),
        maxLines: 1,
      ),
    );
  }
}
