import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppBrowser, WebUri;
import 'package:path/path.dart' as p;

import 'viewer_ui.dart';

/// A file next to [source] that doesn't exist yet: `name.ext`,
/// `name (1).ext`, `name (2).ext` …
Future<File> uniqueSibling(
  File source,
  String extension, {
  String suffix = '',
}) async {
  final dir = p.dirname(source.path);
  final base = '${p.basenameWithoutExtension(source.path)}$suffix';
  final ext = extension.startsWith('.') ? extension.substring(1) : extension;
  var candidate = File(p.join(dir, '$base.$ext'));
  var n = 1;
  while (await candidate.exists()) {
    candidate = File(p.join(dir, '$base ($n).$ext'));
    n++;
  }
  return candidate;
}

/// Writes through a temporary file so a failed write never truncates the
/// original document.
Future<void> writeFileSafely(File target, Uint8List bytes) async {
  final tmp = File('${target.path}.saving~');
  await tmp.writeAsBytes(bytes, flush: true);
  try {
    await tmp.rename(target.path);
  } catch (_) {
    await target.writeAsBytes(bytes, flush: true);
    try {
      await tmp.delete();
    } catch (_) {}
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

//// Bottom sheet for a tapped hyperlink: open in the browser or copy.
Future<void> showLinkSheet(BuildContext context, String url) {
  final internal = url.startsWith('#');
  final canOpen =
      !internal &&
      (url.startsWith('http://') ||
          url.startsWith('https://') ||
          url.startsWith('mailto:') ||
          url.startsWith('tel:'));
  return AppSheet.show<void>(
    context,
    child: Builder(
      builder: (sheet) {
        final colors = sheet.colors;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ViewerSheetHeader(
              title: internal ? 'Link within the document' : 'Link',
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.muted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    internal ? LucideIcons.hash : LucideIcons.link,
                    size: 16,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      internal ? url.substring(1) : url,
                      minLines: 1,
                      maxLines: 4,
                      style: Theme.of(sheet).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: const Text('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      Navigator.pop(sheet);
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(content: Text('Link copied')),
                      );
                    },
                  ),
                ),
                if (canOpen) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(LucideIcons.externalLink, size: 16),
                      label: const Text('Open'),
                      onPressed: () async {
                        Navigator.pop(sheet);
                        try {
                          await InAppBrowser.openWithSystemBrowser(
                            url: WebUri(url),
                          );
                        } catch (_) {
                          await Clipboard.setData(ClipboardData(text: url));
                          if (context.mounted) {
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Couldn\'t open a browser; link copied instead',
                                ),
                              ),
                            );
                          }
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// Simple three-way prompt for unsaved changes.
enum UnsavedChoice { save, discard, cancel }

Future<UnsavedChoice> askUnsavedChanges(
  BuildContext context, {
  String saveLabel = 'Save',
}) async {
  final r = await showDialog<UnsavedChoice>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: const Text('Do you want to save your changes before leaving?'),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: d.colors.destructive),
          onPressed: () => Navigator.pop(d, UnsavedChoice.discard),
          child: const Text('Discard'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(d, UnsavedChoice.cancel),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, UnsavedChoice.save),
          child: Text(saveLabel),
        ),
      ],
    ),
  );
  return r ?? UnsavedChoice.cancel;
}
