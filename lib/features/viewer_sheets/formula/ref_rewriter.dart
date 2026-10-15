import '../model/cell.dart';
import 'tokenizer.dart';

/// Rewrites cell references inside formula text.
abstract final class FormulaRefs {
  /// Replaces every reference token using [map] (return null to keep it).
  static String rewrite(String formula, String? Function(RefInfo ref) map) {
    List<FToken> toks;
    try {
      toks = tokenizeFormula(formula);
    } on FormulaSyntaxError {
      return formula;
    }
    final b = StringBuffer();
    var pos = 0;
    var changed = false;
    for (final t in toks) {
      if (t.type != FTokType.ref) continue;
      final replacement = map(t.ref!.copy());
      if (replacement == null) continue;
      b.write(formula.substring(pos, t.start));
      b.write(replacement);
      pos = t.end;
      changed = true;
    }
    if (!changed) return formula;
    b.write(formula.substring(pos));
    return b.toString();
  }

  /// Shifts relative references by (dRow, dCol), as when copying a formula.
  static String shift(String formula, int dRow, int dCol) {
    if (dRow == 0 && dCol == 0) return formula;
    return rewrite(formula, (r) {
      var bad = false;
      int mv(int v, bool abs, int d, int max) {
        if (abs) return v;
        final n = v + d;
        if (n < 0 || n >= max) bad = true;
        return n;
      }

      switch (r.kind) {
        case RefKind.cell:
          r.r1 = mv(r.r1, r.absR1, dRow, kMaxRows);
          r.c1 = mv(r.c1, r.absC1, dCol, kMaxCols);
        case RefKind.area:
          r.r1 = mv(r.r1, r.absR1, dRow, kMaxRows);
          r.c1 = mv(r.c1, r.absC1, dCol, kMaxCols);
          r.r2 = mv(r.r2, r.absR2, dRow, kMaxRows);
          r.c2 = mv(r.c2, r.absC2, dCol, kMaxCols);
        case RefKind.cols:
          r.c1 = mv(r.c1, r.absC1, dCol, kMaxCols);
          r.c2 = mv(r.c2, r.absC2, dCol, kMaxCols);
        case RefKind.rows:
          r.r1 = mv(r.r1, r.absR1, dRow, kMaxRows);
          r.r2 = mv(r.r2, r.absR2, dRow, kMaxRows);
      }
      if (bad) return '#REF!';
      return r.format();
    });
  }

  /// Adjusts references after inserting ([delta] > 0) or deleting
  /// ([delta] < 0) rows (or columns when [rows] is false) at [at] on
  /// [targetSheet]. [formulaSheet] is the sheet holding the formula.
  static String insertDelete(
    String formula, {
    required String formulaSheet,
    required String targetSheet,
    required bool rows,
    required int at,
    required int delta,
  }) {
    final target = targetSheet.toLowerCase();
    final own = formulaSheet.toLowerCase();
    return rewrite(formula, (r) {
      final sheet = (r.sheet ?? formulaSheet).toLowerCase();
      if (sheet != target && !(r.sheet == null && own == target)) return null;
      if (rows && r.kind == RefKind.cols) return null;
      if (!rows && r.kind == RefKind.rows) return null;

      int a1 = rows ? r.r1 : r.c1;
      int a2 = rows
          ? (r.kind == RefKind.cell ? r.r1 : r.r2)
          : (r.kind == RefKind.cell ? r.c1 : r.c2);
      if (delta > 0) {
        if (a1 >= at) a1 += delta;
        if (a2 >= at) a2 += delta;
        final max = rows ? kMaxRows : kMaxCols;
        if (a1 >= max) return '#REF!';
        if (a2 >= max) a2 = max - 1;
      } else {
        final k = -delta;
        final end = at + k;
        if (r.kind == RefKind.cell) {
          if (a1 >= at && a1 < end) return '#REF!';
          if (a1 >= end) a1 -= k;
          a2 = a1;
        } else {
          final n1 = a1 >= end ? a1 - k : (a1 >= at ? at : a1);
          final n2 = a2 >= end ? a2 - k : (a2 >= at ? at - 1 : a2);
          if (n2 < n1) return '#REF!';
          a1 = n1;
          a2 = n2;
        }
      }
      if (rows) {
        r.r1 = a1;
        if (r.kind != RefKind.cell) r.r2 = a2;
      } else {
        r.c1 = a1;
        if (r.kind != RefKind.cell) r.c2 = a2;
      }
      return r.format();
    });
  }

  /// Updates sheet prefixes after a sheet rename.
  static String renameSheet(String formula, String oldName, String newName) {
    final lower = oldName.toLowerCase();
    return rewrite(formula, (r) {
      if (r.sheet == null || r.sheet!.toLowerCase() != lower) return null;
      r.sheet = newName;
      return r.format();
    });
  }

  /// Turns references to a deleted sheet into `#REF!`.
  static String deleteSheet(String formula, String name) {
    final lower = name.toLowerCase();
    return rewrite(formula, (r) {
      if (r.sheet == null || r.sheet!.toLowerCase() != lower) return null;
      return '#REF!';
    });
  }

  /// Makes references to the formula's own sheet explicit (used when a
  /// formula is copied to another sheet... not needed for in-sheet moves).
  static String qualify(String formula, String sheet) {
    return rewrite(formula, (r) {
      if (r.sheet != null) return null;
      r.sheet = sheet;
      return r.format();
    });
  }
}
