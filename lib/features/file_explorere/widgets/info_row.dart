// Helper widget for a row in the info sheet
import 'package:flutter/material.dart';

class InfoRow extends StatelessWidget {
  final String title;
  final String content;
  const InfoRow({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(content, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
  }
}



