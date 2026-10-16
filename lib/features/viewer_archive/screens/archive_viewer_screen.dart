import 'dart:async';
import 'dart:io';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:explorer/core/formats/archive_backend.dart';
import 'package:explorer/core/formats/archive_extract.dart';
import 'package:explorer/core/formats/archive_index.dart';
import 'package:explorer/core/formats/archive_session.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/features/viewer_archive/archive_ui_utils.dart';
import 'package:explorer/features/viewer_archive/widgets/archive_dialogs.dart';
import 'package:explorer/features/viewer_archive/widgets/archive_entry_tile.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

enum _SortKey { name, size, date, type }

/// Browses ZIP/JAR/APK, TAR (+gz/bz2/xz), RAR 4/5, 7z and ISO/UDF images.
///
/// Listing, decoding and extraction run in background isolates. Pops with
/// `true` when it extracted files into the folder that holds the archive,
/// so the explorer refreshes.
class ArchiveViewerScreen extends StatefulWidget {
  final File archiveFile;

  const ArchiveViewerScreen({super.key, required this.archiveFile});

  @override
  State<ArchiveViewerScreen> createState() => _ArchiveViewerScreenState();
}

class _ArchiveViewerScreenState extends State<ArchiveViewerScreen> {
  ArchiveSession? _session;
  StreamSubscription<ArcOpenEvent>? _openSub;
  ArcSummary? _summary;
  ArcException? _error;
  double? _listProgress;
  int _foundSoFar = 0;
  String? _password;

  String _folder = '';
  _SortKey _sortKey = _SortKey.name;
  bool _ascending = true;

  bool _searching = false;
  String _query = '';
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<String>? _lowerNames;

  final Set<String> _selected = {};

  ExtractJob? _job;
  ExtractProgress? _progress;
  String _jobTitle = '';
  bool _jobVisible = false;
  bool _changedFolder = false;

  final _scroll = ScrollController();
  final Map<String, double> _offsets = {};
  final Map<int, String> _opened = {};

  String? _rowsKey;
  List<Object> _rows = const [];

  String get _archiveName => p.basename(widget.archiveFile.path);

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _openSub?.cancel();
    _session?.dispose();
    _job?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Opening
  // ---------------------------------------------------------------------------

