import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart' show QrCode, QrErrorCorrectLevel, QrImage;

/// A QR code drawn round: dots, neighbouring dots joined into rounded
/// lines, and ring-and-dot corner markers. The markers keep the 1:1:3:1:1
/// proportions scanners look for, and the higher error correction covers
/// the rounded edges.
class RoundQrCode extends StatelessWidget {
  const RoundQrCode({
    super.key,
    required this.data,
    this.size = 168,
    this.color = const Color(0xFF09090B),
    this.semanticsLabel,
  });

  final String data;
  final double size;
  final Color color;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.Q),
    );
    return Semantics(
      label: semanticsLabel,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _RoundQrPainter(image, color),
      ),
    );
  }
}

@visibleForTesting
List<(int, int)> qrAlignmentCenters(int version, int n) => _RoundQrPainter.alignmentCenters(version, n);

class _RoundQrPainter extends CustomPainter {
  _RoundQrPainter(this.image, this.color);

  final QrImage image;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final m = size.shortestSide / n;
    final fill = Paint()..color = color;

    final alignments = alignmentCenters(image.typeNumber, n);
    bool marker(int r, int c) =>
        (r < 7 && c < 7) ||
        (r < 7 && c >= n - 7) ||
        (r >= n - 7 && c < 7) ||
        alignments.any((a) => (a.$1 - r).abs() <= 2 && (a.$2 - c).abs() <= 2);
    bool dark(int r, int c) =>
        r >= 0 && c >= 0 && r < n && c < n && !marker(r, c) && image.isDark(r, c);

    final radius = m * 0.43;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (!dark(r, c)) continue;
        final center = Offset((c + 0.5) * m, (r + 0.5) * m);
        canvas.drawCircle(center, radius, fill);
        // Joined to the right and below: rounded lines.
        if (dark(r, c + 1)) {
          canvas.drawRect(
            Rect.fromLTRB(center.dx, center.dy - radius, center.dx + m, center.dy + radius),
            fill,
          );
        }
        if (dark(r + 1, c)) {
          canvas.drawRect(
            Rect.fromLTRB(center.dx - radius, center.dy, center.dx + radius, center.dy + m),
            fill,
          );
        }
      }
    }

    // Corner markers: a ring one module wide, a gap, a three-module dot.
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = m;
    for (final (r, c) in [(0, 0), (0, n - 7), (n - 7, 0)]) {
      final center = Offset((c + 3.5) * m, (r + 3.5) * m);
      canvas.drawCircle(center, 3 * m, ring);
      canvas.drawCircle(center, 1.5 * m, fill);
    }
    // Alignment markers (larger codes): a ring, a gap, a dot.
    for (final (r, c) in alignments) {
      final center = Offset((c + 0.5) * m, (r + 0.5) * m);
      canvas.drawCircle(center, 2 * m, ring);
      canvas.drawCircle(center, 0.5 * m, fill);
    }
  }

  /// Centres of the alignment patterns of QR version [version] (size [n]).
  @visibleForTesting
  static List<(int, int)> alignmentCenters(int version, int n) {
    if (version < 2) return const [];
    final count = version ~/ 7 + 2;
    final step = version == 32 ? 26 : (version * 4 + count * 2 + 1) ~/ (count * 2 - 2) * 2;
    final positions = [6];
    for (var pos = n - 7; positions.length < count; pos -= step) {
      positions.insert(1, pos);
    }
    return [
      for (final r in positions)
        for (final c in positions)
          // Not where the corner markers are.
          if (!((r == 6 && c == 6) || (r == 6 && c == n - 7) || (r == n - 7 && c == 6))) (r, c),
    ];
  }

  @override
  bool shouldRepaint(_RoundQrPainter old) => old.image != image || old.color != color;
}
