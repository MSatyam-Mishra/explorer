import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import 'grid_colors.dart';

/// Row/column geometry of the table (table index 0 is the header).
class _Geometry {
  _Geometry({
    required this.sheet,
    required this.zoom,
    required this.rows,
    required this.cols,
    required this.headerHeight,
    required this.headerWidth,
    required this.viewport,
  }) {
    rowOffsets = Float64List(rows + 2);
    rowOffsets[1] = headerHeight;
    for (var i = 0; i < rows; i++) {
      rowOffsets[i + 2] = rowOffsets[i + 1] + sheet.rowHeight(i) * zoom;
    }
    colOffsets = Float64List(cols + 2);
    colOffsets[1] = headerWidth;
    for (var i = 0; i < cols; i++) {
      colOffsets[i + 2] = colOffsets[i + 1] + sheet.colWidth(i) * zoom;
    }
    // Frozen panes (pinned extent must stay below the viewport size).
    var fr = sheet.frozenRows.clamp(0, rows);
    while (fr > 0 && rowOffsets[fr + 1] > viewport.height * 0.6) {
      fr--;
    }
    var fc = sheet.frozenCols.clamp(0, cols);
    while (fc > 0 && colOffsets[fc + 1] > viewport.width * 0.6) {
      fc--;
    }
    pinnedRows = 1 + fr;
    pinnedCols = 1 + fc;
  }

  final SheetData sheet;
  final double zoom;
  final int rows;
  final int cols;
  final double headerHeight;
  final double headerWidth;
  final Size viewport;
  late final Float64List rowOffsets;
  late final Float64List colOffsets;
  late final int pinnedRows;
  late final int pinnedCols;

  double rowExtent(int t) => rowOffsets[t + 1] - rowOffsets[t];
  double colExtent(int t) => colOffsets[t + 1] - colOffsets[t];
  double get pinnedHeight => rowOffsets[pinnedRows];
  double get pinnedWidth => colOffsets[pinnedCols];

  static int _search(Float64List offsets, double v, int lo, int hi) {
    // Largest i in [lo, hi) with offsets[i] <= v.
    var a = lo;
    var b = hi - 1;
    var ans = lo;
    while (a <= b) {
      final m = (a + b) >> 1;
      if (offsets[m] <= v) {
        ans = m;
        a = m + 1;
      } else {
        b = m - 1;
      }
    }
    return ans;
  }

  /// Table (row, col) at a viewport position.
  (int, int) hit(Offset p, double vOffset, double hOffset) {
    int row;
    if (p.dy < pinnedHeight) {
      row = _search(rowOffsets, p.dy, 0, pinnedRows);
    } else {
      final y = p.dy - pinnedHeight + vOffset + rowOffsets[pinnedRows];
      row = _search(rowOffsets, y, pinnedRows, rows + 1);
    }
    int col;
    if (p.dx < pinnedWidth) {
      col = _search(colOffsets, p.dx, 0, pinnedCols);
    } else {
      final x = p.dx - pinnedWidth + hOffset + colOffsets[pinnedCols];
      col = _search(colOffsets, x, pinnedCols, cols + 1);
    }
    return (row, col);
  }
}

class _GridScrollBehavior extends MaterialScrollBehavior {
  const _GridScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    return Scrollbar(controller: details.controller, interactive: true, child: child);
  }

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };
}

/// Lazily rendered spreadsheet grid with pinned headers, frozen panes,
/// merged cells, selection, resizing, zoom and keyboard navigation.
class SheetGrid extends StatefulWidget {
  const SheetGrid({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.editorFocusNode,
    required this.onContextMenu,
    this.onKey,
    this.onMessage,
  });

  final SpreadsheetController controller;
  final FocusNode focusNode;
  final FocusNode editorFocusNode;
  final void Function(Offset globalPosition) onContextMenu;

  /// Screen-level shortcuts, tried before the grid's own handling.
  final KeyEventResult Function(KeyEvent event)? onKey;
  final void Function(String message)? onMessage;

  @override
  State<SheetGrid> createState() => _SheetGridState();
}

class _SheetGridState extends State<SheetGrid> {
  final ScrollController _v = ScrollController();
  final ScrollController _h = ScrollController();
  TableCellBuilderDelegate? _delegate;
  final List<TableCellBuilderDelegate> _retired = [];
  _Geometry? _geo;
  int _builtLayout = -1;
  Size _builtSize = Size.zero;
  Map<int, CellRange> _mergeIndex = const {};
  final Map<double, TableSpan> _spanCache = {};

  // Pointer state
  final Map<int, Offset> _touches = {};
  double? _pinchStartDistance;
  double _pinchStartZoom = 1;
  bool _mouseSelecting = false;
  bool _mousePointing = false;
  _DragKind _dragKind = _DragKind.cells;
  DateTime _lastClick = DateTime(0);
  (int, int)? _lastClickCell;
  bool _longPressMoved = false;
  (int, int)? _longPressStart;
  Timer? _autoScroll;
  Offset? _lastDragPos;
  int? _resizeCol;
  double _resizeStartWidth = 0;
  double _resizeAccum = 0;

  SpreadsheetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    c.onRevealCell = _reveal;
  }

  @override
  void didUpdateWidget(covariant SheetGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onController);
      if (oldWidget.controller.onRevealCell == _reveal) oldWidget.controller.onRevealCell = null;
      widget.controller.addListener(_onController);
      widget.controller.onRevealCell = _reveal;
      _builtLayout = -1;
    }
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    if (c.onRevealCell == _reveal) c.onRevealCell = null;
    _autoScroll?.cancel();
    _zoomTimer?.cancel();
    _v.dispose();
    _h.dispose();
    _delegate?.dispose();
    for (final d in _retired) {
      d.dispose();
    }
    super.dispose();
  }

  bool _wasEditing = false;

  void _onController() {
    if (c.layoutVersion != _builtLayout) setState(() {});
    if (_wasEditing && !c.editing && widget.editorFocusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
    _wasEditing = c.editing;
  }

  // ---------------------------------------------------------------------------
  // Layout

  double get _headerHeight => (22 * c.zoom.clamp(0.8, 1.4)).roundToDouble();

  double _headerWidth(int rows) {
    final digits = rows.toString().length;
    return ((digits * 7.5 + 18) * c.zoom.clamp(0.8, 1.4)).roundToDouble();
  }

  void _rebuildIfNeeded(Size size) {
    if (_geo != null && _builtLayout == c.layoutVersion && _builtSize == size) return;
    final sheet = c.sheet;
    final geo = _Geometry(
      sheet: sheet,
      zoom: c.zoom,
      rows: c.displayRows,
      cols: c.displayCols,
      headerHeight: _headerHeight,
      headerWidth: _headerWidth(c.displayRows),
      viewport: size,
    );
    _geo = geo;
    _builtLayout = c.layoutVersion;
    _builtSize = size;
    _mergeIndex = _buildMergeIndex(sheet, geo);
    final old = _delegate;
    _delegate = TableCellBuilderDelegate(
      rowCount: geo.rows + 1,
      columnCount: geo.cols + 1,
      pinnedRowCount: geo.pinnedRows,
      pinnedColumnCount: geo.pinnedCols,
      rowBuilder: (i) => _span(geo.rowExtent(i)),
      columnBuilder: (i) => _span(geo.colExtent(i)),
      cellBuilder: _buildCell,
    );
    if (old != null) {
      _retired.add(old);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_retired.contains(old)) {
          _retired.remove(old);
          old.dispose();
        }
      });
    }
  }

  TableSpan _span(double extent) {
    final e = (extent * 100).roundToDouble() / 100;
    return _spanCache.putIfAbsent(e, () => TableSpan(extent: FixedTableSpanExtent(e)));
  }

  Map<int, CellRange> _buildMergeIndex(SheetData sheet, _Geometry geo) {
    if (sheet.merges.isEmpty) return const {};
    final out = <int, CellRange>{};
    var budget = 2000000;
    final fr = geo.pinnedRows - 1;
    final fc = geo.pinnedCols - 1;
    for (final m in sheet.merges) {
      if (m.r2 >= geo.rows || m.c2 >= geo.cols) continue;
      // Merges can't straddle the frozen boundary.
      if (m.r1 < fr && m.r2 >= fr) continue;
      if (m.c1 < fc && m.c2 >= fc) continue;
      if (m.area > budget) break;
      budget -= m.area;
      for (var r = m.r1; r <= m.r2; r++) {
        for (var col = m.c1; col <= m.c2; col++) {
          out[cellKey(r, col)] = m;
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Scrolling

  void _reveal(int row, int col) {
    final geo = _geo;
    if (geo == null || !_v.hasClients || !_h.hasClients || _builtLayout != c.layoutVersion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _geo != null && _v.hasClients && _builtLayout == c.layoutVersion) {
          _reveal(row, col);
        }
      });
      return;
    }
    final tr = row + 1;
    final tc = col + 1;
    if (tr < geo.rows + 1 && tr >= geo.pinnedRows) {
      final top = geo.rowOffsets[tr] - geo.pinnedHeight;
      final bottom = geo.rowOffsets[tr + 1] - geo.pinnedHeight;
      final visible = _builtSize.height - geo.pinnedHeight;
      final pos = _v.position;
      var target = pos.pixels;
      if (top < pos.pixels) {
        target = top;
      } else if (bottom > pos.pixels + visible) {
        target = bottom - visible;
      }
      target = target.clamp(pos.minScrollExtent, math.max(pos.maxScrollExtent, target));
      if ((target - pos.pixels).abs() > 0.5) _v.jumpTo(target);
    }
    if (tc < geo.cols + 1 && tc >= geo.pinnedCols) {
      final left = geo.colOffsets[tc] - geo.pinnedWidth;
      final right = geo.colOffsets[tc + 1] - geo.pinnedWidth;
      final visible = _builtSize.width - geo.pinnedWidth;
      final pos = _h.position;
      var target = pos.pixels;
      if (left < pos.pixels) {
        target = left;
      } else if (right > pos.pixels + visible) {
        target = right - visible;
      }
      target = target.clamp(pos.minScrollExtent, math.max(pos.maxScrollExtent, target));
      if ((target - pos.pixels).abs() > 0.5) _h.jumpTo(target);
    }
  }

  (int, int)? _hit(Offset local) {
    final geo = _geo;
    if (geo == null) return null;
    final v = _v.hasClients ? _v.offset : 0.0;
    final h = _h.hasClients ? _h.offset : 0.0;
    return geo.hit(local, v, h);
  }

  /// Commits a pending edit before the selection moves. Returns false (and
  /// reports why) when the edit can't be committed.
  bool _commitBeforeSelect() {
    if (!c.editing) return true;
    final err = c.commitEdit();
    if (err != null) {
      widget.onMessage?.call(err);
      return false;
    }
    return true;
  }

  /// Whether (r, col) is the active cell or part of its merged area.
  bool _isActiveArea(int r, int col) {
    final m = _mergeIndex[cellKey(r, col)];
    return m == null ? (r == c.selRow && col == c.selCol) : m.contains(c.selRow, c.selCol);
  }

  /// True when [local] is on a column header's resize handle.
  bool _onResizeHandle(Offset local) {
    final geo = _geo;
    if (geo == null || local.dy > geo.headerHeight) return false;
    final hit = _hit(local);
    if (hit == null || hit.$1 != 0 || hit.$2 == 0) return false;
    final tc = hit.$2;
    final h = _h.hasClients ? _h.offset : 0.0;
    final right = tc < geo.pinnedCols
        ? geo.colOffsets[tc + 1]
        : geo.colOffsets[tc + 1] - geo.colOffsets[geo.pinnedCols] + geo.pinnedWidth - h;
    return right - local.dx <= 14;
  }

  // ---------------------------------------------------------------------------
  // Pointer handling

  void _onPointerDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      _touches[e.pointer] = e.localPosition;
      if (_touches.length == 2) {
        final pts = _touches.values.toList();
        _pinchStartDistance = (pts[0] - pts[1]).distance;
        _pinchStartZoom = c.zoom;
      }
      return;
    }
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryMouseButton) return;
    // Ignore the scrollbar gutters.
    if (e.localPosition.dx > _builtSize.width - 14 || e.localPosition.dy > _builtSize.height - 14) {
      return;
    }
    if (_onResizeHandle(e.localPosition)) return;
    final hit = _hit(e.localPosition);
    if (hit == null) return;
    final (tr, tc) = hit;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (tr > 0 && tc > 0) {
      final r = tr - 1;
      final col = tc - 1;
      if (c.editing && _isActiveArea(r, col) && c.editOrigin == EditOrigin.cell) {
        return; // clicking inside the inline editor
      }
      if (c.canPointReference) {
        c.pointReference(r, col, extend: shift);
        _mousePointing = true;
        _mouseSelecting = true;
        _dragKind = _DragKind.cells;
        return;
      }
      if (!_commitBeforeSelect()) return;
      final now = DateTime.now();
      final isDouble = _lastClickCell == (r, col) &&
          now.difference(_lastClick) < const Duration(milliseconds: 450);
      _lastClick = now;
      _lastClickCell = (r, col);
      if (isDouble && !shift) {
        c.select(r, col);
        c.beginEdit(origin: EditOrigin.cell);
        return;
      }
      c.select(r, col, extend: shift);
      _dragKind = _DragKind.cells;
    } else if (!_commitBeforeSelect()) {
      return;
    } else if (tr == 0 && tc > 0) {
      final col = tc - 1;
      if (shift) {
        c.selectColumns(math.min(c.anchorCol, col), math.max(c.anchorCol, col));
      } else {
        c.selectColumns(col, col);
      }
      _dragKind = _DragKind.columns;
    } else if (tc == 0 && tr > 0) {
      final r = tr - 1;
      if (shift) {
        c.selectRows(math.min(c.anchorRow, r), math.max(c.anchorRow, r));
      } else {
        c.selectRows(r, r);
      }
      _dragKind = _DragKind.rows;
    } else {
      c.selectAll();
      return;
    }
    _mouseSelecting = true;
    _mousePointing = false;
    if (!c.editing) widget.focusNode.requestFocus();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      _touches[e.pointer] = e.localPosition;
      final start = _pinchStartDistance;
      if (_touches.length == 2 && start != null && start > 0) {
        final pts = _touches.values.toList();
        final d = (pts[0] - pts[1]).distance;
        _pendingZoom = (_pinchStartZoom * d / start, (pts[0] + pts[1]) / 2);
        // Throttle relayouts: big sheets rebuild row metrics on every zoom.
        _zoomTimer ??= Timer(Duration(milliseconds: c.displayRows > 20000 ? 120 : 40), _flushZoom);
      }
      return;
    }
    if (!_mouseSelecting) return;
    _dragTo(e.localPosition);
  }

  (double, Offset)? _pendingZoom;
  Timer? _zoomTimer;

  void _flushZoom() {
    _zoomTimer?.cancel();
    _zoomTimer = null;
    final z = _pendingZoom;
    _pendingZoom = null;
    if (z != null && mounted) _applyZoom(z.$1, z.$2);
  }

  void _onPointerUp(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) {
      _pinchStartDistance = null;
      if (_pendingZoom != null) _flushZoom();
    }
    if (e.kind == PointerDeviceKind.mouse) {
      _mouseSelecting = false;
      _mousePointing = false;
      _stopAutoScroll();
    }
  }

  void _applyZoom(double z, Offset focal) {
    final old = c.zoom;
    final next = z.clamp(0.4, 3.0);
    if ((next - old).abs() / old < 0.03) return;
    final geo = _geo;
    double? v;
    double? h;
    if (geo != null && _v.hasClients && _h.hasClients) {
      final ratio = next / old;
      v = (_v.offset + focal.dy - geo.pinnedHeight) * ratio - (focal.dy - geo.pinnedHeight);
      h = (_h.offset + focal.dx - geo.pinnedWidth) * ratio - (focal.dx - geo.pinnedWidth);
    }
    c.setZoom(next);
    if (v != null && h != null) {
      final vv = v;
      final hh = h;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_v.hasClients || !_h.hasClients) return;
        _v.jumpTo(vv.clamp(0.0, _v.position.maxScrollExtent));
        _h.jumpTo(hh.clamp(0.0, _h.position.maxScrollExtent));
      });
    }
  }

  void _dragTo(Offset local) {
    _lastDragPos = local;
    final hit = _hit(local);
    if (hit == null) return;
    final (tr, tc) = hit;
    final r = math.max(tr - 1, 0);
    final col = math.max(tc - 1, 0);
    switch (_dragKind) {
      case _DragKind.cells:
        if (_mousePointing) {
          c.pointReference(r, col, extend: true);
        } else if (r != c.selRow || col != c.selCol) {
          c.select(r, col, extend: true, reveal: false);
        }
      case _DragKind.columns:
        final a = c.selection.c1 == col ? c.selection.c2 : c.anchorCol;
        c.selectColumns(math.min(a, col), math.max(a, col));
      case _DragKind.rows:
        final a = c.selection.r1 == r ? c.selection.r2 : c.anchorRow;
        c.selectRows(math.min(a, r), math.max(a, r));
    }
    _maybeAutoScroll(local);
  }

  void _maybeAutoScroll(Offset local) {
    const edge = 28.0;
    final geo = _geo;
    if (geo == null) return;
    final nearEdge = local.dy > _builtSize.height - edge ||
        local.dx > _builtSize.width - edge ||
        (local.dy < geo.pinnedHeight + 4 && local.dy > 0 && _v.hasClients && _v.offset > 0) ||
        (local.dx < geo.pinnedWidth + 4 && local.dx > 0 && _h.hasClients && _h.offset > 0);
    if (!nearEdge) {
      _stopAutoScroll();
      return;
    }
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 60), (_) {
      final p = _lastDragPos;
      if (!mounted || p == null || !_v.hasClients || !_h.hasClients) return;
      final step = 24 * c.zoom;
      var dy = 0.0;
      var dx = 0.0;
      if (p.dy > _builtSize.height - edge) dy = step;
      if (p.dy < geo.pinnedHeight + 4) dy = -step;
      if (p.dx > _builtSize.width - edge) dx = step;
      if (p.dx < geo.pinnedWidth + 4) dx = -step;
      if (dy != 0) _v.jumpTo((_v.offset + dy).clamp(0.0, _v.position.maxScrollExtent));
      if (dx != 0) _h.jumpTo((_h.offset + dx).clamp(0.0, _h.position.maxScrollExtent));
      _dragTo(p);
    });
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  void _onTapUp(TapUpDetails d) {
    if (d.kind == PointerDeviceKind.mouse) return; // handled on pointer down
    final hit = _hit(d.localPosition);
    if (hit == null) return;
    final (tr, tc) = hit;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (tr > 0 && tc > 0) {
      final r = tr - 1;
      final col = tc - 1;
      if (c.canPointReference && !(r == c.selRow && col == c.selCol)) {
        c.pointReference(r, col, extend: shift);
        return;
      }
      if (c.editing && _isActiveArea(r, col)) return;
      if (!_commitBeforeSelect()) return;
      final m = _mergeIndex[cellKey(r, col)];
      final ar = m?.r1 ?? r;
      final ac = m?.c1 ?? col;
      final alreadyActive = !shift && c.selection.area == (m?.area ?? 1) && c.selRow == ar && c.selCol == ac;
      if (alreadyActive) {
        if (!c.editing) c.beginEdit(origin: EditOrigin.cell);
        return;
      }
      c.select(r, col, extend: shift);
    } else if (!_commitBeforeSelect()) {
      return;
    } else if (tr == 0 && tc > 0) {
      final col = tc - 1;
      if (shift) {
        c.selectColumns(math.min(c.anchorCol, col), math.max(c.anchorCol, col));
      } else {
        c.selectColumns(col, col);
      }
    } else if (tc == 0 && tr > 0) {
      final r = tr - 1;
      if (shift) {
        c.selectRows(math.min(c.anchorRow, r), math.max(c.anchorRow, r));
      } else {
        c.selectRows(r, r);
      }
    } else {
      c.selectAll();
    }
    if (!c.editing) widget.focusNode.requestFocus();
  }

  void _onSecondaryTapUp(TapUpDetails d) {
    final hit = _hit(d.localPosition);
    if (hit != null) {
      final (tr, tc) = hit;
      if (tr > 0 && tc > 0 && !c.selection.contains(tr - 1, tc - 1)) c.select(tr - 1, tc - 1);
    }
    widget.onContextMenu(d.globalPosition);
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final hit = _hit(d.localPosition);
    _longPressMoved = false;
    _longPressStart = hit;
    if (hit == null) return;
    final (tr, tc) = hit;
    if (tr > 0 && tc > 0) {
      if (!c.selection.contains(tr - 1, tc - 1)) c.select(tr - 1, tc - 1);
      _dragKind = _DragKind.cells;
    } else if (tr == 0 && tc > 0) {
      if (!(c.selection.r1 == 0 && c.selection.r2 >= kMaxRows - 1 && c.selection.c1 <= tc - 1 && c.selection.c2 >= tc - 1)) {
        c.selectColumns(tc - 1, tc - 1);
      }
      _dragKind = _DragKind.columns;
    } else if (tc == 0 && tr > 0) {
      if (!(c.selection.c1 == 0 && c.selection.c2 >= kMaxCols - 1 && c.selection.r1 <= tr - 1 && c.selection.r2 >= tr - 1)) {
        c.selectRows(tr - 1, tr - 1);
      }
      _dragKind = _DragKind.rows;
    }
    HapticFeedback.selectionClick();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    final hit = _hit(d.localPosition);
    if (hit == null) return;
    if (hit != _longPressStart) _longPressMoved = true;
    if (_longPressMoved) {
      _mousePointing = false;
      _dragTo(d.localPosition);
    }
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    _stopAutoScroll();
    if (!_longPressMoved) widget.onContextMenu(d.globalPosition);
  }

  // ---------------------------------------------------------------------------
  // Keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final outer = widget.onKey?.call(e);
    if (outer != null && outer != KeyEventResult.ignored) return outer;
    final key = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    final shift = hw.isShiftPressed;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    final alt = hw.isAltPressed;

    if (c.editing) {
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
        if (alt) {
          final t = c.editText;
          final sel = t.selection;
          final pos = sel.isValid ? sel.start : t.text.length;
          final end = sel.isValid ? sel.end : pos;
          t.value = TextEditingValue(
            text: t.text.replaceRange(pos, end, '\n'),
            selection: TextSelection.collapsed(offset: pos + 1),
          );
          return KeyEventResult.handled;
        }
        _commit(shift ? -1 : 1, 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        _commit(0, shift ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        c.cancelEdit();
        widget.focusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    int? dr;
    int? dc;
    if (key == LogicalKeyboardKey.arrowUp) dr = -1;
    if (key == LogicalKeyboardKey.arrowDown) dr = 1;
    if (key == LogicalKeyboardKey.arrowLeft) dc = -1;
    if (key == LogicalKeyboardKey.arrowRight) dc = 1;
    if (dr != null || dc != null) {
      c.move(dr ?? 0, dc ?? 0, extend: shift, jump: ctrl);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.pageUp) {
      final rows = math.max(1, (_builtSize.height / (c.sheet.defaultRowHeight * c.zoom)).floor() - 2);
      c.move(key == LogicalKeyboardKey.pageDown ? rows : -rows, 0, extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      if (ctrl) {
        c.select(0, 0, extend: shift);
      } else {
        c.select(c.selRow, 0, extend: shift);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end && ctrl) {
      c.select(math.max(c.sheet.usedRows - 1, 0), math.max(c.sheet.usedCols - 1, 0), extend: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      c.move(shift ? -1 : 1, 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      c.move(0, shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      c.beginEdit(origin: EditOrigin.cell);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      c.clearSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      c.beginEdit(initial: '', origin: EditOrigin.cell);
      return KeyEventResult.handled;
    }
    if (ctrl) {
      if (key == LogicalKeyboardKey.keyC) {
        _run(c.copySelection());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX) {
        _run(c.copySelection(cut: true));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _run(c.paste());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyZ) {
        shift ? c.redo() : c.undo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        c.redo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        c.selectAll();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyB) {
        c.toggleBold();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyI) {
        c.toggleItalic();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyU) {
        c.toggleUnderline();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        c.fillDown();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyR) {
        c.fillRight();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add) {
        c.setZoom(c.zoom + 0.1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.minus) {
        c.setZoom(c.zoom - 0.1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.digit0) {
        c.setZoom(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final ch = e.character;
    if (!alt && ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20 && ch.codeUnitAt(0) != 0x7F) {
      c.beginEdit(initial: ch, origin: EditOrigin.cell);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _commit(int dr, int dc) {
    final err = c.commitEdit(dr: dr, dc: dc);
    if (err != null) {
      widget.onMessage?.call(err);
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void _run(Future<String?> f) {
    f.then((msg) {
      if (msg != null && mounted) widget.onMessage?.call(msg);
    });
  }

  // ---------------------------------------------------------------------------
  // Cells

  TableViewCell _buildCell(BuildContext context, TableVicinity v) {
    final tr = v.row;
    final tc = v.column;
    if (tr == 0 && tc == 0) {
      return TableViewCell(child: _Corner(controller: c));
    }
    if (tr == 0) {
      return TableViewCell(
        child: _ColumnHeader(
          controller: c,
          col: tc - 1,
          onResizeStart: _onResizeStart,
          onResizeUpdate: _onResizeUpdate,
          onResizeEnd: _onResizeEnd,
          onAutoFit: _autoFit,
        ),
      );
    }
    if (tc == 0) return TableViewCell(child: _RowHeader(controller: c, row: tr - 1));
    final r = tr - 1;
    final col = tc - 1;
    final merge = _mergeIndex[cellKey(r, col)];
    if (merge != null) {
      return TableViewCell(
        rowMergeStart: merge.r1 + 1,
        rowMergeSpan: merge.rowCount,
        columnMergeStart: merge.c1 + 1,
        columnMergeSpan: merge.colCount,
        child: _DataCell(
          controller: c,
          row: merge.r1,
          col: merge.c1,
          merge: merge,
          editorFocus: widget.editorFocusNode,
          onCommit: _commit,
        ),
      );
    }
    return TableViewCell(
      child: _DataCell(
        controller: c,
        row: r,
        col: col,
        editorFocus: widget.editorFocusNode,
        onCommit: _commit,
      ),
    );
  }

  void _onResizeStart(int col) {
    _resizeCol = col;
    _resizeStartWidth = c.sheet.colWidth(col);
    _resizeAccum = 0;
  }

  void _onResizeUpdate(int col, double dx) {
    if (_resizeCol != col) return;
    _resizeAccum += dx / c.zoom;
    c.setColumnWidth(col, _resizeStartWidth + _resizeAccum);
  }

  void _onResizeEnd(int col) {
    if (_resizeCol != col) return;
    c.setColumnWidth(col, _resizeStartWidth + _resizeAccum, from: _resizeStartWidth, record: true);
    _resizeCol = null;
  }

  void _autoFit(int col) {
    final painter = TextPainter(textDirection: TextDirection.ltr, maxLines: 1);
    c.autoFitColumn(col, (text, style) {
      painter.text = TextSpan(
        text: text.length > 200 ? text.substring(0, 200) : text,
        style: TextStyle(
          fontSize: 13 * (style.fontSize ?? 11) / 11,
          fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
        ),
      );
      painter.layout();
      return painter.width;
    });
    painter.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = GridColors.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size != _builtSize && c.editing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reveal(c.selRow, c.selCol);
        });
      }
      _rebuildIfNeeded(size);
      return Focus(
        focusNode: widget.focusNode,
        onKeyEvent: _onKey,
        child: ColoredBox(
          color: colors.paper,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _onTapUp,
              onSecondaryTapUp: _onSecondaryTapUp,
              onLongPressStart: _onLongPressStart,
              onLongPressMoveUpdate: _onLongPressMoveUpdate,
              onLongPressEnd: _onLongPressEnd,
              child: ScrollConfiguration(
                behavior: const _GridScrollBehavior(),
                child: TableView(
                  delegate: _delegate!,
                  verticalDetails: ScrollableDetails.vertical(controller: _v),
                  horizontalDetails: ScrollableDetails.horizontal(controller: _h),
                  diagonalDragBehavior: DiagonalDragBehavior.free,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

enum _DragKind { cells, columns, rows }

// -----------------------------------------------------------------------------
// Header cells

class _Corner extends StatelessWidget {
  const _Corner({required this.controller});
  final SpreadsheetController controller;

  @override
  Widget build(BuildContext context) {
    final colors = GridColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.header,
        border: Border(
          right: BorderSide(color: colors.headerLine),
          bottom: BorderSide(color: colors.headerLine),
        ),
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: CustomPaint(size: const Size(8, 8), painter: _CornerTriangle(colors.headerText.withValues(alpha: 0.35))),
        ),
      ),
    );
  }
}

class _CornerTriangle extends CustomPainter {
  _CornerTriangle(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _CornerTriangle old) => old.color != color;
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({
    required this.controller,
    required this.col,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.onAutoFit,
  });

  final SpreadsheetController controller;
  final int col;
  final void Function(int col) onResizeStart;
  final void Function(int col, double dx) onResizeUpdate;
  final void Function(int col) onResizeEnd;
  final void Function(int col) onAutoFit;

  @override
  Widget build(BuildContext context) {
    final colors = GridColors.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sel = controller.selection;
        final inSel = col >= sel.c1 && col <= sel.c2;
        final full = inSel && sel.r1 == 0 && sel.r2 >= kMaxRows - 1;
        final frozenEdge = controller.sheet.frozenCols > 0 && col == controller.sheet.frozenCols - 1;
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: full ? colors.headerSelectedStrong : (inSel ? colors.headerSelected : colors.header),
                border: Border(
                  right: BorderSide(color: frozenEdge ? colors.frozenLine : colors.headerLine, width: frozenEdge ? 2 : 1),
                  bottom: BorderSide(color: inSel ? colors.accent : colors.headerLine, width: inSel ? 2 : 1),
                ),
              ),
              child: Center(
                child: Text(
                  columnName(col),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: 11.5 * controller.zoom.clamp(0.8, 1.4),
                    color: inSel ? colors.accent : colors.headerText,
                    fontWeight: inSel ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 14,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => onResizeStart(col),
                  onHorizontalDragUpdate: (d) => onResizeUpdate(col, d.delta.dx),
                  onHorizontalDragEnd: (_) => onResizeEnd(col),
                  onHorizontalDragCancel: () => onResizeEnd(col),
                  onDoubleTap: () => onAutoFit(col),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RowHeader extends StatelessWidget {
  const _RowHeader({required this.controller, required this.row});
  final SpreadsheetController controller;
  final int row;

  @override
  Widget build(BuildContext context) {
    final colors = GridColors.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sel = controller.selection;
        final inSel = row >= sel.r1 && row <= sel.r2;
        final full = inSel && sel.c1 == 0 && sel.c2 >= kMaxCols - 1;
        final frozenEdge = controller.sheet.frozenRows > 0 && row == controller.sheet.frozenRows - 1;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: full ? colors.headerSelectedStrong : (inSel ? colors.headerSelected : colors.header),
            border: Border(
              right: BorderSide(color: inSel ? colors.accent : colors.headerLine, width: inSel ? 2 : 1),
              bottom: BorderSide(color: frozenEdge ? colors.frozenLine : colors.headerLine, width: frozenEdge ? 2 : 1),
            ),
          ),
          child: Center(
            child: Text(
              '${row + 1}',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 11 * controller.zoom.clamp(0.8, 1.4),
                color: inSel ? colors.accent : colors.headerText,
                fontWeight: inSel ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Data cells

class _DataCell extends StatelessWidget {
  const _DataCell({
    required this.controller,
    required this.row,
    required this.col,
    required this.editorFocus,
    required this.onCommit,
    this.merge,
  });

  final SpreadsheetController controller;
  final int row;
  final int col;
  final CellRange? merge;
  final FocusNode editorFocus;
  final void Function(int dr, int dc) onCommit;

  @override
  Widget build(BuildContext context) {
    final colors = GridColors.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _build(context, colors),
    );
  }

  Widget _build(BuildContext context, GridColors colors) {
    final c = controller;
    final sheet = c.sheet;
    final cell = sheet.cell(row, col);
    final style = cell?.style ?? CellStyle.plain;
    final zoom = c.zoom;
    final area = merge ?? CellRange.single(row, col);
    final sel = c.selection;
    final inSel = sel.intersects(area);
    final active = area.contains(c.selRow, c.selCol);
    final multi = !(sel == area || sel.isSingle);

    final fill = style.fillColor == null ? null : Color(style.fillColor!);
    final lastRow = area.r2;
    final lastCol = area.c2;
    final frozenR = sheet.frozenRows > 0 && lastRow == sheet.frozenRows - 1;
    final frozenC = sheet.frozenCols > 0 && lastCol == sheet.frozenCols - 1;

    final fontPx = 13 * (style.fontSize ?? 11) / 11 * zoom;
    final csvHeader = c.isCsv && c.workbook.csv?.hasHeader == true && row == 0;

    // Inline editor.
    if (c.editing && active) {
      final textStyle = TextStyle(
        fontSize: fontPx,
        color: colors.editorText,
        fontWeight: style.bold || csvHeader ? FontWeight.bold : FontWeight.normal,
        fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
        height: 1.15,
      );
      Widget editor;
      if (c.editOrigin == EditOrigin.cell) {
        editor = TextField(
          controller: c.editText,
          focusNode: editorFocus,
          autofocus: true,
          style: textStyle,
          cursorColor: colors.accent,
          cursorWidth: 1.5,
          maxLines: style.wrap ? null : 1,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration.collapsed(hintText: null),
          onSubmitted: (_) => onCommit(1, 0),
          onTapOutside: (_) {},
        );
      } else {
        editor = ValueListenableBuilder<TextEditingValue>(
          valueListenable: c.editText,
          builder: (context, value, _) => Text(
            value.text,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: textStyle,
          ),
        );
      }
      return Container(
        decoration: BoxDecoration(
          color: colors.editorBackground,
          border: Border.all(color: colors.accent, width: 2),
        ),
        padding: EdgeInsets.symmetric(horizontal: 3 * zoom.clamp(0.6, 1.5)),
        alignment: Alignment.centerLeft,
        child: editor,
      );
    }

    final fv = c.display(cell);
    var text = fv.text;
    final v = cell?.value;
    var align = style.hAlign;
    if (align == HAlign.general) {
      if (v is double) {
        align = HAlign.right;
      } else if (v is bool || v is CellError) {
        align = HAlign.center;
      } else {
        align = HAlign.left;
      }
    }
    if (align == HAlign.centerContinuous) align = HAlign.center;
    if (align == HAlign.fill && text.isNotEmpty) {
      final w = sheet.colWidth(col) * zoom;
      final n = (w / (fontPx * 0.55 * text.length)).floor().clamp(1, 200);
      text = text * n;
      align = HAlign.left;
    }
    final textColor = colors.textFor(
      explicit: fv.color ?? style.fontColor,
      fill: fill,
    );
    final ts = TextStyle(
      fontSize: fontPx,
      color: textColor,
      fontWeight: style.bold || csvHeader ? FontWeight.bold : FontWeight.normal,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine([
        if (style.underline) TextDecoration.underline,
        if (style.strike) TextDecoration.lineThrough,
      ]),
      decorationColor: textColor,
      height: 1.15,
    );
    final vAlign = switch (style.vAlign) {
      VAlign.top => -1.0,
      VAlign.center => 0.0,
      _ => merge != null ? 0.0 : 1.0,
    };
    final hAlign = switch (align) {
      HAlign.center => 0.0,
      HAlign.right => 1.0,
      _ => -1.0,
    };
    final pad = EdgeInsets.fromLTRB(3 * zoom, 1, 3 * zoom, 2 * zoom.clamp(0.5, 1.0));

    Widget content;
    if (text.isEmpty) {
      content = const SizedBox.shrink();
    } else if (style.wrap) {
      content = Padding(
        padding: pad,
        child: Align(
          alignment: Alignment(hAlign, vAlign),
          child: Text(
            text,
            style: ts,
            softWrap: true,
            overflow: TextOverflow.clip,
            textAlign: align == HAlign.center
                ? TextAlign.center
                : (align == HAlign.right ? TextAlign.right : TextAlign.left),
          ),
        ),
      );
    } else {
      // Text may spill into empty neighbours like in Excel.
      var spill = 0.0;
      if (v is String && align == HAlign.left && merge == null) {
        for (var k = 1; k <= 12; k++) {
          final n = sheet.cell(row, col + k);
          if (n != null && n.hasContent) break;
          spill += sheet.colWidth(col + k) * zoom;
        }
      }
      final line = Text(
        text,
        style: ts,
        maxLines: 1,
        softWrap: false,
        overflow: spill > 0 ? TextOverflow.visible : TextOverflow.clip,
      );
      content = Padding(
        padding: pad,
        child: spill > 0
            ? OverflowBox(
                alignment: Alignment(-1, vAlign),
                maxWidth: double.infinity,
                minWidth: 0,
                child: line,
              )
            : ClipRect(child: Align(alignment: Alignment(hAlign, vAlign), child: line)),
      );
    }

    Color? bg = fill;
    if (inSel && multi && !active) {
      bg = Color.alphaBlend(colors.selectionFill, bg ?? Colors.transparent);
    }
    final grid = BorderSide(color: colors.gridLine, width: 1);
    final decoration = BoxDecoration(
      color: bg,
      border: Border(
        right: frozenC ? BorderSide(color: colors.frozenLine, width: 2) : grid,
        bottom: frozenR ? BorderSide(color: colors.frozenLine, width: 2) : grid,
      ),
    );
    BoxDecoration? fg;
    if (active) {
      fg = BoxDecoration(border: Border.all(color: colors.accent, width: 2));
    } else if (inSel && multi) {
      final edge = BorderSide(color: colors.accent, width: 1.5);
      fg = BoxDecoration(
        border: Border(
          top: area.r1 <= sel.r1 ? edge : BorderSide.none,
          bottom: area.r2 >= sel.r2 ? edge : BorderSide.none,
          left: area.c1 <= sel.c1 ? edge : BorderSide.none,
          right: area.c2 >= sel.c2 ? edge : BorderSide.none,
        ),
      );
    }
    return Container(
      decoration: decoration,
      foregroundDecoration: fg,
      child: content,
    );
  }
}

/// Formats [v] for tests and callers that only need text.
String gridDisplayText(Object? v, String numFmt) => NumberFormats.format(v, numFmt).text;
