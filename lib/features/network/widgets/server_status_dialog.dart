import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ServerStatusDialog extends StatelessWidget {
  final String url;
  final VoidCallback onStop;

  const ServerStatusDialog({
    super.key,
    required this.url,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('HTTP File Server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Scan to browse files:'),
          const SizedBox(height: 16),
          SizedBox(
            width: 200,
            height: 200,
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URL copied to clipboard')),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    url,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Keep this dialog open to keep server running.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            onStop();
            Navigator.pop(context);
          },
          child: const Text('Stop Server', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }
}
