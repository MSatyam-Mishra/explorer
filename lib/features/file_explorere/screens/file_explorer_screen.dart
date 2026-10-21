import 'dart:async';
import 'dart:io';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/archive_service.dart';
import 'package:explorer/core/services/file_action_service.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/services/http_server_service.dart';
import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_header.dart';
import 'package:explorer/features/file_explorere/widgets/file_grid_item.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart';
import 'package:explorer/features/file_explorere/widgets/paste_bar.dart';
import 'package:explorer/features/localsend/screens/localsend_screen.dart';
import 'package:explorer/features/network/widgets/server_status_dialog.dart';
import 'package:explorer/features/sidebar/bloc/bloc/sidebar_bloc.dart';
import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_options_sheet.dart';
import 'package:explorer/shared/widgets/main_drawer.dart';
import 'package:explorer/shared/widgets/progress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

FileActionsService fileActionsService = FileActionsService();

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
  _FileExplorerUI();

  /// Sidebar width when it's docked next to the files (tablets, desktops).
  static const double _sidebarWidth = 280;

  @override
  Widget build(BuildContext context) {
    // We listen to multiple BLoCs to build the final UI
    final fileExplorerState = context.watch<FileExplorerBloc>().state;
    final clipboardState = context.watch<ClipboardBloc>().state;
    final taskState = context.watch<TaskProgressBloc>().state;

    final path = _pathOf(fileExplorerState);
    final loaded =
        fileExplorerState is FileExplorerLoaded ? fileExplorerState : null;
    final bool isSelectionMode = loaded?.isSelectionMode ?? false;
    final String? parentPath = path == null ? null : ExplorerPaths.parentOf(path);
    final bool canPop = !isSelectionMode && parentPath == null;

    // Tablets, unfolded foldables and desktops keep navigation docked.
    final bool docked = AdaptiveSplitView.isSplit(context);
    final bool busy = taskState is TaskInProgress;
    final pasteState =
        clipboardState is ClipboardReadyToPaste && !busy ? clipboardState : null;
    final bool canCreate =
        loaded != null && !ExplorerPaths.isWindowsRoots(loaded.path);
    final bool showFab = !docked &&
        canCreate &&
        loaded.entities.isNotEmpty &&
        !isSelectionMode &&
        pasteState == null &&
        !busy;

    final bottomInset = (pasteState != null ? PasteBar.reservedHeight : 0.0) +
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
                    : () => context
                        .read<ClipboardBloc>()
                        .add(PasteFromClipboard(loaded.path)),
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
    );
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
              context.read<ClipboardBloc>().add(CopyToClipboard(selected.first));
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
    final loaded =
        fileExplorerState is FileExplorerLoaded ? fileExplorerState : null;
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
          ? () => fileActionsService.showCreateFolderDialog(context, loaded.path)
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
      return _DelayedReveal(
        child: _ListSkeleton(top: topInset + 8),
      );
    }
    if (state is FileExplorerError) {
      final parent =
          state.path == null ? null : ExplorerPaths.parentOf(state.path!);
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

    void onTap(FileSystemEntity e) => _handleTap(context, state, e);
    void onLongPress(FileSystemEntity e) => _handleLongPress(context, state, e);
    VoidCallback? onSecondaryTap(FileSystemEntity e) => state.isSelectionMode
        ? null
        : () => fileActionsService.showFileOptionsMenu(context, e);

    final footer = SliverToBoxAdapter(
      child: _FolderSummary(entities: entities),
    );

    final List<Widget> slivers;
    if (state.viewMode == ViewMode.grid ||
        state.viewMode == ViewMode.gallery) {
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
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final entity = entities[index];
                return FileGridItem(
                  entity: entity,
                  displayName: state.labelFor(entity),
                  gallery: gallery,
                  isSelectionMode: state.isSelectionMode,
                  isSelected: state.selectedItems.contains(entity),
                  onTap: () => onTap(entity),
                  onLongPress: () => onLongPress(entity),
                  onSecondaryTap: onSecondaryTap(entity),
                );
              },
              childCount: entities.length,
            ),
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
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final entity = entities[index];
                return FileListItem(
                  entity: entity,
                  displayName: state.labelFor(entity),
                  style: style,
                  isSelectionMode: state.isSelectionMode,
                  isSelected: state.selectedItems.contains(entity),
                  onTap: () => onTap(entity),
                  onLongPress: () => onLongPress(entity),
                  onSecondaryTap: onSecondaryTap(entity),
                );
              },
              childCount: entities.length,
            ),
          ),
        ),
        footer,
      ];
    }

    return Scrollbar(
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
      if (entity is Directory) {
        context.read<FileExplorerBloc>().add(LoadDirectory(entity.path));
      } else {
        final bloc = context.read<FileExplorerBloc>();
        final result = await FileOpener.open(context, entity as File);
        // Only re-list when the viewer changed the folder (saved a copy...).
        if (result == true && !bloc.isClosed) {
          bloc.add(LoadDirectory(state.path));
        }
      }
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Compression failed: $e')),
          );
        }
      }
    }
  }

  final HttpServerService _httpService = HttpServerService();

  Future<void> _handleHttpShare(
    BuildContext context,
    FileExplorerState state,
  ) async {
    if (state is! FileExplorerLoaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot share: Directory not loaded')),
        );
      }
      return;
    }

    // Start Server
    try {
      final url = await _httpService.startServer(state.path);

      if (context.mounted) {
        await showDialog(
          context: context,
          barrierDismissible:
              false, // Force use of Stop button or explicit cancel
          builder: (context) => ServerStatusDialog(
            url: url,
            onStop: () async {
              // The dialog calls onStop then pops; we only stop the server.
              await _httpService.stopServer();
            },
          ),
        );
        // Ensure stopped if dialog closed otherwise
        if (_httpService.isRunning) {
          await _httpService.stopServer();
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to start server: $e')));
      }
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
          description: 'Explorer needs the "All files access" permission to '
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
