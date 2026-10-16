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
    RandomAccessFile? raf;
    try {
      raf = await widget.file.open();
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
      if (_raf == null) {
        try {
          await raf?.close();
        } catch (_) {}
      }
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    // A read may be in flight, and RandomAccessFile refuses to close while
    // one is pending ("An async operation is currently pending"), which
    // leaked the handle. Close after the queued work instead; queued reads
    // see `_raf == null` and skip.
    final raf = _raf;
    _raf = null;
    _pending.catchError((Object _) {}).whenComplete(() async {
      try {
        await raf?.close();
      } catch (_) {}
    });
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

  /// Bytes per row and row height of the current layout, to tell whether a
  /// queued page is still near the viewport.
  int _bytesPerRow = 16;
  double _rowHeight = 22;

  bool _isNearViewport(int index) {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    final firstRow = (position.pixels / _rowHeight).floor();
    final lastRow = ((position.pixels + position.viewportDimension) / _rowHeight).ceil();
    final firstPage = firstRow * _bytesPerRow ~/ _pageSize;
    final lastPage = lastRow * _bytesPerRow ~/ _pageSize;
    return index >= firstPage - 1 && index <= lastPage + 1;
  }

  void _readPage(int index) {
    _pending = _pending.then((_) async {
      if (_raf == null || !mounted) return;
      // Fast scrolling queues many pages; skip the ones scrolled past (the
      // row asks again if it comes back into view).
      if (!_isNearViewport(index)) {
        _loading.remove(index);
        return;
      }
      Uint8List bytes;
      try {
        final raf = _raf;
        if (raf == null) return;
        await raf.setPosition(index * _pageSize);
        if (!mounted || _raf == null) return;
        bytes = await raf.read(_pageSize);
      } catch (e) {
        // Keep the chain alive; show the error rather than retrying forever.
        if (mounted) setState(() => _error = '$e');
        return;
      }
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
    _bytesPerRow = bytesPerRow;
    _rowHeight = rowHeight;
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
