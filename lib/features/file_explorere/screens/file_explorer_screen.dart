import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/archive_service.dart';
import 'package:explorer/core/services/file_action_service.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_header.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_menu.dart';
import 'package:explorer/features/file_explorere/widgets/file_grid_item.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:explorer/features/file_explorere/widgets/paste_bar.dart';
import 'package:explorer/features/localsend/screens/localsend_screen.dart';
import 'package:explorer/features/network/screens/file_server_screen.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';
import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_options_sheet.dart';
import 'package:explorer/shared/widgets/main_drawer.dart';
import 'package:explorer/shared/widgets/progress_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

FileActionsService fileActionsService = FileActionsService();

/// Mouse clicks in the file list (one explorer per window): the kind of the
/// last pointer, and what was clicked last, for double-clicks and Shift
/// ranges.
final _clicks = _Clicks();

class _Clicks {
  PointerDeviceKind kind = PointerDeviceKind.touch;
  String? lastPath;
  DateTime lastTime = DateTime(0);
  String? anchorPath;

  /// A mouse clicks like on a desktop (click selects, double-click opens);
  /// touch taps like on a phone (tap opens).
  bool get mouse => kind == PointerDeviceKind.mouse;
}

/// Ctrl, or Cmd on macOS.
bool get _commandPressed => Platform.isMacOS
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({super.key});

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen>
    with WidgetsBindingObserver {
  // Created once: building the FutureBuilder with a fresh future on every
  // rebuild re-ran the permission check each time.
  late Future<PermissionStatus> _permission = _checkAndRequestPermission();
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from system settings: pick up a newly granted permission.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Computers need no storage permission (and permission_handler has no
    // Linux version).
    if (ExplorerPaths.isDesktop) return;
    if (state == AppLifecycleState.resumed && !_granted) {
      setState(() => _permission = Permission.manageExternalStorage.status);
    }
  }

  @override
  Widget build(BuildContext context) {
    // We use a FutureBuilder to handle the initial permission check.
    return FutureBuilder<PermissionStatus>(
      future: _permission,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(
            backgroundColor: context.colors.background,
            body: const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final status = snapshot.data!;
        _granted = status.isGranted;
        // Handle both standard usage and "manage external storage" scenarios
        if (status.isGranted) {
          return const _FileExplorerWithProviders();
        } else {
          return _PermissionDeniedScreen(
            onRequest: () => setState(
              () => _permission = Permission.manageExternalStorage.request(),
            ),
          );
        }
      },
    );
  }

  Future<PermissionStatus> _checkAndRequestPermission() async {
    if (ExplorerPaths.isDesktop) {
      return PermissionStatus.granted;
    }

    var status = await Permission.manageExternalStorage.status;

    // If not granted, request it immediately
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }

    return status;
  }
}

// This widget holds all our BLoCs at the very top.
class _FileExplorerWithProviders extends StatelessWidget {
  const _FileExplorerWithProviders();

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) =>
              FileExplorerBloc(repository: LocalFileRepository())
                ..add(LoadDirectory(ExplorerPaths.initialPath)),
        ),
        BlocProvider(
          create: (context) => SidebarBloc()..add(LoadSidebarData()),
        ),
        BlocProvider(create: (context) => TaskProgressBloc()),
        BlocProvider(
          create: (context) =>
              ClipboardBloc(taskProgressBloc: context.read<TaskProgressBloc>()),
        ),
      ],
      child: _FileExplorerUI(),
    );
  }
}

/// The folder a state is about, if any.
String? _pathOf(FileExplorerState state) => switch (state) {
  FileExplorerLoaded(:final path) => path,
  FileExplorerLoading(:final path) => path,
  FileExplorerError(:final path) => path,
  _ => null,
};

// This is the actual UI, which is now guaranteed to be under all the providers.
class _FileExplorerUI extends StatelessWidget {
  const _FileExplorerUI();

  /// Sidebar width when it's docked next to the files (tablets, desktops).
  static const double _sidebarWidth = 280;

