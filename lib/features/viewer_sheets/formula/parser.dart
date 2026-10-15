import '../model/cell.dart';
import 'tokenizer.dart';

/// Formula syntax tree.
sealed class FNode {
  const FNode();
}

class NumNode extends FNode {
  const NumNode(this.value);
  final double value;
}

class StrNode extends FNode {
  const StrNode(this.value);
  final String value;
}

class BoolNode extends FNode {
  const BoolNode(this.value);
  final bool value;
}

class ErrNode extends FNode {
  const ErrNode(this.error);
  final CellError error;
}

class RefNode extends FNode {
  const RefNode(this.ref);
  final RefInfo ref;
}

class FuncNode extends FNode {
  const FuncNode(this.name, this.args);

  /// Upper-case, without `_xlfn.` style prefixes.
  final String name;
  final List<FNode> args;
}

class UnaryNode extends FNode {
  const UnaryNode(this.op, this.operand);
  final String op;
  final FNode operand;
}

class BinNode extends FNode {
  const BinNode(this.op, this.left, this.right);
  final String op;
  final FNode left;
  final FNode right;
}

class PercentNode extends FNode {
  const PercentNode(this.operand);
  final FNode operand;
}

class RangeOpNode extends FNode {
  const RangeOpNode(this.left, this.right);
  final FNode left;
  final FNode right;
}

class NameNode extends FNode {
  const NameNode(this.name);
  final String name;
}

class MissingNode extends FNode {
  const MissingNode();
}

class ArrayNode extends FNode {
  const ArrayNode(this.rows);
  final List<List<FNode>> rows;
}

/// Parses formula text (without `=`). Throws [FormulaSyntaxError].
FNode parseFormula(String text) => _Parser(tokenizeFormula(text)).parseAll();

class _Parser {
  _Parser(this.toks);

  final List<FToken> toks;
  int pos = 0;

  FToken? get peek => pos < toks.length ? toks[pos] : null;

  FToken next() {
    if (pos >= toks.length) throw FormulaSyntaxError('Unexpected end of formula');
    return toks[pos++];
  }

  bool peekOp(String op) {
    final t = peek;
    return t != null && t.type == FTokType.op && t.text == op;
  }

  FNode parseAll() {
    if (toks.isEmpty) throw FormulaSyntaxError('Empty formula');
    final n = parseExpr();
    if (pos < toks.length) {
      throw FormulaSyntaxError('Unexpected "${toks[pos].text}"');
    }
    return n;
  }

  FNode parseExpr() => parseComparison();

  FNode parseComparison() {
    var left = parseConcat();
    while (true) {
      final t = peek;
      if (t != null &&
          t.type == FTokType.op &&
          const ['=', '<>', '<', '>', '<=', '>='].contains(t.text)) {
        pos++;
        left = BinNode(t.text, left, parseConcat());
      } else {
        return left;
      }
    }
  }

  FNode parseConcat() {
    var left = parseAdditive();
    while (peekOp('&')) {
      pos++;
      left = BinNode('&', left, parseAdditive());
    }
    return left;
  }

  FNode parseAdditive() {
    var left = parseMultiplicative();
    while (peekOp('+') || peekOp('-')) {
      final op = next().text;
      left = BinNode(op, left, parseMultiplicative());
    }
    return left;
  }

  FNode parseMultiplicative() {
    var left = parsePower();
    while (peekOp('*') || peekOp('/')) {
      final op = next().text;
      left = BinNode(op, left, parsePower());
    }
    return left;
  }

  FNode parsePower() {
    var left = parsePercent();
    while (peekOp('^')) {
      pos++;
      left = BinNode('^', left, parsePercent());
    }
    return left;
  }

  FNode parsePercent() {
    var e = parseUnary();
    while (peekOp('%')) {
      pos++;
      e = PercentNode(e);
    }
    return e;
  }

