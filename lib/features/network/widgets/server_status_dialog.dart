import 'dart:async';

import 'package:explorer/core/services/file_server/http_file_server.dart';
import 'package:explorer/features/viewer_kit/viewer_kit.dart' show IconBox;
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Shown while a folder is shared over HTTP: the address and its QR code,
/// the uploads switch and Stop. The caller stops the server when it closes.
class ServerStatusDialog extends StatefulWidget {
  const ServerStatusDialog({
    super.key,
    required this.server,
    required this.folderName,
  });

  final HttpFileServer server;
  final String folderName;

  @override
  State<ServerStatusDialog> createState() => _ServerStatusDialogState();
}

class _ServerStatusDialogState extends State<ServerStatusDialog> {
  StreamSubscription<String>? _received;
  final _uploaded = <String>[];

  @override
  void initState() {
    super.initState();
    _received = widget.server.received.listen(
      (path) => setState(() => _uploaded.add(p.basename(path))),
    );
  }

  @override
  void dispose() {
    _received?.cancel();
    super.dispose();
  }

  void _copy(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Address copied')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final server = widget.server;
    final url = server.url ?? '';
    final others = server.urls.skip(1).toList();

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      title: Row(
        children: [
          IconBox(LucideIcons.wifi, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sharing over Wi-Fi'),
                Text(
                  widget.folderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Scan the code, or open the address in a browser on a device '
                'on the same Wi-Fi.',
              ),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.border),
                  ),
                  child: QrImageView(
                    data: url,
                    size: 168,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF09090B),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF09090B),
                    ),
                    semanticsLabel: 'QR code for $url',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _AddressField(url: url, onCopy: () => _copy(url)),
              if (others.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('Also at ${others.join(', ')}', style: text.bodySmall),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: server.allowUploads,
                onChanged: (v) => setState(() => server.allowUploads = v),
                title: const Text('Allow uploads'),
                subtitle: const Text(
                  'Anyone with the address can add files to this folder.',
                ),
              ),
              if (_uploaded.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: colors.muted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.circleCheck,
                        size: 18,
                        color: colors.foreground,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _uploaded.length == 1
                              ? 'Received ${_uploaded.single}'
                              : 'Received ${_uploaded.length} files, '
                                    'latest ${_uploaded.last}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    LucideIcons.info,
                    size: 14,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Keep Explorer open while sharing.',
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: colors.destructive,
            foregroundColor: colors.destructiveForeground,
          ),
          onPressed: () => Navigator.pop(context),
          icon: const Icon(LucideIcons.circleStop, size: 18),
          label: const Text('Stop sharing'),
        ),
      ],
    );
  }
}

class _AddressField extends StatelessWidget {
  const _AddressField({required this.url, required this.onCopy});

  final String url;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.input),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onCopy,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(LucideIcons.globe, size: 16, color: colors.mutedForeground),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    url,
                    maxLines: 1,
                    style: TextStyle(
                      color: colors.foreground,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AppIconButton(
                icon: const Icon(LucideIcons.copy, size: 18),
                tooltip: 'Copy address',
                onPressed: onCopy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
