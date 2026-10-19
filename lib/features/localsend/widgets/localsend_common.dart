import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/localsend/localsend.dart';
import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

String lsSize(int bytes) => filesize(bytes, 1);

String lsSpeed(double bytesPerSecond) =>
    bytesPerSecond <= 0 ? '' : '${filesize(bytesPerSecond.round(), 1)}/s';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The app palettes can have a pale primary in light mode: buttons, tabs and
/// progress bars here use the text colour instead when primary would be hard
/// to read on the surface.
ThemeData lsTheme(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  if (_contrast(scheme.primary, scheme.surface) >= 3) return theme;
  return theme.copyWith(
    colorScheme: scheme.copyWith(
      primary: scheme.onSurface,
      onPrimary: scheme.onSurface.computeLuminance() > 0.5
          ? Colors.black
          : Colors.white,
    ),
  );
}

/// Applies [lsTheme] to dialogs and sheets (they use the root theme).
Widget lsThemed(BuildContext context, Widget child) =>
    Theme(data: lsTheme(context), child: child);

IconData lsDeviceIcon(LsDeviceType? type) => switch (type) {
  LsDeviceType.mobile => Icons.smartphone,
  LsDeviceType.desktop => Icons.computer,
  LsDeviceType.web => Icons.language,
  LsDeviceType.headless => Icons.terminal,
  LsDeviceType.server => Icons.dns,
  null => Icons.devices_other,
};

/// Rounded section used by both panels.
class LsSection extends StatelessWidget {
  const LsSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// Icon for a (possibly folder-relative) file name.
class LsFileIcon extends StatelessWidget {
  const LsFileIcon(this.name, {super.key, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) =>
      FileIcon(path: p.basename(name), size: size);
}

/// Reveals [path] in the system file manager on desktop; on phones shows the
/// folder in a sheet where files can be opened.
Future<void> lsShowInFolder(BuildContext context, String path) async {
  final isDir = FileSystemEntity.isDirectorySync(path);
  final folder = isDir ? path : p.dirname(path);
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', isDir ? [path] : ['/select,', path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', isDir ? [path] : ['-R', path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [folder]);
      return;
    }
  } catch (_) {
    // Fall back to the in-app listing below.
  }
  if (!context.mounted) return;
  await ExplorerLiquidGlassBottomSheet.show<void>(
    context,
    child: lsThemed(
      context,
      LsFolderSheet(folder: folder, highlight: isDir ? null : path),
    ),
  );
}

/// Simple in-app folder listing (phones): open files, enter sub-folders.
class LsFolderSheet extends StatefulWidget {
  const LsFolderSheet({super.key, required this.folder, this.highlight});

  final String folder;
  final String? highlight;

  @override
  State<LsFolderSheet> createState() => _LsFolderSheetState();
}

class _LsFolderSheetState extends State<LsFolderSheet> {
  late String _dir = widget.folder;
  List<FileSystemEntity> _entries = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await Directory(
        _dir,
      ).list().where((e) => !p.basename(e.path).startsWith('.')).toList();
      list.sort((a, b) {
        final da = a is Directory ? 0 : 1;
        final db = b is Directory ? 0 : 1;
        if (da != db) return da - db;
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });
      if (mounted) {
        setState(() {
          _entries = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.66;
    final scheme = Theme.of(context).colorScheme;
    final canGoUp =
        !p.equals(_dir, widget.folder) && p.isWithin(widget.folder, _dir);
    return SizedBox(
      height: height,
      child: Column(
        children: [
          ListTile(
            leading: canGoUp
                ? IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: 'Up',
                    onPressed: () {
                      setState(() => _dir = p.dirname(_dir));
                      _load();
                    },
                  )
                : const FolderIcon(size: 32),
            title: Text(
              p.basename(_dir),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_dir, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const Divider(height: 1),
          Expanded(
            child: _error != null
                ? Center(child: Text('Cannot open folder: $_error'))
                : _entries.isEmpty
                ? const Center(child: Text('Empty folder'))
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      final name = p.basename(e.path);
                      final isDir = e is Directory;
                      final selected = e.path == widget.highlight;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: scheme.onSurface.withValues(
                          alpha: 0.08,
                        ),
                        leading: isDir
                            ? const FolderIcon(size: 40)
                            : LsFileIcon(name),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: isDir
                            ? null
                            : Text(lsSize((e as File).statSync().size)),
                        onTap: () {
                          if (isDir) {
                            setState(() => _dir = e.path);
                            _load();
                          } else {
                            FileOpener.open(context, e as File);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
