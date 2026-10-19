import 'dart:async';

import 'package:explorer/core/services/localsend/localsend.dart';
import 'package:explorer/features/localsend/widgets/localsend_common.dart';
import 'package:flutter/material.dart';

/// Result of the incoming-transfer dialog.
class LsIncomingAnswer {
  const LsIncomingAnswer({required this.accept, this.trust = false});

  final bool accept;

  /// Accept this device automatically from now on.
  final bool trust;
}

/// Accept/decline dialog. Closes by itself when the sender withdraws.
Future<LsIncomingAnswer> showLsIncomingDialog(
  BuildContext context,
  LsIncomingRequest request, {
  required bool alreadyTrusted,
}) async {
  final navigator = Navigator.of(context);
  var open = true;
  unawaited(
    request.cancelled.then((_) {
      if (open && navigator.mounted) navigator.pop();
    }),
  );
  final result = await showDialog<LsIncomingAnswer>(
    context: context,
    barrierDismissible: false,
    builder: (_) => lsThemed(
      context,
      _IncomingDialog(request: request, alreadyTrusted: alreadyTrusted),
    ),
  );
  open = false;
  return result ?? const LsIncomingAnswer(accept: false);
}

class _IncomingDialog extends StatefulWidget {
  const _IncomingDialog({required this.request, required this.alreadyTrusted});

  final LsIncomingRequest request;
  final bool alreadyTrusted;

  @override
  State<_IncomingDialog> createState() => _IncomingDialogState();
}

class _IncomingDialogState extends State<_IncomingDialog> {
  bool _trust = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final sender = r.sender;
    final theme = Theme.of(context);
    final count = r.files.length;
    final files = List.of(r.files)
      ..sort((a, b) => a.fileName.compareTo(b.fileName));
    return AlertDialog(
      icon: Icon(lsDeviceIcon(sender.deviceType), size: 36),
      titleTextStyle: theme.textTheme.titleLarge,
      title: Text(
        '${sender.alias} wants to send you $count ${count == 1 ? 'file' : 'files'}',
        textAlign: TextAlign.center,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                if (sender.deviceModel != null) sender.deviceModel!,
                r.senderIp,
                lsSize(r.totalSize),
              ].join(' · '),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: files.length,
                itemBuilder: (context, i) {
                  final f = files[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: LsFileIcon(f.fileName, size: 32),
                    title: Text(
                      f.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      lsSize(f.size),
                      style: theme.textTheme.bodySmall,
                    ),
                  );
                },
              ),
            ),
            if (!widget.alreadyTrusted && sender.fingerprint.isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _trust,
                onChanged: (v) => setState(() => _trust = v ?? false),
                title: const Text('Always accept from this device'),
                subtitle: const Text(
                  'Needs "Auto-accept trusted devices" in settings',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const LsIncomingAnswer(accept: false)),
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            LsIncomingAnswer(accept: true, trust: _trust),
          ),
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

/// Asks for the receiver's PIN; null when dismissed.
Future<String?> showLsPinDialog(
  BuildContext context, {
  required String deviceAlias,
  required bool invalid,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => lsThemed(
    context,
    _TextPromptDialog(
      title: 'PIN for $deviceAlias',
      label: 'PIN',
      helper: "Set in the receiver's LocalSend settings",
      error: invalid ? 'Wrong PIN, try again' : null,
      action: 'Send',
    ),
  ),
);

/// Asks for `ip` or `ip:port`.
Future<String?> showLsAddressDialog(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => lsThemed(
    context,
    const _TextPromptDialog(
      title: 'Add device by IP',
      label: 'IP address',
      hint: '192.168.1.20 or 192.168.1.20:53317',
      helper: "Shown in the other device's LocalSend settings",
      action: 'Add',
      keyboardType: TextInputType.url,
    ),
  ),
);

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.action,
    this.hint,
    this.helper,
    this.error,
    this.keyboardType,
  });

  final String title;
  final String label;
  final String action;
  final String? hint;
  final String? helper;
  final String? error;
  final TextInputType? keyboardType;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          helperText: widget.helper,
          errorText: widget.error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
