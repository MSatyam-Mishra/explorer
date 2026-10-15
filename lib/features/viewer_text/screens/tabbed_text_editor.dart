import 'dart:io';

import 'package:explorer/features/viewer_text/screens/text_editor_screen.dart';
import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:path/path.dart' as p;

/// Multi-tab text/code editor. Each tab keeps its state while hidden.
class TabbedTextEditorScreen extends StatefulWidget {
  final File initialFile;

  const TabbedTextEditorScreen({super.key, required this.initialFile});

  @override
  State<TabbedTextEditorScreen> createState() => _TabbedTextEditorScreenState();
}

class _EditorTab {
  _EditorTab(this.file);

  final File file;
  final GlobalKey<TextEditorPaneState> key = GlobalKey();
  bool dirty = false;
}

class _TabbedTextEditorScreenState extends State<TabbedTextEditorScreen> {
  late final List<_EditorTab> _tabs = [_EditorTab(widget.initialFile)];
  int _index = 0;

  _EditorTab get _current => _tabs[_index];
  bool get _anyDirty => _tabs.any((t) => t.dirty);

  Future<void> _addFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final existing = _tabs.indexWhere((t) => t.file.path == path);
    setState(() {
      if (existing >= 0) {
        _index = existing;
      } else {
        _tabs.add(_EditorTab(File(path)));
        _index = _tabs.length - 1;
      }
    });
  }

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    if (tab.dirty) {
      final choice = await _confirmDiscard(p.basename(tab.file.path));
      if (choice == null) return;
      if (choice && !(await tab.key.currentState?.save() ?? false)) return;
    }
    if (!mounted) return;
    if (_tabs.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _tabs.removeAt(index);
      if (_index >= _tabs.length) _index = _tabs.length - 1;
      if (index < _index) _index--;
    });
  }

  /// null = cancel, true = save first, false = discard.
  Future<bool?> _confirmDiscard(String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text('Save changes to $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCurrent() async {
    final ok = await _current.key.currentState?.save() ?? false;
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${p.basename(_current.file.path)}')),
      );
    }
  }

  Future<void> _handlePop() async {
    for (final tab in _tabs.where((t) => t.dirty).toList()) {
      final choice = await _confirmDiscard(p.basename(tab.file.path));
      if (choice == null) return;
      if (choice && !(await tab.key.currentState?.save() ?? false)) return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_anyDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handlePop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveCurrent,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _saveCurrent,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              _current.key.currentState?.toggleFind(),
          const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
              _current.key.currentState?.toggleFind(replace: true),
        },
        child: ExplorerScaffold(
          title: p.basename(_current.file.path),
          trailing: ExplorerTopBar.actions(context, [
            ExplorerTopBar.iconButton(
              context: context,
              icon: AppIcons.huge(HugeIcons.strokeRoundedAdd01, color: iconColor),
              tooltip: 'Open another file',
              onPressed: _addFile,
            ),
            ExplorerTopBar.iconButton(
              context: context,
              icon: AppIcons.huge(
                HugeIcons.strokeRoundedFloppyDisk,
                color: _current.dirty ? scheme.primary : iconColor,
              ),
              tooltip: 'Save',
              onPressed: _current.dirty ? _saveCurrent : null,
            ),
          ]),
          body: Padding(
            padding: EdgeInsets.only(
              top: DockedGlossyTopBar.contentTopInset(context),
            ),
            child: Column(
              children: [
                if (_tabs.length > 1) _buildTabStrip(scheme),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      for (final tab in _tabs)
                        TextEditorPane(
                          key: tab.key,
                          file: tab.file,
                          onDirtyChanged: (dirty) {
                            if (tab.dirty != dirty) {
                              setState(() => tab.dirty = dirty);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabStrip(ColorScheme scheme) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final tab = _tabs[i];
          final selected = i == _index;
          return InputChip(
            selected: selected,
            showCheckmark: false,
            label: Text(
              '${tab.dirty ? '● ' : ''}${p.basename(tab.file.path)}',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => setState(() => _index = i),
            onDeleted: () => _closeTab(i),
            deleteButtonTooltipMessage: 'Close',
            visualDensity: VisualDensity.compact,
          );
        },
      ),
    );
  }
}
