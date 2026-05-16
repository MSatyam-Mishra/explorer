import 'dart:io';

import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:explorer/features/viewer_text/screens/text_editor_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

class TabbedTextEditorScreen extends StatefulWidget {
  final File initialFile;

  const TabbedTextEditorScreen({super.key, required this.initialFile});

  @override
  State<TabbedTextEditorScreen> createState() => _TabbedTextEditorScreenState();
}

class _TabbedTextEditorScreenState extends State<TabbedTextEditorScreen>
    with TickerProviderStateMixin {
  late List<File> _files;
  late TabController _tabController;
  // Map to keep track of editor states to trigger saves
  final Map<String, GlobalKey<dynamic>> _editorKeys = {};

  @override
  void initState() {
    super.initState();
    _files = [widget.initialFile];
    _initializeTabController();
  }

  void _initializeTabController() {
    _tabController = TabController(length: _files.length, vsync: this);
    // Listener to update state when tab changes (if needed for UI updates)
    _tabController.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  GlobalKey<dynamic> _getKeyForFile(File file) {
    final path = file.path;
    if (!_editorKeys.containsKey(path)) {
      _editorKeys[path] = GlobalKey();
    }
    return _editorKeys[path]!;
  }

  Future<void> _addFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.any, // Logic could be more specific
    );

    if (result != null && result.files.single.path != null) {
      File newFile = File(result.files.single.path!);

      // Check if already open
      if (_files.any((f) => f.path == newFile.path)) {
        // Switch to that tab
        int index = _files.indexWhere((f) => f.path == newFile.path);
        _tabController.animateTo(index);
        return;
      }

      setState(() {
        _files.add(newFile);
        // Re-init controller because length changed
        _tabController.dispose();
        _initializeTabController();
        // Move to new tab
        _tabController.animateTo(_files.length - 1);
      });
    }
  }

  void _closeTab(int index) {
    if (_files.length <= 1) {
      Navigator.pop(context); // Close screen if last tab
      return;
    }

    setState(() {
      File file = _files[index];
      _editorKeys.remove(file.path);
      _files.removeAt(index);

      // Re-init
      _tabController.dispose();
      _initializeTabController();
      // Safe index clamp
      if (index >= _files.length) {
        _tabController.animateTo(_files.length - 1);
      } else {
        _tabController.animateTo(index);
      }
    });
  }

  void _saveCurrentFile() {
    final int index = _tabController.index;
    final File currentFile = _files[index];
    final key = _getKeyForFile(currentFile);

    // Call save on the SingleFileEditor state
    // We cast to dynamic because the state class is private in the other file,
    // but we can assume the method exists if we stick to the contract.
    // Better practice: Make State public?? or use mixin.
    // For now: dynamic dispatch via key.currentState
    final state = key.currentState;
    if (state != null) {
      if (state.toString().contains('_SingleFileEditorState')) {
        // This relies on the method 'save' being exposed.
        // Since _SingleFileEditorState is private, we can't cast to it.
        // We should have made SingleFileEditorState public or used an interface.
        // Quick fix: define a GlobalKey<State<SingleFileEditor>> and use dynamic.
        (state as dynamic).save();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);

    return ExplorerScaffold(
      title: 'Text Editor',
      trailing: ExplorerTopBar.actions(
        context,
        [
          ExplorerTopBar.iconButton(
            context: context,
            icon: AppIcons.huge(
              HugeIcons.strokeRoundedAdd01,
              color: iconColor,
            ),
            tooltip: 'Open another file',
            onPressed: _addFile,
          ),
          ExplorerTopBar.iconButton(
            context: context,
            icon: AppIcons.huge(
              HugeIcons.strokeRoundedFloppyDisk,
              color: iconColor,
            ),
            tooltip: 'Save current file',
            onPressed: _saveCurrentFile,
          ),
        ],
      ),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: _files.map((file) {
              return Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(p.basename(file.path)),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        final idx = _files.indexOf(file);
                        _closeTab(idx);
                      },
                      child: const Icon(Icons.close, size: 16),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: _files.map((file) {
                return SingleFileEditor(
                  key: _getKeyForFile(file),
                  textFile: file,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
