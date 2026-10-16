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
  _EditorTab(this.file, {this.isCopy = false});

  final File file;

  /// [file] is the file picker's temporary copy, not the user's file, so
  /// saving goes through "Save a copy" instead of overwriting it.
  final bool isCopy;
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
    final picked = result?.files.single;
    final path = picked?.path;
    if (picked == null || path == null || !mounted) return;
    var file = File(path);
    var isCopy = false;
    // On Android and iOS the picker hands back a copy in the app's cache;
    // edits saved there would never reach the real file.
    if (Platform.isAndroid || Platform.isIOS) {
      final real = await _realPathFor(picked);
      if (real != null) {
        file = File(real);
      } else {
        isCopy = true;
      }
    }
    if (!mounted) return;
    final existing = _tabs.indexWhere((t) => p.equals(t.file.path, file.path));
    setState(() {
      if (existing >= 0) {
        _index = existing;
      } else {
        _tabs.add(_EditorTab(file, isCopy: isCopy));
        _index = _tabs.length - 1;
      }
    });
  }

  /// Maps an Android document URI back to the file it names when the
  /// provider exposes one (internal/SD storage, "raw:" downloads) and the app
  /// can read it. Returns null otherwise (other providers, iOS).
  static Future<String?> _realPathFor(PlatformFile picked) async {
    if (!Platform.isAndroid) return null;
    final uri = Uri.tryParse(picked.identifier ?? '');
    if (uri == null || uri.scheme != 'content') return null;
    final segments = uri.pathSegments; // decoded: "primary:Documents/a.txt"
    final docIndex = segments.lastIndexOf('document');
    if (docIndex < 0 || docIndex + 1 >= segments.length) return null;
    final docId = segments[docIndex + 1];
    String? candidate;
    switch (uri.authority) {
      case 'com.android.externalstorage.documents':
        final colon = docId.indexOf(':');
        if (colon <= 0) return null;
        final volume = docId.substring(0, colon);
        final relative = docId.substring(colon + 1);
        final root = volume.toLowerCase() == 'primary'
            ? '/storage/emulated/0'
            : '/storage/$volume';
        candidate = relative.isEmpty ? null : '$root/$relative';
      case 'com.android.providers.downloads.documents':
        if (docId.startsWith('raw:')) candidate = docId.substring(4);
    }
    if (candidate == null) return null;
    try {
      // Same size as the copy we were given, so it's the same file.
      if (await File(candidate).length() != picked.size) return null;
    } catch (_) {
      return null;
    }
    return candidate;
  }

  /// Saves or discards [tab]'s edits after asking. Returns false if the
  /// user cancelled or the save failed.
  Future<bool> _resolveUnsaved(_EditorTab tab) async {
    // Loop: keystrokes typed while a save is running leave the tab dirty.
    while (tab.dirty) {
      final choice = await _confirmDiscard(p.basename(tab.file.path));
      if (choice == null) return false;
      if (!choice) return true;
      if (!(await tab.key.currentState?.save() ?? false)) return false;
      if (!mounted) return false;
    }
    return true;
  }

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    if (!await _resolveUnsaved(tab)) return;
    if (!mounted) return;
    if (_tabs.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      final position = _tabs.indexOf(tab);
      if (position < 0) return;
      _tabs.removeAt(position);
      if (position < _index) _index--;
      if (_index >= _tabs.length) _index = _tabs.length - 1;
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
    final tab = _current;
    final ok = await tab.key.currentState?.save() ?? false;
    if (ok && mounted) {
      final name = p.basename(tab.file.path);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tab.isCopy ? 'Saved a copy of $name' : 'Saved $name')),
      );
    }
  }

  Future<void> _handlePop() async {
    for (final tab in _tabs.where((t) => t.dirty).toList()) {
      if (!await _resolveUnsaved(tab)) return;
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
                          saveAsCopy: tab.isCopy,
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
