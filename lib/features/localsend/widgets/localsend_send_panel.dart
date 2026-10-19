import 'dart:io';

import 'package:explorer/core/services/localsend/localsend.dart';
import 'package:explorer/features/localsend/localsend_controller.dart';
import 'package:explorer/features/localsend/widgets/localsend_common.dart';
import 'package:explorer/features/localsend/widgets/localsend_dialogs.dart';
import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Files to send, nearby devices and the running send transfer.
class LsSendPanel extends StatelessWidget {
  const LsSendPanel({
    super.key,
    required this.controller,
    required this.padding,
  });

  final LocalSendController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final session = controller.sendSession;
    return ListView(
      padding: padding,
      children: [
        _FilesSection(controller: controller),
        if (session != null)
          _SendProgressSection(controller: controller, session: session),
        _DevicesSection(controller: controller),
      ],
    );
  }
}

class _FilesSection extends StatelessWidget {
  const _FilesSection({required this.controller});

  final LocalSendController controller;

  Future<void> _pickFiles(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = result?.files.map((f) => f.path).whereType<String>().toList();
    if (paths == null || paths.isEmpty) return;
    controller.addItems(paths.map(File.new));
  }

  Future<void> _pickFolder(BuildContext context) async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    controller.addItems([Directory(path)]);
  }

  @override
  Widget build(BuildContext context) {
    final items = controller.items;
    final files = controller.sendFiles;
    final theme = Theme.of(context);
    final busy =
        controller.sendSession != null && !controller.sendSession!.isDone;
    return LsSection(
      title: 'Files to send',
      icon: Icons.upload_file,
      trailing: items.isEmpty || busy
          ? null
          : TextButton(
              onPressed: controller.clearItems,
              child: const Text('Clear'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Pick files or folders, then tap a device below. Folders keep their structure.',
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final e = items[i];
                  final isDir = e is Directory;
                  final (count, bytes) = controller.statsFor(e);
                  final name = p.basename(p.normalize(e.path));
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: isDir
                        ? const FolderIcon(size: 40)
                        : FileIcon(path: name, size: 40),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      files == null
                          ? 'Counting…'
                          : isDir
                          ? 'Folder · $count ${count == 1 ? 'file' : 'files'} · ${lsSize(bytes)}'
                          : (count == 0 ? 'Not readable' : lsSize(bytes)),
                    ),
                    trailing: busy
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Remove',
                            onPressed: () => controller.removeItem(e),
                          ),
                  );
                },
              ),
            ),
          if (items.isNotEmpty && files != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                '${files.length} ${files.length == 1 ? 'file' : 'files'} · ${lsSize(controller.sendTotalBytes)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => _pickFiles(context),
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('Add files'),
              ),
              if (!Platform.isIOS)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _pickFolder(context),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add folder'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.controller});

  final LocalSendController controller;

  Future<void> _addByIp(BuildContext context) async {
    final address = await showLsAddressDialog(context);
    if (address == null || address.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Connecting to $address…')));
    try {
      final device = await controller.addByAddress(address);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Added ${device.alias}')));
    } on LsException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not add $address: ${e.message}')),
        );
    }
  }

  void _send(BuildContext context, LsDevice device) {
    final error = controller.sendTo(device);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = controller.devices;
    final theme = Theme.of(context);
    final scanning = controller.scanning;
    return LsSection(
      title: 'Nearby devices',
      icon: Icons.wifi_tethering,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: 'Add by IP',
            onPressed: controller.service == null
                ? null
                : () => _addByIp(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: controller.service == null ? null : controller.refresh,
          ),
        ],
      ),
      child: devices.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  scanning
                      ? 'Scanning the network…'
                      : 'Looking for devices… Open LocalSend on the other device '
                            'and make sure both are on the same Wi-Fi.',
                  style: theme.textTheme.bodyMedium,
                ),
                if (controller.multicastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Automatic discovery is limited here (${controller.multicastError}). '
                      'Use "Scan network" or add the device by IP.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: scanning || controller.service == null
                        ? null
                        : controller.scan,
                    icon: const Icon(Icons.radar),
                    label: const Text('Scan network'),
                  ),
                ),
              ],
            )
          : Column(
              children: [
                for (final d in devices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.onSurface.withValues(
                        alpha: 0.08,
                      ),
                      foregroundColor: theme.colorScheme.onSurface,
                      child: Icon(lsDeviceIcon(d.info.deviceType)),
                    ),
                    title: Text(
                      d.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (d.info.deviceModel != null) d.info.deviceModel!,
                        d.ip,
                        if (d.protocol == LsProtocol.http) 'HTTP',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(
                      Icons.send,
                      color: theme.colorScheme.primary,
                    ),
                    onTap: () => _send(context, d),
                  ),
              ],
            ),
    );
  }
}

class _SendProgressSection extends StatelessWidget {
  const _SendProgressSection({required this.controller, required this.session});

  final LocalSendController controller;
  final LsSendSession session;

  String _stateText() => switch (session.state) {
    LsSendState.preparing => 'Preparing…',
    LsSendState.waitingForPin => 'Waiting for the PIN…',
    LsSendState.waitingForAcceptance =>
      'Waiting for ${session.target.alias} to accept…',
    LsSendState.sending => 'Sending… ${lsSpeed(session.speed)}',
    LsSendState.finished => 'Sent',
    LsSendState.finishedWithErrors => 'Finished with errors',
    LsSendState.declined => 'Declined by ${session.target.alias}',
    LsSendState.failed => session.error?.message ?? 'Failed',
    LsSendState.cancelled => 'Cancelled',
    LsSendState.cancelledByReceiver =>
      '${session.target.alias} cancelled the transfer',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = session.totalBytes;
    final sent = session.sentBytes;
    final done = session.isDone;
    final ok = session.state == LsSendState.finished;
    final files = session.files.values.toList();
    final waiting =
        session.state == LsSendState.waitingForAcceptance ||
        session.state == LsSendState.preparing;
    return LsSection(
      title: 'To ${session.target.alias}',
      icon: lsDeviceIcon(session.target.info.deviceType),
      trailing: done
          ? TextButton(
              onPressed: controller.dismissSend,
              child: const Text('Done'),
            )
          : TextButton(
              onPressed: controller.cancelSend,
              child: const Text('Cancel'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _stateText(),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: done && !ok ? theme.colorScheme.error : null,
            ),
          ),
          if (done &&
              !ok &&
              session.state == LsSendState.failed &&
              session.error?.detail != null)
            Text(session.error!.detail!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: waiting
                ? null
                : (total == 0 ? (done ? 1 : 0) : sent / total),
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 4),
          Text(
            '${lsSize(sent)} / ${lsSize(total)} · ${files.where((f) => f.status == LsSendFileStatus.done).length}/${files.length} files',
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
                final size = f.file.size;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: LsFileIcon(f.file.fileName, size: 32),
                  title: Text(
                    f.file.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: switch (f.status) {
                    LsSendFileStatus.sending => LinearProgressIndicator(
                      value: size == 0 ? null : f.sent / size,
                    ),
                    LsSendFileStatus.failed => Text(
                      f.error ?? 'Failed',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    LsSendFileStatus.skipped => const Text(
                      'Skipped by receiver',
                    ),
                    _ => Text(lsSize(size)),
                  },
                  trailing: switch (f.status) {
                    LsSendFileStatus.done => Icon(
                      Icons.check_circle,
                      color: theme.colorScheme.primary,
                    ),
                    LsSendFileStatus.failed => Icon(
                      Icons.error,
                      color: theme.colorScheme.error,
                    ),
                    _ => null,
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