  @override
  Widget build(BuildContext context) {
    // We listen to multiple BLoCs to build the final UI
    final fileExplorerState = context.watch<FileExplorerBloc>().state;
    final clipboardState = context.watch<ClipboardBloc>().state;
    final taskState = context.watch<TaskProgressBloc>().state;

    final path = _pathOf(fileExplorerState);
    final loaded = fileExplorerState is FileExplorerLoaded
        ? fileExplorerState
        : null;
    final bool isSelectionMode = loaded?.isSelectionMode ?? false;
    final String? parentPath = path == null
        ? null
        : ExplorerPaths.parentOf(path);
    final bool canPop = !isSelectionMode && parentPath == null;

    // Tablets, unfolded foldables and desktops keep navigation docked.
    final bool docked = AdaptiveSplitView.isSplit(context);
    final bool busy = taskState is TaskInProgress;
    final pasteState = clipboardState is ClipboardReadyToPaste && !busy
        ? clipboardState
        : null;
    final bool canCreate =
        loaded != null && !ExplorerPaths.isWindowsRoots(loaded.path);
    final bool showFab =
        !docked &&
        canCreate &&
        loaded.entities.isNotEmpty &&
        !isSelectionMode &&
        pasteState == null &&
        !busy;

    final bottomInset =
        (pasteState != null ? PasteBar.reservedHeight : 0.0) +
        (showFab ? 72.0 : 0) +
        (busy ? 120.0 : 0);

    final body = Stack(
      children: [
        Positioned.fill(
          child: _buildFileList(
            context,
            fileExplorerState,
            bottomInset: bottomInset,
            canCreate: canCreate,
          ),
        ),
        if (pasteState != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
            child: Center(
              child: PasteBar(
                clipboard: pasteState,
                onCancel: () =>
                    context.read<ClipboardBloc>().add(ClearClipboard()),
                onPaste: loaded == null || ExplorerPaths.isWindowsRoots(path!)
                    ? null
                    : () => context.read<ClipboardBloc>().add(
                        PasteFromClipboard(loaded.path),
                      ),
              ),
            ),
          ),
        if (taskState is TaskInProgress)
          ProgressCard(
            title: taskState.title,
            message: taskState.message,
            progress: taskState.progress,
          ),
      ],
    );

    final page = DockedTopBarScaffold(
      drawer: docked ? null : const MainDrawer(),
      topBarBuilder: (scaffoldContext) => _buildDockedTopBar(
        scaffoldContext,
        fileExplorerState: fileExplorerState,
        isSelectionMode: isSelectionMode,
        docked: docked,
        canCreate: canCreate,
      ),
      // Show pasted items, and say why a paste failed.
      body: BlocListener<ClipboardBloc, ClipboardState>(
        listener: (context, state) {
          final current = context.read<FileExplorerBloc>().state;
          if (state is ClipboardPasteSuccess && current is FileExplorerLoaded) {
            context.read<FileExplorerBloc>().add(LoadDirectory(current.path));
          } else if (state is ClipboardPasteFailure) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Couldn't paste: ${state.error}")),
            );
          }
        },
        child: body,
      ),
      floatingActionButton: showFab
          ? FloatingActionButton(
              tooltip: 'New folder',
              onPressed: () => fileActionsService.showCreateFolderDialog(
                context,
                loaded.path,
              ),
              child: const Icon(LucideIcons.folderPlus),
            )
          : null,
    );

    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (isSelectionMode) {
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
          return;
        }
        if (parentPath != null) {
          context.read<FileExplorerBloc>().add(LoadDirectory(parentPath));
        }
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) => _onKey(context, event),
        child: docked
            ? ColoredBox(
                color: context.colors.background,
                child: AdaptiveSplitView(
                  secondaryWidth: _sidebarWidth,
                  primary: page,
                  secondary: const DockedSidebar(child: MainDrawerContent()),
                ),
              )
            : page,
      ),
    );
  }

  /// Keyboard shortcuts of desktop file managers.
  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Typing in a text field: the keys are the field's.
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }
    final bloc = context.read<FileExplorerBloc>();
    final state = bloc.state;
    if (state is! FileExplorerLoaded) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final command = _commandPressed;
    final selected = state.selectedItems.toList();
    final single = selected.length == 1 ? selected.single : null;
    final inFolder = !ExplorerPaths.isWindowsRoots(state.path);
    final clipboard = context.read<ClipboardBloc>();

    if (command && key == LogicalKeyboardKey.keyA) {
      bloc.add(SelectAll());
    } else if (command && key == LogicalKeyboardKey.keyC && selected.isNotEmpty) {
      clipboard.add(CopyToClipboard(selected.first));
    } else if (command && key == LogicalKeyboardKey.keyX && selected.isNotEmpty) {
      clipboard.add(CutToClipboard(selected.first));
    } else if (command && key == LogicalKeyboardKey.keyV) {
      if (clipboard.state is ClipboardReadyToPaste && inFolder) {
        clipboard.add(PasteFromClipboard(state.path));
      }
    } else if (command && keys.isShiftPressed && key == LogicalKeyboardKey.keyN) {
      if (inFolder) {
        fileActionsService.showCreateFolderDialog(context, state.path);
      }
    } else if (command && key == LogicalKeyboardKey.keyN && Desktop.isDesktop) {
      Desktop.openWindow(folder: state.path);
    } else if (key == LogicalKeyboardKey.f5 ||
        (command && key == LogicalKeyboardKey.keyR)) {
      bloc.add(LoadDirectory(state.path));
    } else if (key == LogicalKeyboardKey.enter && single != null) {
      if (keys.isAltPressed) {
        fileActionsService.showInfoSheet(single, context);
      } else {
        _open(context, state, single);
      }
    } else if (command && key == LogicalKeyboardKey.keyI && single != null) {
      fileActionsService.showInfoSheet(single, context);
    } else if (key == LogicalKeyboardKey.delete && selected.isNotEmpty) {
      fileActionsService.deleteFiles(context, selected);
    } else if (key == LogicalKeyboardKey.f2 && single != null) {
      fileActionsService.showRenameDialog(context, single);
    } else if (key == LogicalKeyboardKey.escape && selected.isNotEmpty) {
      bloc.add(ToggleSelectionMode(enable: false));
    } else if (key == LogicalKeyboardKey.backspace ||
        (keys.isAltPressed && key == LogicalKeyboardKey.arrowLeft) ||
        (command && key == LogicalKeyboardKey.arrowUp)) {
      final parent = ExplorerPaths.parentOf(state.path);
      if (parent == null) return KeyEventResult.ignored;
      bloc.add(LoadDirectory(parent));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _buildDockedTopBar(
    BuildContext context, {
    required FileExplorerState fileExplorerState,
    required bool isSelectionMode,
    required bool docked,
    required bool canCreate,
  }) {
    final bloc = context.read<FileExplorerBloc>();

    if (isSelectionMode && fileExplorerState is FileExplorerLoaded) {
      final selected = fileExplorerState.selectedItems.toList();
      void exitSelection() => bloc.add(ToggleSelectionMode(enable: false));
      return ExplorerSelectionHeader(
        count: selected.length,
        total: fileExplorerState.entities.length,
        wide: docked,
        onClose: exitSelection,
        onShare: () => fileActionsService.shareMany(context, selected),
        onSendNearby: () {
          exitSelection();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LocalSendScreen(initialItems: selected),
            ),
          );
        },
        onCompress: () => _handleCompress(context, fileExplorerState),
        onDelete: () => fileActionsService.deleteFiles(context, selected),
        onMenuAction: (action) {
          switch (action) {
            case SelectionMenuAction.selectAll:
              bloc.add(SelectAll());
            case SelectionMenuAction.clear:
              bloc.add(ClearSelection());
            case SelectionMenuAction.copy:
              exitSelection();
              context.read<ClipboardBloc>().add(
                CopyToClipboard(selected.first),
              );
            case SelectionMenuAction.cut:
              exitSelection();
              context.read<ClipboardBloc>().add(CutToClipboard(selected.first));
            case SelectionMenuAction.rename:
              exitSelection();
              fileActionsService.showRenameDialog(context, selected.first);
            case SelectionMenuAction.properties:
              exitSelection();
              fileActionsService.showInfoSheet(selected.first, context);
            case SelectionMenuAction.allActions:
              exitSelection();
              fileActionsService.showFileOptionsMenu(context, selected.first);
          }
        },
      );
    }

    final path = _pathOf(fileExplorerState);
    final loaded = fileExplorerState is FileExplorerLoaded
        ? fileExplorerState
        : null;
    return ExplorerHeader(
      crumbs: path == null
          ? const []
          : explorerCrumbs(path, labels: loaded?.pathLabels ?? const {}),
      wide: docked,
      onNavigate: (target) => bloc.add(LoadDirectory(target)),
      onMenuPressed: docked ? null : () => Scaffold.of(context).openDrawer(),
      viewMode: loaded?.viewMode,
      sortOption: loaded?.sortOption,
      sortOrder: loaded?.sortOrder,
      onViewModeChanged: loaded == null
          ? null
          : (mode) => bloc.add(ChangeViewMode(mode)),
      onSortChanged: loaded == null
          ? null
          : (option, order) => bloc.add(ChangeSortOrder(option, order)),
      onNewFolder: canCreate && loaded != null
          ? () =>
                fileActionsService.showCreateFolderDialog(context, loaded.path)
          : null,
      onOptionsPressed: loaded == null
          ? null
          : () {
              ExplorerOptionsSheet.show(
                context,
                fileState: loaded,
                onHttpShare: () => _handleHttpShare(context, loaded),
                onSortChanged: (SortOption option, SortOrder order) {
                  bloc.add(ChangeSortOrder(option, order));
                },
                onViewModeChanged: (ViewMode mode) {
                  bloc.add(ChangeViewMode(mode));
                },
                onShowHiddenChanged: () => bloc.add(LoadDirectory(loaded.path)),
              );
            },
    );
  }

  Widget _buildFileList(
    BuildContext context,
    FileExplorerState state, {
    required double bottomInset,
    required bool canCreate,
  }) {
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    final bottom = MediaQuery.paddingOf(context).bottom + 16 + bottomInset;
    final statePadding = EdgeInsets.fromLTRB(24, topInset + 24, 24, bottom);

    if (state is FileExplorerLoading || state is FileExplorerInitial) {
      return _DelayedReveal(child: _ListSkeleton(top: topInset + 8));
    }
    if (state is FileExplorerError) {
      final parent = state.path == null
          ? null
          : ExplorerPaths.parentOf(state.path!);
      final bloc = context.read<FileExplorerBloc>();
      return ExplorerEmptyState(
        padding: statePadding,
        destructive: true,
        icon: LucideIcons.folderX,
        title: "Can't open this folder",
        description: _friendlyError(state.message),
        actions: [
          if (parent != null)
            OutlinedButton.icon(
              onPressed: () => bloc.add(LoadDirectory(parent)),
              icon: const Icon(LucideIcons.arrowLeft, size: 16),
              label: const Text('Go back'),
            ),
          FilledButton.icon(
            onPressed: () => bloc.add(
              LoadDirectory(state.path ?? ExplorerPaths.initialPath),
            ),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('Try again'),
          ),
        ],
      );
    }
    if (state is FileExplorerLoaded) {
      if (state.entities.isEmpty) {
        return ExplorerEmptyState(
          padding: statePadding,
          icon: LucideIcons.folderOpen,
          title: 'This folder is empty',
          description: canCreate
              ? 'Create a folder, or copy files here from another folder.'
              : 'There is nothing to show here.',
          actions: [
            if (canCreate)
              OutlinedButton.icon(
                onPressed: () => fileActionsService.showCreateFolderDialog(
                  context,
                  state.path,
                ),
                icon: const Icon(LucideIcons.folderPlus, size: 16),
                label: const Text('New folder'),
              ),
          ],
        );
      }

      return LayoutBuilder(
        builder: (context, constraints) => _buildEntries(
          context,
          state,
          width: constraints.maxWidth,
          top: topInset,
          bottom: bottom,
        ),
      );
    }
    return ExplorerEmptyState(
      padding: statePadding,
      icon: LucideIcons.circleAlert,
      title: 'Something went wrong',
    );
  }

  Widget _buildEntries(
    BuildContext context,
    FileExplorerLoaded state, {
    required double width,
    required double top,
    required double bottom,
  }) {
    final wide = width >= 720;
    final entities = state.entities;
    final bloc = context.read<FileExplorerBloc>();

    void onTap(FileSystemEntity e) => _clicks.mouse
        ? _handleClick(context, state, e)
        : _handleTap(context, state, e);
    void onLongPress(FileSystemEntity e) => _handleLongPress(context, state, e);
    GestureTapUpCallback? onSecondaryTap(FileSystemEntity e) {
      if (Desktop.isDesktop) {
        return (details) =>
            _showItemMenu(context, state, e, details.globalPosition);
      }
      return state.isSelectionMode
          ? null
          : (_) => fileActionsService.showFileOptionsMenu(context, e);
    }

    final footer = SliverToBoxAdapter(
      child: _FolderSummary(entities: entities),
    );

    final List<Widget> slivers;
    if (state.viewMode == ViewMode.grid || state.viewMode == ViewMode.gallery) {
      final gallery = state.viewMode == ViewMode.gallery;
      final pad = wide ? 24.0 : 16.0;
      final spacing = wide ? 12.0 : 10.0;
      slivers = [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, top + pad - 4, pad, 0),
          sliver: SliverGrid(
            // Column count follows the window width (phones ≈3, tablets 6+).
            gridDelegate: gallery
                ? SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: wide ? 200 : 180,
                    childAspectRatio: 0.84,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                  )
                : SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: wide ? 144 : 128,
                    childAspectRatio: 0.84,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                  ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final entity = entities[index];
              return FileGridItem(
                entity: entity,
                displayName: state.labelFor(entity),
                gallery: gallery,
                isSelectionMode: state.isSelectionMode,
                isSelected: state.selectedItems.contains(entity),
                onTap: () => onTap(entity),
                onLongPress: () => onLongPress(entity),
                onSecondaryTapUp: onSecondaryTap(entity),
              );
            }, childCount: entities.length),
          ),
        ),
        footer,
      ];
    } else {
      final style = state.viewMode == ViewMode.compact
          ? FileRowStyle.compact
          : wide
          ? FileRowStyle.table
          : FileRowStyle.comfortable;
      final sidePad = wide ? 8.0 : 0.0;
      slivers = [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(sidePad, top + 8, sidePad, 0),
          sliver: SliverList.list(
            children: [
              if (style == FileRowStyle.table)
                FileTableHeader(
                  sortOption: state.sortOption,
                  sortOrder: state.sortOrder,
                  showSelectionColumn: state.isSelectionMode,
                  onSort: (option, order) =>
                      bloc.add(ChangeSortOrder(option, order)),
                ),
            ],
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: sidePad),
          sliver: SliverFixedExtentList(
            itemExtent: FileListItem.heightFor(style) + 2,
            delegate: SliverChildBuilderDelegate((context, index) {
              final entity = entities[index];
              return FileListItem(
                entity: entity,
                displayName: state.labelFor(entity),
                style: style,
                isSelectionMode: state.isSelectionMode,
                isSelected: state.selectedItems.contains(entity),
                onTap: () => onTap(entity),
                onLongPress: () => onLongPress(entity),
                onSecondaryTapUp: onSecondaryTap(entity),
              );
            }, childCount: entities.length),
          ),
        ),
        footer,
      ];
    }

    final list = Scrollbar(
      child: CustomScrollView(
        // Remembers each folder's scroll position when coming back up.
        key: PageStorageKey<String>('explorer:${state.path}'),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          ...slivers,
          SliverToBoxAdapter(child: SizedBox(height: bottom)),
        ],
      ),
    );
    return Listener(
      // Before the item's tap fires: was it a mouse or a finger?
      onPointerDown: (event) => _clicks.kind = event.kind,
      child: GestureDetector(
        // Only where no item took the click: the space around them.
        onTap: () {
          if (_clicks.mouse && state.selectedItems.isNotEmpty) {
            bloc.add(ToggleSelectionMode(enable: false));
          }
        },
        onSecondaryTapUp: Desktop.isDesktop
            ? (details) =>
                _showFolderMenu(context, state, details.globalPosition)
            : null,
        child: list,
      ),
    );
  }

  /// Opens a folder or file, as a tap does.
  Future<void> _open(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) async {
    final bloc = context.read<FileExplorerBloc>();
    if (entity is Directory) {
      bloc.add(LoadDirectory(entity.path));
      return;
    }
    if (state.selectedItems.isNotEmpty) {
      bloc.add(ToggleSelectionMode(enable: false));
    }
    final result = await FileOpener.open(context, entity as File);
    // Only re-list when the viewer changed the folder (saved a copy...).
    if (result == true && !bloc.isClosed) {
      bloc.add(LoadDirectory(state.path));
    }
  }

  /// A mouse click, as desktop file managers handle it: click selects,
  /// double-click opens, Ctrl (Cmd) adds or removes, Shift selects a range.
  void _handleClick(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) {
    final bloc = context.read<FileExplorerBloc>();
    final keys = HardwareKeyboard.instance;
    final now = DateTime.now();
    final isDouble = _clicks.lastPath == entity.path &&
        now.difference(_clicks.lastTime) <= kDoubleTapTimeout;
    _clicks
      ..lastPath = entity.path
      ..lastTime = now;

    if (isDouble && !_commandPressed && !keys.isShiftPressed) {
      _clicks.lastPath = null;
      _open(context, state, entity);
      return;
    }
    if (_commandPressed) {
      final items = {...state.selectedItems};
      if (!items.remove(entity)) items.add(entity);
      _clicks.anchorPath = entity.path;
      bloc.add(SetSelection(items, selectionMode: items.length > 1));
      return;
    }
    final anchor = _clicks.anchorPath;
    if (keys.isShiftPressed && anchor != null) {
      final paths = [for (final e in state.entities) e.path];
      final from = paths.indexOf(anchor);
      final to = paths.indexOf(entity.path);
      if (from >= 0 && to >= 0) {
        final range = state.entities
            .sublist(math.min(from, to), math.max(from, to) + 1)
            .toSet();
        bloc.add(SetSelection(range, selectionMode: range.length > 1));
        return;
      }
    }
    _clicks.anchorPath = entity.path;
    bloc.add(SetSelection({entity}));
  }

  /// Right-click on an item: its menu, or the selection's when it's part of
  /// a selection of several.
  void _showItemMenu(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
    Offset position,
  ) {
    final selected = state.selectedItems;
    if (selected.length > 1 && selected.any((e) => e.path == entity.path)) {
      _showSelectionMenu(context, state, position);
      return;
    }
    _clicks.anchorPath = entity.path;
    context.read<FileExplorerBloc>().add(SetSelection({entity}));
    fileActionsService.showContextMenu(
      context,
      entity,
      position,
      onOpen: () => _open(context, state, entity),
    );
  }

  Future<void> _showSelectionMenu(
    BuildContext context,
    FileExplorerLoaded state,
    Offset position,
  ) async {
    final bloc = context.read<FileExplorerBloc>();
    final selected = state.selectedItems.toList();
    final action = await ExplorerMenu.showAt<String>(
      context,
      position,
      items: [
        ExplorerMenu.label(context, '${selected.length} selected'),
        if (Desktop.canShareFiles)
          ExplorerMenu.item(context,
              value: 'share', label: 'Share', icon: LucideIcons.share2),
        ExplorerMenu.item(context,
            value: 'nearby', label: 'Send nearby', icon: LucideIcons.radio),
        ExplorerMenu.item(context,
            value: 'zip',
            label: 'Compress to ZIP',
            icon: LucideIcons.fileArchive),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'all',
            label: 'Select all',
            icon: LucideIcons.listChecks,
            shortcut: FileActionsService.shortcut('A')),
        ExplorerMenu.item(context,
            value: 'none', label: 'Clear selection', icon: LucideIcons.x),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'delete',
            label: 'Delete',
            icon: LucideIcons.trash2,
            destructive: true,
            shortcut: 'Delete'),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'share':
        fileActionsService.shareMany(context, selected);
      case 'nearby':
        bloc.add(ToggleSelectionMode(enable: false));
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LocalSendScreen(initialItems: selected),
          ),
        );
      case 'zip':
        _handleCompress(context, state);
      case 'all':
        bloc.add(SelectAll());
      case 'none':
        bloc.add(ToggleSelectionMode(enable: false));
      case 'delete':
        fileActionsService.deleteFiles(context, selected);
    }
  }

  /// Right-click on the empty space of a folder.
  Future<void> _showFolderMenu(
    BuildContext context,
    FileExplorerLoaded state,
    Offset position,
  ) async {
    final bloc = context.read<FileExplorerBloc>();
    final clipboard = context.read<ClipboardBloc>();
    final inFolder = !ExplorerPaths.isWindowsRoots(state.path);
    final canPaste = inFolder && clipboard.state is ClipboardReadyToPaste;
    final action = await ExplorerMenu.showAt<String>(
      context,
      position,
      items: [
        if (inFolder)
          ExplorerMenu.item(context,
              value: 'folder',
              label: 'New folder',
              icon: LucideIcons.folderPlus,
              shortcut: Platform.isMacOS ? '⇧⌘N' : 'Ctrl+Shift+N'),
        ExplorerMenu.item(context,
            value: 'paste',
            label: 'Paste',
            icon: LucideIcons.clipboardPaste,
            enabled: canPaste,
            shortcut: FileActionsService.shortcut('V')),
        ExplorerMenu.item(context,
            value: 'all',
            label: 'Select all',
            icon: LucideIcons.listChecks,
            shortcut: FileActionsService.shortcut('A')),
        ExplorerMenu.item(context,
            value: 'refresh',
            label: 'Refresh',
            icon: LucideIcons.refreshCw,
            shortcut: 'F5'),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'window',
            label: 'Open in new window',
            icon: LucideIcons.appWindow,
            shortcut: FileActionsService.shortcut('N')),
        if (inFolder)
          ExplorerMenu.item(context,
              value: 'wifi',
              label: 'Share over Wi-Fi',
              icon: LucideIcons.wifi),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'folder':
        fileActionsService.showCreateFolderDialog(context, state.path);
      case 'paste':
        clipboard.add(PasteFromClipboard(state.path));
      case 'all':
        bloc.add(SelectAll());
      case 'refresh':
        bloc.add(LoadDirectory(state.path));
      case 'window':
        Desktop.openWindow(folder: state.path);
      case 'wifi':
        _handleHttpShare(context, state);
    }
  }

  static String _friendlyError(String message) {
    if (message.contains('not found or access denied')) {
      return "It may have been moved or deleted, or Explorer isn't allowed "
          'to read it.';
    }
    return message;
  }

  void _handleTap(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) async {
    if (state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(SelectItem(entity));
    } else {
      await _open(context, state, entity);
    }
  }

  void _handleLongPress(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) {
    HapticFeedback.selectionClick();
    if (!state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(ToggleSelectionMode(enable: true));
    }
    context.read<FileExplorerBloc>().add(SelectItem(entity));
  }

  Future<void> _handleCompress(
    BuildContext context,
    FileExplorerLoaded state,
  ) async {
    if (state.selectedItems.isEmpty) return;
    final count = state.selectedItems.length;

    final String? fileName = await fileActionsService.promptForName(
      context,
      title: 'Compress to ZIP',
      description: count == 1
          ? 'The selected item will be added to a new ZIP archive in this '
                'folder.'
          : '$count items will be added to a new ZIP archive in this folder.',
      initialValue: 'archive.zip',
      selectBaseName: true,
      confirmLabel: 'Compress',
    );

    if (fileName != null && fileName.isNotEmpty && context.mounted) {
      // Filter only files for now, directories need recursive add logic in ArchiveService
      // My ArchiveService.compressFiles only takes List<File>.
      // So we filter:
      final filesOnly = state.selectedItems.whereType<File>().toList();

      if (filesOnly.length != state.selectedItems.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Folders were skipped: they can't be compressed yet"),
          ),
        );
      }

      if (filesOnly.isEmpty) return;

      try {
        final destPath = p.join(
          state.path,
          fileName.endsWith('.zip') ? fileName : '$fileName.zip',
        );
        await ArchiveService().compressFiles(filesOnly, File(destPath));

        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Compressed to $fileName')));
          // Refresh
          context.read<FileExplorerBloc>().add(LoadDirectory(state.path));
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Compression failed: $e')));
        }
      }
    }
  }

  Future<void> _handleHttpShare(
    BuildContext context,
    FileExplorerState state,
  ) async {
    if (state is! FileExplorerLoaded ||
        ExplorerPaths.isWindowsRoots(state.path)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open a folder to share it')),
      );
      return;
    }
    final bloc = context.read<FileExplorerBloc>();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FileServerScreen(initialFolder: state.path),
      ),
    );
    // Show files other devices uploaded.
    final now = bloc.state;
    if (!bloc.isClosed && now is FileExplorerLoaded) {
      bloc.add(LoadDirectory(now.path));
    }
  }
}

