import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Five-segment ring preview of a color theme palette.
class ThemePaletteCircle extends StatelessWidget {
  const ThemePaletteCircle({
    super.key,
    required this.colors,
    this.size = 28,
    this.selected = false,
  });

  final List<Color> colors;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size + (selected ? 6 : 0),
      height: size + (selected ? 6 : 0),
      decoration: selected
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      alignment: Alignment.center,
      child: CustomPaint(
        size: Size.square(size),
        painter: _PaletteRingPainter(colors: colors.take(5).toList()),
      ),
    );
  }
}

class _PaletteRingPainter extends CustomPainter {
  _PaletteRingPainter({required this.colors});

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = size.width / 2;
    final inner = outer * 0.38;
    final segmentCount = colors.isEmpty ? 1 : colors.length;
    final sweep = (2 * math.pi) / segmentCount;

    for (var i = 0; i < segmentCount; i++) {
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.fill;
      final start = -math.pi / 2 + i * sweep;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(
          Rect.fromCircle(center: center, radius: outer),
          start,
          sweep,
          false,
        )
        ..lineTo(
          center.dx + inner * math.cos(start + sweep),
          center.dy + inner * math.sin(start + sweep),
        )
        ..arcTo(
          Rect.fromCircle(center: center, radius: inner),
          start + sweep,
          -sweep,
          false,
        )
        ..close();
      canvas.drawPath(path, paint);
    }

    final hole = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, inner * 0.92, hole);
  }

  @override
  bool shouldRepaint(covariant _PaletteRingPainter oldDelegate) {
    return oldDelegate.colors != colors;
  }
}
