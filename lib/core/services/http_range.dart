import 'dart:math';

/// Returned by [parseByteRange] when the range can't be satisfied (416).
const unsatisfiableRange = (-1, -1);

/// Parses a single-range `Range: bytes=...` header into `[start, end)`.
/// Returns null to ignore the header (malformed or multi-range: the whole
/// file is sent, as HTTP allows) and [unsatisfiableRange] for 416.
(int, int)? parseByteRange(String header, int length) {
  final value = header.trim();
  if (!value.startsWith('bytes=') || value.contains(',')) return null;
  final spec = value.substring(6).trim();
  final dash = spec.indexOf('-');
  if (dash < 0) return null;
  final first = spec.substring(0, dash).trim();
  final last = spec.substring(dash + 1).trim();
  if (first.isEmpty) {
    // Suffix range: the last N bytes.
    final n = int.tryParse(last);
    if (n == null) return null;
    if (n <= 0 || length == 0) return unsatisfiableRange;
    return (max(0, length - n), length);
  }
  final start = int.tryParse(first);
  if (start == null || start < 0) return null;
  if (start >= length) return unsatisfiableRange;
  if (last.isEmpty) return (start, length);
  final stop = int.tryParse(last);
  if (stop == null || stop < start) return null;
  return (start, min(stop + 1, length));
}