  FNode parseUnary() {
    if (peekOp('-') || peekOp('+')) {
      final op = next().text;
      return UnaryNode(op, parseUnary());
    }
    return parseRange();
  }

  FNode parseRange() {
    var left = parsePrimary();
    while (peekOp(':')) {
      pos++;
      left = RangeOpNode(left, parsePrimary());
    }
    return left;
  }

  FNode parsePrimary() {
    final t = next();
    switch (t.type) {
      case FTokType.number:
        return NumNode(double.parse(t.text));
      case FTokType.string:
        return StrNode(t.text);
      case FTokType.boolean:
        return BoolNode(t.text == 'TRUE');
      case FTokType.error:
        return ErrNode(CellError(t.text));
      case FTokType.ref:
        return RefNode(t.ref!);
      case FTokType.name:
        return NameNode(t.text);
      case FTokType.func:
        final name = normalizeFunctionName(t.text);
        final lp = next();
        if (lp.type != FTokType.lparen) throw FormulaSyntaxError('Expected (');
        final args = <FNode>[];
        if (peek?.type == FTokType.rparen) {
          pos++;
          return FuncNode(name, args);
        }
        while (true) {
          final p = peek;
          if (p == null) throw FormulaSyntaxError('Missing )');
          if (p.type == FTokType.comma || p.type == FTokType.rparen) {
            args.add(const MissingNode());
          } else {
            args.add(parseExpr());
          }
          final sep = next();
          if (sep.type == FTokType.rparen) break;
          if (sep.type != FTokType.comma) {
            throw FormulaSyntaxError('Expected , or )');
          }
        }
        return FuncNode(name, args);
      case FTokType.lparen:
        final e = parseExpr();
        final rp = next();
        if (rp.type != FTokType.rparen) throw FormulaSyntaxError('Missing )');
        return e;
      case FTokType.lbrace:
        final rows = <List<FNode>>[<FNode>[]];
        while (true) {
          final p = next();
          if (p.type == FTokType.rbrace) break;
          if (p.type == FTokType.comma) {
            if (p.text == ';') rows.add(<FNode>[]);
            continue;
          }
          pos--;
          var neg = false;
          if (peekOp('-')) {
            pos++;
            neg = true;
          }
          final v = parsePrimary();
          rows.last.add(neg ? UnaryNode('-', v) : v);
        }
        return ArrayNode(rows);
      default:
        throw FormulaSyntaxError('Unexpected "${t.text}"');
    }
  }
}

/// Visits every reference node in [node].
void visitRefs(FNode node, void Function(RefInfo ref) visit) {
  switch (node) {
    case RefNode(:final ref):
      visit(ref);
    case FuncNode(:final args):
      for (final a in args) {
        visitRefs(a, visit);
      }
    case UnaryNode(:final operand):
      visitRefs(operand, visit);
    case PercentNode(:final operand):
      visitRefs(operand, visit);
    case BinNode(:final left, :final right):
      visitRefs(left, visit);
      visitRefs(right, visit);
    case RangeOpNode(:final left, :final right):
      visitRefs(left, visit);
      visitRefs(right, visit);
    case ArrayNode(:final rows):
      for (final r in rows) {
        for (final c in r) {
          visitRefs(c, visit);
        }
      }
    default:
      break;
  }
}

/// Visits every function call in [node].
void visitFuncs(FNode node, void Function(FuncNode f) visit) {
  switch (node) {
    case final FuncNode f:
      visit(f);
      for (final a in f.args) {
        visitFuncs(a, visit);
      }
    case UnaryNode(:final operand):
      visitFuncs(operand, visit);
    case PercentNode(:final operand):
      visitFuncs(operand, visit);
    case BinNode(:final left, :final right):
      visitFuncs(left, visit);
      visitFuncs(right, visit);
    case RangeOpNode(:final left, :final right):
      visitFuncs(left, visit);
      visitFuncs(right, visit);
    default:
      break;
  }
}
