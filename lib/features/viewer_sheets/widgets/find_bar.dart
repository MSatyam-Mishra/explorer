import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/spreadsheet_controller.dart';

/// Docked find & replace panel.
class FindReplaceBar extends StatefulWidget {
  const FindReplaceBar({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onMessage,
    this.replaceMode = false,
  });

  final SpreadsheetController controller;
  final VoidCallback onClose;
  final void Function(String message) onMessage;
  final bool replaceMode;

  @override
  State<FindReplaceBar> createState() => _FindReplaceBarState();
}

class _FindReplaceBarState extends State<FindReplaceBar> {
  final _find = TextEditingController();
  final _replace = TextEditingController();
  final _findFocus = FocusNode();
  late bool _replaceMode = widget.replaceMode;
  bool _matchCase = false;
  bool _wholeCell = false;
  bool _allSheets = false;
  List<FindMatch> _matches = const [];
  int _index = -1;
  Timer? _debounce;
  int _searchedVersion = -1;

  FindOptions get _opts =>
      FindOptions(matchCase: _matchCase, wholeCell: _wholeCell, allSheets: _allSheets);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant FindReplaceBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.replaceMode != oldWidget.replaceMode && widget.replaceMode) {
      setState(() => _replaceMode = true);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _find.dispose();
    _replace.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  void _search({bool keepIndex = false}) {
    final m = widget.controller.findAll(_find.text, _opts);
    setState(() {
      _matches = m;
      _searchedVersion = widget.controller.contentVersion;
      if (!keepIndex || _index >= m.length) _index = m.isEmpty ? -1 : 0;
    });
    if (!keepIndex && _matches.isNotEmpty) widget.controller.goToMatch(_matches[0]);
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _search);
  }

  void _step(int delta) {
    if (_searchedVersion != widget.controller.contentVersion) _search(keepIndex: true);
    if (_matches.isEmpty) return;
    setState(() => _index = (_index + delta) % _matches.length);
    if (_index < 0) _index += _matches.length;
    widget.controller.goToMatch(_matches[_index]);
  }

  void _replaceCurrent() {
    if (_matches.isEmpty || _index < 0) return;
    final ok = widget.controller.replaceOne(_matches[_index], _find.text, _replace.text, _opts);
    if (!ok) widget.onMessage('Nothing to replace in this cell.');
    _search(keepIndex: true);
    if (_matches.isNotEmpty) widget.controller.goToMatch(_matches[_index.clamp(0, _matches.length - 1)]);
  }

  void _replaceAll() {
    if (_find.text.isEmpty) return;
    final n = widget.controller.replaceAll(_find.text, _replace.text, _opts);
    widget.onMessage(n == 0 ? 'No matches replaced.' : 'Replaced $n ${n == 1 ? 'cell' : 'cells'}.');
    _search(keepIndex: true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _step(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _find.text.isEmpty
        ? ''
        : (_matches.isEmpty ? 'No results' : '${_index + 1} of ${_matches.length}');
    Widget field(TextEditingController ctrl, String hint, {FocusNode? focus, ValueChanged<String>? onChanged}) {
      return TextField(
        controller: ctrl,
        focusNode: focus,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        ),
      );
    }

    return Focus(
      onKeyEvent: _onKey,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.95),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: _replaceMode ? 'Hide replace' : 'Show replace',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(_replaceMode ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                    onPressed: () => setState(() => _replaceMode = !_replaceMode),
                  ),
                  Expanded(child: field(_find, 'Find', focus: _findFocus, onChanged: _onQueryChanged)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(status, style: theme.textTheme.bodySmall),
                  ),
                  IconButton(
                    tooltip: 'Previous',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    onPressed: _matches.isEmpty ? null : () => _step(-1),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    onPressed: _matches.isEmpty ? null : () => _step(1),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Options',
                    icon: const Icon(Icons.tune_rounded),
                    onSelected: (v) {
                      setState(() {
                        if (v == 'case') _matchCase = !_matchCase;
                        if (v == 'whole') _wholeCell = !_wholeCell;
                        if (v == 'all') _allSheets = !_allSheets;
                      });
                      _search();
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: 'case', checked: _matchCase, child: const Text('Match case')),
                      CheckedPopupMenuItem(value: 'whole', checked: _wholeCell, child: const Text('Entire cell')),
                      CheckedPopupMenuItem(value: 'all', checked: _allSheets, child: const Text('All sheets')),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              if (_replaceMode)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 40, right: 4),
                  child: Row(
                    children: [
                      Expanded(child: field(_replace, 'Replace with')),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: _matches.isEmpty ? null : _replaceCurrent,
                        child: const Text('Replace'),
                      ),
                      TextButton(
                        onPressed: _find.text.isEmpty ? null : _replaceAll,
                        child: const Text('All'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