/// "4 folders · 14 files" under the last row.
class _FolderSummary extends StatelessWidget {
  const _FolderSummary({required this.entities});

  final List<FileSystemEntity> entities;

  @override
  Widget build(BuildContext context) {
    final folders = entities.whereType<Directory>().length;
    final files = entities.length - folders;
    final parts = [
      if (folders > 0) '$folders ${folders == 1 ? 'folder' : 'folders'}',
      if (files > 0) '$files ${files == 1 ? 'file' : 'files'}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text(
        parts.join(' · '),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// Placeholder rows while a folder loads.
class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton({required this.top});

  final double top;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: top),
      itemCount: 12,
      itemBuilder: (context, index) => SizedBox(
        height: 62,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(120.0 + (index * 37) % 90, 12),
                  const SizedBox(height: 8),
                  bar(72.0 + (index * 23) % 40, 10),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [child] only if it's still on screen after a short delay, so fast
/// folder loads don't flash a placeholder.
class _DelayedReveal extends StatefulWidget {
  const _DelayedReveal({required this.child});

  final Widget child;

  @override
  State<_DelayedReveal> createState() => _DelayedRevealState();
}

class _DelayedRevealState extends State<_DelayedReveal> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: widget.child,
    );
  }
}

/// Shown when storage access hasn't been granted.
class _PermissionDeniedScreen extends StatelessWidget {
  const _PermissionDeniedScreen({required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: ExplorerEmptyState(
          icon: LucideIcons.folderLock,
          title: 'Allow access to your files',
          description:
              'Explorer needs the "All files access" permission to '
              'browse, open and organise the files on this device. Nothing '
              'leaves your device.',
          actions: [
            OutlinedButton(
              onPressed: openAppSettings,
              child: const Text('Open settings'),
            ),
            FilledButton(
              onPressed: onRequest,
              child: const Text('Allow access'),
            ),
          ],
        ),
      ),
    );
  }
}
