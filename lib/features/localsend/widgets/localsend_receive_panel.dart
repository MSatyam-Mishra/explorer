import 'dart:io';

import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/localsend/localsend.dart';
import 'package:explorer/features/localsend/localsend_controller.dart';
import 'package:explorer/features/localsend/widgets/localsend_common.dart';
import 'package:flutter/material.dart';

/// This device's identity, the running incoming transfer and received files.
class LsReceivePanel extends StatelessWidget {
  const LsReceivePanel({
    super.key,
    required this.controller,
    required this.padding,
  });

  final LocalSendController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final history = controller.receiveHistory;
    final current =
        controller.receiveSession ??
        (history.isNotEmpty &&
                DateTime.now().difference(
                      history.first.endedAt ?? DateTime.now(),
                    ) <
                    const Duration(minutes: 10)
            ? history.first
            : null);
    return ListView(
      padding: padding,
      children: [
        _ThisDeviceSection(controller: controller),
        if (current != null)
          _ReceiveProgressSection(controller: controller, session: current),
        _ReceivedSection(controller: controller),
      ],
    );
  }
}

class _ThisDeviceSection extends StatelessWidget {
  const _ThisDeviceSection({required this.controller});

  final LocalSendController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = controller.settings;
    if (settings == null) return const SizedBox.shrink();
    final port = controller.serverPort ?? settings.port;
    final addresses = controller.localAddresses;
    final error = controller.serverError;
    final pin = settings.pin;
    return LsSection(
      title: 'Receive',
      icon: Icons.download,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.onSurface.withValues(
                  alpha: 0.08,
                ),
                foregroundColor: theme.colorScheme.onSurface,
                child: Icon(lsDeviceIcon(settings.deviceType), size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(settings.alias, style: theme.textTheme.titleLarge),
                    Text(
                      error == null
                          ? 'Visible to nearby devices while this screen is open'
                          : 'Not receiving',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (error != null) ...[
            Text(error, style: TextStyle(color: theme.colorScheme.error)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: controller.retryServer,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ),
          ] else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final a in addresses.take(3))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.lan_outlined, size: 16),
                    label: Text('$a:$port'),
                  ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    settings.https ? Icons.lock_outline : Icons.lock_open,
                    size: 16,
                  ),
                  label: Text(settings.https ? 'HTTPS' : 'HTTP'),
                ),
                if (pin != null && pin.isNotEmpty)
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.pin_outlined, size: 16),
                    label: Text('PIN required'),
                  ),
                if (settings.autoAcceptTrusted)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.verified_user_outlined, size: 16),
                    label: Text(
                      'Auto-accept ${controller.trusted.length} trusted',
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Save to'),
            subtitle: Text(
              settings.destination,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open folder',
              onPressed: () async {
                await Directory(settings.destination).create(recursive: true);
                if (context.mounted) {
                  await lsShowInFolder(context, settings.destination);
                }
              },
            ),
          ),
          if (controller.destinationFallback)
            Text(
              'The Download folder is not writable (storage permission?), '
              'so files go to the app folder above. Change it in settings.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (controller.multicastError != null)
            Text(
              'Other devices may not find this one automatically '
              '(${controller.multicastError}); they can add it by IP.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _ReceiveProgressSection extends StatelessWidget {
  const _ReceiveProgressSection({
    required this.controller,
    required this.session,
  });

  final LocalSendController controller;
  final LsReceiveSession session;

  String _stateText() => switch (session.state) {
    LsReceiveState.receiving => 'Receiving…',
    LsReceiveState.finished =>
      session.failedCount == 0
          ? 'Received ${session.doneCount} ${session.doneCount == 1 ? 'file' : 'files'}'
          : 'Received ${session.doneCount}, ${session.failedCount} failed',
    LsReceiveState.cancelledBySender =>
      '${session.sender.alias} cancelled the transfer',
    LsReceiveState.cancelledByReceiver => 'Cancelled',
    LsReceiveState.stalled => 'The sender stopped responding',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = session.totalBytes;
    final received = session.receivedBytes;
    final files = session.files.values.toList();
    final active = session.isActive;
    return LsSection(
      title: 'From ${session.sender.alias}',
      icon: lsDeviceIcon(session.sender.deviceType),
      trailing: active
          ? TextButton(
              onPressed: controller.cancelReceive,
              child: const Text('Cancel'),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_stateText()),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: total == 0 ? (active ? null : 1) : received / total,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 4),
          Text(
            '${lsSize(received)} / ${lsSize(total)} · ${session.doneCount}/${files.length} files',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: files.length,
              itemBuilder: (context, i) {
                final f = files[i];
                final size = f.dto.size;
                final saved = f.savedPath;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: LsFileIcon(f.dto.fileName, size: 32),
                  title: Text(
                    f.dto.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: switch (f.status) {
                    LsReceiveFileStatus.receiving => LinearProgressIndicator(
                      value: size == 0 ? null : f.received / size,
                    ),
                    LsReceiveFileStatus.failed => Text(
                      f.error ?? 'Failed',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    _ => Text(lsSize(size)),
                  },
                  trailing: switch (f.status) {
                    LsReceiveFileStatus.done => Icon(
                      Icons.check_circle,
                      color: theme.colorScheme.primary,
                    ),
                    LsReceiveFileStatus.failed => Icon(
                      Icons.error,
                      color: theme.colorScheme.error,
                    ),
                    _ => null,
                  },
                  onTap: saved == null
                      ? null
                      : () => FileOpener.open(context, File(saved)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceivedSection extends StatelessWidget {
  const _ReceivedSection({required this.controller});

  final LocalSendController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.received;
    final theme = Theme.of(context);
    return LsSection(
      title: 'Received',
      icon: Icons.inventory_2_outlined,
      child: items.isEmpty
          ? Text(
              'Files you receive while this screen is open appear here.',
              style: theme.textTheme.bodyMedium,
            )
          : Column(
              children: [
                for (final item in items.take(200))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: LsFileIcon(item.path),
                    title: Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${lsSize(item.size)} · from ${item.from}'),
                    onTap: () => _open(context, item),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'More',
                      onSelected: (v) {
                        switch (v) {
                          case 'open':
                            _open(context, item);
                          case 'folder':
                            lsShowInFolder(context, item.path);
                          case 'remove':
                            controller.removeReceived(item);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'open', child: Text('Open')),
                        PopupMenuItem(
                          value: 'folder',
                          child: Text('Show in folder'),
                        ),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove from list'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  void _open(BuildContext context, LsReceivedItem item) {
    final file = File(item.path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file was moved or deleted.')),
      );
      return;
    }
    FileOpener.open(context, file);
  }
}
