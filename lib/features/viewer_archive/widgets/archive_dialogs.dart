import 'package:explorer/core/formats/archive_backend.dart';
import 'package:explorer/core/formats/archive_extract.dart';
import 'package:explorer/features/viewer_archive/archive_ui_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Asks for an archive password. Returns null when cancelled.
Future<String?> showArchivePasswordDialog(
  BuildContext context, {
  required String archiveName,
  bool wrongPassword = false,
  String? detail,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _PasswordDialog(
      archiveName: archiveName,
      wrongPassword: wrongPassword,
      detail: detail,
    ),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.archiveName,
    required this.wrongPassword,
    this.detail,
  });

  final String archiveName;
  final bool wrongPassword;
  final String? detail;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isEmpty) return;
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.lock_outline, color: scheme.primary),
      title: Text(widget.wrongPassword ? 'Wrong password' : 'Password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.wrongPassword
                ? 'That password didn\'t work for "${widget.archiveName}". '
                    'Try again.'
                : widget.detail ??
                    '"${widget.archiveName}" is password protected.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              errorText: widget.wrongPassword ? ' ' : null,
              errorStyle: const TextStyle(height: 0),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Remembered until you close this archive.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}

/// Asks what to do with files that already exist. Null cancels.
Future<ConflictPolicy?> showConflictDialog(
  BuildContext context,
  int count,
  List<String> examples,
) {
  return showDialog<ConflictPolicy>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.file_copy_outlined),
      title: Text(count == 1 ? 'File already exists' : '$count files already exist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in examples.take(3))
            Text(
              e,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (count > 3)
            Text(
              '…and ${count - 3} more',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ConflictPolicy.skip),
          child: const Text('Skip'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ConflictPolicy.rename),
          child: const Text('Keep both'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ConflictPolicy.overwrite),
          child: const Text('Replace'),
        ),
      ],
    ),
  );
}

class ExtractOptions {
  const ExtractOptions(this.destination, this.policy);
  final String destination;
  final ConflictPolicy policy;
}

/// Bottom sheet to confirm an extraction and pick where it goes.
Future<ExtractOptions?> showExtractSheet(
  BuildContext context, {
  required String title,
  required String parent,
  required String folderName,
  required int fileCount,
  required int totalBytes,
  int? freeBytes,
}) {
  return showModalBottomSheet<ExtractOptions>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ExtractSheet(
      title: title,
      parent: parent,
      folderName: folderName,
      fileCount: fileCount,
      totalBytes: totalBytes,
      freeBytes: freeBytes,
    ),
  );
}

class _ExtractSheet extends StatefulWidget {
  const _ExtractSheet({
    required this.title,
    required this.parent,
    required this.folderName,
    required this.fileCount,
    required this.totalBytes,
    this.freeBytes,
  });

  final String title;
  final String parent;
  final String folderName;
  final int fileCount;
  final int totalBytes;
  final int? freeBytes;

  @override
  State<_ExtractSheet> createState() => _ExtractSheetState();
}

class _ExtractSheetState extends State<_ExtractSheet> {
  late String _parent = widget.parent;
  bool _ownFolder = true;
  ConflictPolicy _policy = ConflictPolicy.ask;

  String get _destination =>
      _ownFolder ? p.join(_parent, widget.folderName) : _parent;

  Future<void> _pick() async {
    String? picked;
    try {
      picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Extract to',
        initialDirectory: _parent,
      );
    } catch (_) {
      picked = null;
    }
    if (!mounted) return;
    if (picked == null || picked.isEmpty) return;
    if (picked.startsWith('content://') || picked == '/') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That location can\'t be written to.')),
      );
      return;
    }
    setState(() => _parent = picked!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final free = widget.freeBytes;
    final short = free != null && widget.totalBytes > free;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${widget.fileCount} ${widget.fileCount == 1 ? 'file' : 'files'}'
              ' · ${formatBytes(widget.totalBytes)}'
              '${free == null ? '' : ' · ${formatBytes(free)} free'}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: short ? theme.colorScheme.error : null,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Destination'),
              subtitle: Text(
                _destination,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed: _pick,
                child: const Text('Change'),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _ownFolder,
              onChanged: (v) => setState(() => _ownFolder = v ?? true),
              title: Text('In a new folder "${widget.folderName}"'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            Text('If a file already exists', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<ConflictPolicy>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ConflictPolicy.ask, label: Text('Ask')),
                ButtonSegment(value: ConflictPolicy.skip, label: Text('Skip')),
                ButtonSegment(
                  value: ConflictPolicy.overwrite,
                  label: Text('Replace'),
                ),
                ButtonSegment(
                  value: ConflictPolicy.rename,
                  label: Text('Keep both'),
                ),
              ],
              selected: {_policy},
              onSelectionChanged: (s) => setState(() => _policy = s.first),
            ),
            if (short) ...[
              const SizedBox(height: 12),
              Text(
                'There isn\'t enough free space for everything.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    ExtractOptions(_destination, _policy),
                  ),
                  icon: const Icon(Icons.unarchive_outlined),
                  label: const Text('Extract'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Error explanation with an optional "Open with another app".
Future<void> showArchiveErrorDialog(
  BuildContext context,
  ArcException error, {
  VoidCallback? onOpenElsewhere,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      ),
      title: Text(errorTitle(error.kind)),
      content: Text(error.message),
      actions: [
        if (onOpenElsewhere != null && error.suggestOtherApp)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onOpenElsewhere();
            },
            child: const Text('Open with another app'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Lists entries that couldn't be extracted.
Future<void> showFailuresDialog(
  BuildContext context,
  List<(String, String)> failures,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text(
        failures.length == 1
            ? '1 item couldn\'t be extracted'
            : '${failures.length} items couldn\'t be extracted',
      ),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (path, message) in failures.take(50))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(message),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Floating progress card for a running extraction.
class ExtractProgressCard extends StatelessWidget {
  const ExtractProgressCard({
    super.key,
    required this.title,
    required this.progress,
    required this.onCancel,
  });

  final String title;
  final ExtractProgress? progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pr = progress;
    final seeking = pr?.seeking;
    final current = pr == null || pr.current.isEmpty
        ? 'Preparing…'
        : seeking != null
        ? 'Unpacking the data stored before ${p.basename(pr.current)} '
            '(solid archive)…'
        : p.basename(pr.current);
    final detail = pr == null
        ? ''
        : seeking != null
        ? '${(seeking * 100).round()}%'
        : pr.totalBytes > 0
        ? '${formatBytes(pr.doneBytes)} of ${formatBytes(pr.totalBytes)}'
        : '${pr.doneFiles} of ${pr.totalFiles} files';
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    current,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: seeking ?? pr?.fraction,
                      minHeight: 6,
                    ),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(detail, style: theme.textTheme.labelSmall),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Cancel',
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}
