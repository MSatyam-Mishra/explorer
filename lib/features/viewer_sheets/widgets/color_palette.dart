import 'package:flutter/material.dart';

import 'grid_colors.dart';

/// Result of the colour picker; [color] null means automatic / no fill.
class ColorChoice {
  const ColorChoice(this.color);
  final int? color;
}

Future<ColorChoice?> showColorPalette(
  BuildContext context, {
  required String title,
  required String noneLabel,
  int? current,
}) {
  return showDialog<ColorChoice>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.format_color_reset_outlined),
                label: Text(noneLabel),
                onPressed: () => Navigator.pop(context, const ColorChoice(null)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in kSheetPalette)
                    Semantics(
                      button: true,
                      label: '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => Navigator.pop(context, ColorChoice(c)),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: current == c ? scheme.primary : scheme.outlineVariant,
                              width: current == c ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ],
      );
    },
  );
}
