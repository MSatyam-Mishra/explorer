import 'package:flutter/material.dart';

/// Single-field input dialog. [validate] returns an error message or null.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String? helper,
  String action = 'OK',
  String? Function(String value)? validate,
  bool selectAll = true,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      initial: initial,
      label: label,
      helper: helper,
      action: action,
      validate: validate,
      selectAll: selectAll,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.initial,
    required this.action,
    required this.selectAll,
    this.label,
    this.helper,
    this.validate,
  });

  final String title;
  final String initial;
  final String? label;
  final String? helper;
  final String action;
  final bool selectAll;
  final String? Function(String value)? validate;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.selectAll) {
      _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    final err = widget.validate?.call(v);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