  Future<void> _open() async {
    setState(() {
      _error = null;
      _summary = null;
      _listProgress = null;
      _foundSoFar = 0;
    });
    try {
      if (_session == null) {
        final session = await ArchiveSession.spawn();
        if (!mounted) {
          session.dispose();
          return;
        }
        _session = session;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = ArcException(
              ArcErrorKind.io,
              'Couldn\'t start the archive reader.',
              detail: '$e',
            ));
      }
      return;
    }
    if (!mounted) return;
    await _openSub?.cancel();
    _openSub = _session!
        .open(widget.archiveFile.path, password: _password)
        .listen(
          (event) {
            if (!mounted) return;
            switch (event) {
              case ArcOpenProgress(:final fraction):
                setState(() => _listProgress = fraction);
              case ArcOpenPartial(:final entries):
                setState(() => _foundSoFar += entries.length);
              case ArcOpenReady(:final summary):
                setState(() {
                  _summary = summary;
                  _lowerNames = null;
                  _rowsKey = null;
                  if (!summary.index.folders.containsKey(_folder)) _folder = '';
                });
            }
          },
          onError: (Object e) =>
              _onOpenError(e is ArcException ? e : mapKoniError(e)),
        );
  }

  Future<void> _onOpenError(ArcException e) async {
    if (!mounted) return;
    if (e.kind == ArcErrorKind.needPassword ||
        e.kind == ArcErrorKind.wrongPassword) {
      final pw = await showArchivePasswordDialog(
        context,
        archiveName: _archiveName,
        wrongPassword: e.kind == ArcErrorKind.wrongPassword,
        detail: e.message,
      );
      if (!mounted) return;
      if (pw == null) {
        setState(() => _error = e);
        return;
      }
      _password = pw;
      _open();
      return;
    }
    setState(() => _error = e);
  }

  void _openArchiveElsewhere() =>
      FileOpener.openExternally(context, widget.archiveFile);

  // ---------------------------------------------------------------------------
  // Listing
  // ---------------------------------------------------------------------------

  int _compare(Object a, Object b) {
    final aFolder = a is ArcFolder, bFolder = b is ArcFolder;
    if (aFolder != bFolder) return aFolder ? -1 : 1;
    String nameOf(Object o) => o is ArcFolder ? o.name : (o as ArcEntry).name;
    int c;
    switch (_sortKey) {
      case _SortKey.name:
        c = 0;
      case _SortKey.size:
        int size(Object o) =>
            o is ArcFolder ? o.totalSize : (o as ArcEntry).size;
        c = size(a).compareTo(size(b));
      case _SortKey.date:
        DateTime? date(Object o) =>
            o is ArcFolder ? o.modified : (o as ArcEntry).modified;
        final da = date(a), db = date(b);
        c = da == null
            ? (db == null ? 0 : -1)
            : (db == null ? 1 : da.compareTo(db));
      case _SortKey.type:
        c = p
            .extension(nameOf(a))
            .toLowerCase()
            .compareTo(p.extension(nameOf(b)).toLowerCase());
    }
    if (c == 0) c = naturalCompare(nameOf(a), nameOf(b));
    return _ascending ? c : -c;
  }

  List<Object> _currentRows(ArcIndex index) {
    final key = '$_folder|$_sortKey|$_ascending|$_searching|$_query';
    if (key == _rowsKey) return _rows;
    final rows = <Object>[];
    if (_searching && _query.isNotEmpty) {
      final q = _query.toLowerCase();
      final names = _lowerNames ??= [
        for (final e in index.entries) e.name.toLowerCase(),
      ];
      for (final f in index.folders.values) {
        if (f.path.isNotEmpty && f.name.toLowerCase().contains(q)) rows.add(f);
      }
      for (final e in index.entries) {
        if (!e.isDirectory && names[e.index].contains(q)) rows.add(e);
        if (rows.length >= 5000) break;
      }
    } else {
      final folder = index.folders[_folder] ?? index.root;
      for (final path in folder.folders) {
        rows.add(index.folders[path]!);
      }
      for (final i in folder.files) {
        rows.add(index.entries[i]);
      }
    }
    rows.sort(_compare);
    _rowsKey = key;
    _rows = rows;
    return rows;
  }

  void _enterFolder(String path) {
    if (_scroll.hasClients) _offsets[_folder] = _scroll.offset;
    setState(() {
      _folder = path;
      if (_searching) {
        _searching = false;
        _query = '';
        _searchController.clear();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_offsets[path] ?? 0);
    });
  }

  String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  // ---------------------------------------------------------------------------
  // Selection, search, back
  // ---------------------------------------------------------------------------

  void _toggle(String path) {
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  void _selectAll() {
    final summary = _summary;
    if (summary == null) return;
    setState(() {
      for (final r in _currentRows(summary.index)) {
        _selected.add(r is ArcFolder ? r.path : (r as ArcEntry).path);
      }
    });
  }

  void _setQuery(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _query = q.trim());
    });
  }

  Future<void> _handleBack() async {
    if (_job != null) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Stop extracting?'),
          content: const Text('Leaving stops the extraction in progress.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep going'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Stop'),
            ),
          ],
        ),
      );
      if (stop != true || !mounted) return;
      _job?.cancel();
      Navigator.pop(context, _changedFolder);
      return;
    }
    if (_selected.isNotEmpty) {
      setState(_selected.clear);
      return;
    }
    if (_searching) {
      setState(() {
        _searching = false;
        _query = '';
        _searchController.clear();
      });
      return;
    }
    if (_folder.isNotEmpty && _summary != null) {
      _enterFolder(_parentOf(_folder));
      return;
    }
    Navigator.pop(context, _changedFolder);
  }

  // ---------------------------------------------------------------------------
  // Jobs
  // ---------------------------------------------------------------------------

  ExtractRequest _withPassword(ExtractRequest r, String? password) =>
      ExtractRequest(
        archivePath: r.archivePath,
        destination: r.destination,
        password: password,
        paths: r.paths,
        stripPrefix: r.stripPrefix,
        policy: r.policy,
        flat: r.flat,
        targets: r.targets,
        freeBytes: r.freeBytes,
        reportEachFile: r.reportEachFile,
      );

  Future<ExtractResult?> _runJob(
    ExtractRequest request, {
    required String title,
    bool quiet = false,
  }) async {
    ExtractJob job;
    try {
      job = await ExtractJob.start(request);
    } catch (e) {
      if (mounted) {
        await showArchiveErrorDialog(
          context,
          ArcException(ArcErrorKind.io, 'Couldn\'t start extracting.',
              detail: '$e'),
        );
      }
      return null;
    }
    if (!mounted) {
      job.cancel();
      return null;
    }
    setState(() {
      _job = job;
      _progress = null;
      _jobTitle = title;
      _jobVisible = !quiet;
    });
    if (quiet) {
      Timer(const Duration(milliseconds: 350), () {
        if (mounted && identical(_job, job)) {
          setState(() => _jobVisible = true);
        }
      });
    }
    ExtractResult? result;
    ArcException? error;
    await for (final ev in job.events) {
      if (!mounted) break;
      switch (ev) {
        case ExtractProgress():
          setState(() => _progress = ev);
        case ExtractConflicts(:final count, :final examples):
          final policy = await showConflictDialog(context, count, examples);
          job.answerConflicts(policy);
        case ExtractDone():
          result = ev.result;
        case ExtractFailed():
          error = ev.error;
        case ExtractFileDone():
          break;
      }
    }
    if (!mounted) return null;
    setState(() {
      _job = null;
      _progress = null;
      _jobVisible = false;
    });
    final err = error;
    if (err != null) {
      if (err.kind == ArcErrorKind.cancelled) return null;
      if (err.kind == ArcErrorKind.needPassword ||
          err.kind == ArcErrorKind.wrongPassword) {
        final pw = await showArchivePasswordDialog(
          context,
          archiveName: _archiveName,
          wrongPassword: err.kind == ArcErrorKind.wrongPassword,
          detail: err.message,
        );
        if (pw == null || !mounted) return null;
        _password = pw;
        return _runJob(
          _withPassword(request, pw),
          title: title,
          quiet: quiet,
        );
      }
      await showArchiveErrorDialog(
        context,
        err,
        onOpenElsewhere: _openArchiveElsewhere,
      );
      return null;
    }
    return result;
  }

  Future<bool> _ensurePassword(Iterable<ArcEntry> entries) async {
    if (_password != null || !entries.any((e) => e.isEncrypted)) return true;
    final pw = await showArchivePasswordDialog(
      context,
      archiveName: _archiveName,
    );
    if (pw == null) return false;
    _password = pw;
    return true;
  }

  Future<void> _openEntry(ArcEntry e) async {
    if (e.isSymlink) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          e.linkTarget == null
              ? '"${e.name}" is a link.'
              : '"${e.name}" is a link to ${e.linkTarget}.',
        ),
      ));
      return;
    }
    final reason = e.unsupportedReason;
    if (reason != null) {
      await showArchiveErrorDialog(
        context,
        ArcException(ArcErrorKind.unsupported, reason),
        onOpenElsewhere: _openArchiveElsewhere,
      );
      return;
    }
    if (!await _ensurePassword([e]) || !mounted) return;
    final cached = _opened[e.index];
    if (cached != null) {
      final f = File(cached);
      if (f.existsSync() && (e.size < 0 || f.lengthSync() == e.size)) {
        await FileOpener.open(context, f);
        return;
      }
    }
    final Directory dir;
    try {
      dir = await openCacheDirFor(widget.archiveFile);
    } catch (err) {
      if (mounted) {
        await showArchiveErrorDialog(
          context,
          ArcException(ArcErrorKind.io, 'No space for temporary files.',
              detail: '$err'),
        );
      }
      return;
    }
    final target = p.join(dir.path, '${e.index}', sanitizeSegment(e.name) ?? 'file');
    final result = await _runJob(
      ExtractRequest(
        archivePath: widget.archiveFile.path,
        destination: p.dirname(target),
        password: _password,
        policy: ConflictPolicy.overwrite,
        targets: {e.index: target},
      ),
      title: 'Opening ${e.name}',
      quiet: true,
    );
    if (result == null || !mounted) return;
    if (result.failures.isNotEmpty) {
      await showArchiveErrorDialog(
        context,
        ArcException(ArcErrorKind.corrupt, result.failures.first.$2),
        onOpenElsewhere: _openArchiveElsewhere,
      );
      return;
    }
    final path = result.written[e.index];
    if (path == null) return;
    _opened[e.index] = path;
    await FileOpener.open(context, File(path));
  }

  Future<int?> _freeBytes(String path) async {
    try {
      var dir = path;
      while (!Directory(dir).existsSync() && p.dirname(dir) != dir) {
        dir = p.dirname(dir);
      }
      final mb = await DiskSpacePlus()
          .getFreeDiskSpaceForPath(dir)
          .timeout(const Duration(seconds: 2));
      return mb == null ? null : (mb * 1024 * 1024).round();
    } catch (_) {
      return null;
    }
  }

  Future<void> _extract({List<String>? paths}) async {
    final summary = _summary;
    if (summary == null || _job != null) return;
    final entries = paths == null ? summary.entries : summary.index.select(paths);
    final files = entries.where((e) => !e.isDirectory && !e.isSymlink).toList();
    if (files.isEmpty && entries.every((e) => !e.isDirectory)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to extract.')),
      );
      return;
    }
    if (!await _ensurePassword(files) || !mounted) return;
    var total = 0;
    for (final e in files) {
      if (e.size > 0) total += e.size;
    }
    var parent = p.dirname(widget.archiveFile.path);
    if (await isInTempDir(widget.archiveFile.path)) {
      parent = await fallbackExtractRoot();
    }
    final free = await _freeBytes(parent);
    if (!mounted) return;

    // Decompression-bomb warning for absurd expansion ratios.
    if (total > 1024 * 1024 * 1024 &&
        summary.archiveSize > 0 &&
        total > summary.archiveSize * 100) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Unusually large'),
          content: Text(
            'This ${formatBytes(summary.archiveSize)} archive expands to '
            '${formatBytes(total)} (${total ~/ summary.archiveSize}× its size). '
            'Archives like this are sometimes built to fill up storage. '
            'Extract anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Extract'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }

    final options = await showExtractSheet(
      context,
      title: paths == null
          ? 'Extract all'
          : 'Extract ${paths.length} ${paths.length == 1 ? 'item' : 'items'}',
      parent: parent,
      folderName: archiveBaseName(widget.archiveFile.path),
      fileCount: files.length,
      totalBytes: total,
      freeBytes: free,
    );
    if (options == null || !mounted) return;
    final dest = options.destination;
    final result = await _runJob(
      ExtractRequest(
        archivePath: widget.archiveFile.path,
        destination: dest,
        password: _password,
        paths: paths,
        stripPrefix: paths == null ? '' : _folder,
        policy: options.policy,
        freeBytes: p.isWithin(parent, dest) || p.equals(parent, dest)
            ? free
            : null,
      ),
      title: 'Extracting to ${p.basename(dest)}',
    );
    if (result == null || !mounted) return;
    final archiveDir = p.dirname(widget.archiveFile.path);
    if (result.changedDestination &&
        (p.equals(archiveDir, dest) || p.isWithin(archiveDir, dest))) {
      _changedFolder = true;
    }
    setState(_selected.clear);
    final parts = <String>[
      'Extracted ${result.files} ${result.files == 1 ? 'file' : 'files'}',
      if (result.skippedExisting > 0) '${result.skippedExisting} skipped',
      if (result.skippedLinks > 0) '${result.skippedLinks} links ignored',
      if (result.skippedUnsafe > 0) '${result.skippedUnsafe} unsafe paths ignored',
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${parts.join(', ')} to ${p.basename(dest)}'),
      duration: const Duration(seconds: 4),
    ));
    if (result.failures.isNotEmpty) {
      await showFailuresDialog(context, result.failures);
    }
  }

  void _showInfo() {
    final s = _summary;
    if (s == null) return;
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        Widget row(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(k, style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    )),
                  ),
                  Expanded(child: SelectableText(v)),
                ],
              ),
            );
        final ratio = ratioLabel(s.index.totalSize, s.archiveSize);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_archiveName, style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                row('Format', s.formatLabel),
                row('Files', '${s.index.fileCount}'),
                row('Folders', '${s.index.folders.length - 1}'),
                row('Unpacked', formatBytes(s.index.totalSize)),
                row('On disk', '${formatBytes(s.archiveSize)}'
                    '${ratio == null ? '' : ' ($ratio)'}'),
                if (s.index.anyEncrypted) row('Encryption', 'Password protected'),
                if (s.isSequential)
                  row('Note', 'Solid/streamed archive: opening a file unpacks '
                      'everything stored before it.'),
                if (s.volumes.length > 1)
                  row('Parts', s.volumes.map(p.basename).join('\n')),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    final ready = _summary != null;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: ExplorerScaffold(
        // The default back button pops through PopScope, i.e. _handleBack.
        title: _archiveName,
        topBarBuilder: _selected.isNotEmpty
            ? _selectionBar
            : _searching
            ? _searchBar
            : null,
        trailing: ExplorerTopBar.actions(context, [
          ExplorerTopBar.iconButton(
            context: context,
            icon: Icon(Icons.search, color: iconColor),
            tooltip: 'Search in archive',
            onPressed: ready ? () => setState(() => _searching = true) : null,
          ),
          PopupMenuButton<Object>(
            tooltip: 'Sort',
            enabled: ready,
            icon: Icon(Icons.sort, color: iconColor),
            onSelected: (v) => setState(() {
              if (v is _SortKey) {
                if (_sortKey == v) {
                  _ascending = !_ascending;
                } else {
                  _sortKey = v;
                  _ascending = v == _SortKey.name || v == _SortKey.type;
                }
              }
            }),
            itemBuilder: (context) => [
              for (final (key, label) in [
                (_SortKey.name, 'Name'),
                (_SortKey.size, 'Size'),
                (_SortKey.date, 'Date'),
                (_SortKey.type, 'Type'),
              ])
                CheckedPopupMenuItem<Object>(
                  value: key,
                  checked: _sortKey == key,
                  child: Row(
                    children: [
                      Expanded(child: Text(label)),
                      if (_sortKey == key)
                        Icon(
                          _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 16,
                        ),
                    ],
                  ),
                ),
            ],
          ),
          ExplorerTopBar.iconButton(
            context: context,
            icon: Icon(Icons.unarchive_outlined, color: iconColor),
            tooltip: 'Extract all',
            onPressed: ready && _job == null ? () => _extract() : null,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: Icon(Icons.more_vert, color: iconColor),
            onSelected: (v) {
              if (v == 'info') _showInfo();
              if (v == 'external') _openArchiveElsewhere();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'info',
                enabled: ready,
                child: const Text('Archive info'),
              ),
              const PopupMenuItem(
                value: 'external',
                child: Text('Open with another app'),
              ),
            ],
          ),
        ]),
        body: Stack(
          children: [
            Positioned.fill(child: _buildBody(context)),
            if (_job != null && _jobVisible)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: ExtractProgressCard(
                  title: _jobTitle,
                  progress: _progress,
                  onCancel: () => _job?.cancel(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _selectionBar(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    return DockedGlossyTopBar(
      title: '${_selected.length} selected',
      leading: IconButton(
        icon: Icon(Icons.close, color: iconColor),
        tooltip: 'Clear selection',
        onPressed: () => setState(_selected.clear),
      ),
      trailing: ExplorerTopBar.actions(context, [
        ExplorerTopBar.iconButton(
          context: context,
          icon: Icon(Icons.select_all, color: iconColor),
          tooltip: 'Select all',
          onPressed: _selectAll,
        ),
        ExplorerTopBar.iconButton(
          context: context,
          icon: Icon(Icons.unarchive_outlined, color: iconColor),
          tooltip: 'Extract selected',
          onPressed: _job == null
              ? () => _extract(paths: _selected.toList())
              : null,
        ),
      ]),
    );
  }

  Widget _searchBar(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: iconColor),
            tooltip: 'Close search',
            onPressed: () => setState(() {
              _searching = false;
              _query = '';
              _searchController.clear();
            }),
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _setQuery,
              textInputAction: TextInputAction.search,
              style: ClearGlassForeground.title(context).copyWith(
                fontWeight: FontWeight.w400,
              ),
              decoration: InputDecoration(
                hintText: 'Search in $_archiveName',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: Icon(Icons.clear, color: iconColor),
              tooltip: 'Clear',
              onPressed: () {
                _searchController.clear();
                _setQuery('');
              },
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    final err = _error;
    if (err != null) return _errorView(context, err, topInset);
    final summary = _summary;
    if (summary == null) {
      return ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: topInset + 4),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _foundSoFar > 0
                      ? 'Reading archive… $_foundSoFar items found'
                      : 'Reading archive…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: _listProgress, minHeight: 3),
                ),
              ],
            ),
          ),
          const ArchiveSkeleton(),
        ],
      );
    }
    final rows = _currentRows(summary.index);
    final bottomPad = 24 + MediaQuery.paddingOf(context).bottom +
        (_job != null ? 110 : 0);
    return Scrollbar(
      controller: _scroll,
      interactive: true,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(padding: EdgeInsets.only(top: topInset)),
          SliverToBoxAdapter(child: _header(context, summary)),
          if (rows.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Center(
                  child: Text(
                    _searching && _query.isNotEmpty
                        ? 'No matches'
                        : 'This folder is empty',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          SliverFixedExtentList(
            itemExtent: kArchiveRowHeight,
            delegate: SliverChildBuilderDelegate(
              (context, i) => _tile(rows[i]),
              childCount: rows.length,
            ),
          ),
          SliverPadding(padding: EdgeInsets.only(bottom: bottomPad)),
        ],
      ),
    );
  }

  Widget _tile(Object row) {
    final showPath = _searching && _query.isNotEmpty;
    if (row is ArcFolder) {
      return ArchiveEntryTile.folder(
        key: ValueKey('d:${row.path}'),
        folder: row,
        selected: _selected.contains(row.path),
        selecting: _selected.isNotEmpty,
        showPath: showPath,
        onTap: () => _selected.isNotEmpty
            ? _toggle(row.path)
            : _enterFolder(row.path),
        onLongPress: () => _toggle(row.path),
      );
    }
    final e = row as ArcEntry;
    return ArchiveEntryTile.file(
      key: ValueKey('f:${e.index}'),
      entry: e,
      selected: _selected.contains(e.path),
      selecting: _selected.isNotEmpty,
      showPath: showPath,
      onTap: () => _selected.isNotEmpty ? _toggle(e.path) : _openEntry(e),
      onLongPress: () => _toggle(e.path),
    );
  }

  Widget _header(BuildContext context, ArcSummary s) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7);
    final crumbs = <(String, String)>[('', _archiveName)];
    if (_folder.isNotEmpty) {
      var acc = '';
      for (final seg in _folder.split('/')) {
        acc = acc.isEmpty ? seg : '$acc/$seg';
        crumbs.add((acc, seg));
      }
    }
    final ratio = ratioLabel(s.index.totalSize, s.archiveSize);
    final searching = _searching && _query.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!searching)
            SizedBox(
              height: 36,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: [
                    for (var i = 0; i < crumbs.length; i++) ...[
                      if (i > 0)
                        Icon(Icons.chevron_right, size: 18, color: muted),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: i == crumbs.length - 1
                            ? null
                            : () => _enterFolder(crumbs[i].$1),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (i == 0) ...[
                              const Icon(Icons.inventory_2_outlined, size: 16),
                              const SizedBox(width: 6),
                            ],
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                crumbs[i].$2,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  searching
                      ? '${_rows.length}${_rows.length >= 5000 ? '+' : ''} '
                          'matches for "$_query"'
                      : '${s.formatLabel} · ${s.index.fileCount} files · '
                          '${formatBytes(s.index.totalSize)}'
                          '${ratio == null ? '' : ' → ${formatBytes(s.archiveSize)} ($ratio)'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                if (s.index.anyEncrypted && !searching)
                  _badge(context, Icons.lock_outline,
                      _password == null ? 'Encrypted' : 'Unlocked'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: scheme.primary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.primary)),
        ],
      ),
    );
  }

  Widget _errorView(BuildContext context, ArcException err, double topInset) {
    final theme = Theme.of(context);
    final needsPassword = err.kind == ArcErrorKind.needPassword ||
        err.kind == ArcErrorKind.wrongPassword;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(32, topInset + 24, 32, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                needsPassword ? Icons.lock_outline : Icons.inventory_2_outlined,
                size: 56,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(errorTitle(err.kind), style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                err.message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (needsPassword)
                    FilledButton.icon(
                      onPressed: () => _onOpenError(err),
                      icon: const Icon(Icons.key),
                      label: const Text('Enter password'),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: _open,
                      child: const Text('Try again'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _openArchiveElsewhere,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open with another app'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
