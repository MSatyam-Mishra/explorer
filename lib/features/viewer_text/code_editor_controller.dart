import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Token colours for the editor, derived from light/dark mode.
class CodeTheme {
  const CodeTheme({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.type,
    required this.tag,
    required this.match,
    required this.currentMatch,
  });

  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
  final Color type;
  final Color tag;
  final Color match;
  final Color currentMatch;

  static CodeTheme of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const CodeTheme(
            keyword: Color(0xFFC792EA),
            string: Color(0xFFC3E88D),
            comment: Color(0xFF7F8C98),
            number: Color(0xFFF78C6C),
            type: Color(0xFFFFCB6B),
            tag: Color(0xFF82AAFF),
            match: Color(0x66FFEB3B),
            currentMatch: Color(0xCCFF9800),
          )
        : const CodeTheme(
            keyword: Color(0xFF8E24AA),
            string: Color(0xFF2E7D32),
            comment: Color(0xFF78909C),
            number: Color(0xFFD84315),
            type: Color(0xFFB8860B),
            tag: Color(0xFF1565C0),
            match: Color(0x80FFEB3B),
            currentMatch: Color(0xCCFFA726),
          );
  }
}

enum _Token { keyword, string, comment, number, type, tag }

/// A small regex-based highlighter covering the common language families.
/// It favours speed and robustness over perfect accuracy.
class SyntaxLanguage {
  SyntaxLanguage._(this.name, this._rules);

  final String name;
  final List<(RegExp, _Token)> _rules;

  static const _cKeywords =
      'abstract|as|async|await|break|case|catch|class|const|continue|default|'
      'defer|delete|do|else|enum|export|extends|extension|external|factory|'
      'false|final|finally|fn|for|from|func|function|get|go|if|impl|implements|'
      'import|in|instanceof|interface|is|late|let|match|mixin|mod|module|move|'
      'mut|namespace|new|null|nil|operator|override|package|private|protected|'
      'pub|public|required|return|sealed|set|static|struct|super|switch|this|'
      'throw|throws|trait|true|try|type|typeof|typedef|use|using|val|var|void|'
      'when|where|while|with|yield|fun|object|companion|data|inline|virtual|'
      'unsigned|signed|char|int|long|short|float|double|bool|boolean|string|'
      'String|auto|goto|register|volatile|sizeof|template|typename|readonly|'
      'declare|keyof|satisfies|undefined|elif|lambda|pass|def|None|True|False|'
      'and|or|not|del|global|nonlocal|assert|raise|except|print|self';

  static final _doubleString = RegExp(r'"(?:[^"\\\n]|\\.)*"');
  static final _singleString = RegExp(r"'(?:[^'\\\n]|\\.)*'");
  static final _backtickString = RegExp(r'`(?:[^`\\]|\\.)*`');
  static final _tripleString = RegExp(r'"""[\s\S]*?"""|' r"'''[\s\S]*?'''");
  static final _number =
      RegExp(r'\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b');
  static final _blockComment = RegExp(r'/\*[\s\S]*?\*/');
  static final _lineComment = RegExp(r'//[^\n]*');
  static final _hashComment = RegExp(r'#[^\n]*');
  static final _typeName = RegExp(r'\b[A-Z][A-Za-z0-9_]*\b');

  static SyntaxLanguage? forExtension(String ext) {
    switch (ext) {
      case 'dart' || 'js' || 'mjs' || 'cjs' || 'jsx' || 'ts' || 'tsx' ||
            'java' || 'kt' || 'kts' || 'scala' || 'groovy' || 'gradle' ||
            'swift' || 'go' || 'rs' || 'c' || 'h' || 'cc' || 'cpp' || 'cxx' ||
            'hpp' || 'hh' || 'hxx' || 'cs' || 'm' || 'mm' || 'php' || 'zig' ||
            'v' || 'd' || 'proto' || 'json5' || 'jsonc' || 'vue' || 'svelte':
        return SyntaxLanguage._('C-like', [
          (_blockComment, _Token.comment),
          (_lineComment, _Token.comment),
          (_tripleString, _Token.string),
          (_doubleString, _Token.string),
          (_singleString, _Token.string),
          (_backtickString, _Token.string),
          (RegExp('\\b(?:$_cKeywords)\\b'), _Token.keyword),
          (RegExp(r'@\w+'), _Token.tag),
          (_typeName, _Token.type),
          (_number, _Token.number),
        ]);
      case 'py' || 'pyw' || 'pyi' || 'rb' || 'sh' || 'bash' || 'zsh' ||
            'fish' || 'pl' || 'pm' || 'r' || 'jl' || 'ex' || 'exs' ||
            'nim' || 'tcl' || 'awk' || 'coffee' || 'cmake' || 'make' || 'mk' ||
            'mak' || 'dockerfile' || 'nix' || 'tf' || 'hcl' || 'ps1' ||
            'psm1' || 'toml' || 'conf' || 'cfg' || 'env' || 'properties' ||
            'desktop' || 'service' || 'editorconfig' || 'gitignore' ||
            'gitattributes' || 'npmrc':
        return SyntaxLanguage._('Script', [
          (_tripleString, _Token.string),
          (_hashComment, _Token.comment),
          (_doubleString, _Token.string),
          (_singleString, _Token.string),
          (RegExp('\\b(?:$_cKeywords|then|fi|esac|done|elsif|unless|end|'
                  'begin|rescue|ensure|require|echo|local|export|function|'
                  'param|foreach)\\b'), _Token.keyword),
          (RegExp(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?'), _Token.tag),
          (RegExp(r'^\s*\[[^\]\n]+\]', multiLine: true), _Token.type),
          (_number, _Token.number),
        ]);
      case 'lua' || 'sql' || 'hs' || 'elm':
        return SyntaxLanguage._('SQL/Lua', [
          (RegExp(r'--[^\n]*'), _Token.comment),
          (_blockComment, _Token.comment),
          (_doubleString, _Token.string),
          (_singleString, _Token.string),
          (
            RegExp(
              r'\b(?:select|from|where|insert|into|values|update|set|delete|'
              r'create|table|drop|alter|index|join|left|right|inner|outer|on|'
              r'group|by|order|having|limit|offset|as|and|or|not|null|is|in|'
              r'like|between|case|when|then|else|end|distinct|union|all|'
              r'primary|key|foreign|references|default|local|function|return|'
              r'if|elseif|for|while|do|repeat|until|nil|true|false|module|'
              r'import|where|let|data|type|class|instance|deriving)\b',
              caseSensitive: false,
            ),
            _Token.keyword
          ),
          (_number, _Token.number),
        ]);
      case 'html' || 'htm' || 'xhtml' || 'xml' || 'xsd' || 'xsl' || 'xslt' ||
            'svg' || 'plist' || 'opml' || 'rss' || 'atom' || 'kml' || 'gpx' ||
            'xaml' || 'csproj' || 'vcxproj':
        return SyntaxLanguage._('Markup', [
          (RegExp(r'<!--[\s\S]*?-->'), _Token.comment),
          (RegExp(r'<!\[CDATA\[[\s\S]*?\]\]>'), _Token.string),
          (_doubleString, _Token.string),
          (_singleString, _Token.string),
          (RegExp(r'</?[A-Za-z][\w:.-]*|/?>|<\?[\w:-]*|\?>'), _Token.tag),
          (RegExp(r'\b[\w:-]+(?==)'), _Token.type),
          (RegExp(r'&[#\w]+;'), _Token.keyword),
        ]);
      case 'css' || 'scss' || 'sass' || 'less':
        return SyntaxLanguage._('CSS', [
          (_blockComment, _Token.comment),
          (_lineComment, _Token.comment),
          (_doubleString, _Token.string),
          (_singleString, _Token.string),
          (RegExp(r'[.#][A-Za-z_-][\w-]*'), _Token.type),
          (RegExp(r'[\w-]+(?=\s*:)'), _Token.keyword),
          (RegExp(r'@[\w-]+|\$[\w-]+'), _Token.tag),
          (RegExp(r'#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b'),
              _Token.number),
        ]);
      case 'json' || 'geojson' || 'har' || 'ipynb' || 'arb' || 'lock':
        return SyntaxLanguage._('JSON', [
          (RegExp(r'"(?:[^"\\\n]|\\.)*"(?=\s*:)'), _Token.tag),
          (_doubleString, _Token.string),
          (RegExp(r'\b(?:true|false|null)\b'), _Token.keyword),
          (RegExp(r'-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b'), _Token.number),
        ]);
      case 'yaml' || 'yml':
        return SyntaxLanguage._('YAML', [
          (_hashComment, _Token.comment),
          (_doubleString, _Token.string),
          (_singleString, _Token.string),
          (RegExp(r'^[ \t-]*[\w.\-/ ]+(?=:(?:\s|$))', multiLine: true), _Token.tag),
          (RegExp(r'\b(?:true|false|null|yes|no|on|off)\b'), _Token.keyword),
          (RegExp(r'[&*][\w-]+|!![\w]+'), _Token.type),
          (_number, _Token.number),
        ]);
      case 'ini' || 'reg' || 'cfg_ini':
        return SyntaxLanguage._('INI', [
          (RegExp(r'^\s*[;#][^\n]*', multiLine: true), _Token.comment),
          (RegExp(r'^\s*\[[^\]\n]+\]', multiLine: true), _Token.type),
          (RegExp(r'^\s*[^=\n]+(?==)', multiLine: true), _Token.tag),
          (_doubleString, _Token.string),
        ]);
      case 'md' || 'markdown' || 'mdown' || 'mkd' || 'mdx':
        return SyntaxLanguage._('Markdown', [
          (RegExp(r'```[\s\S]*?```'), _Token.string),
          (RegExp(r'`[^`\n]+`'), _Token.string),
          (RegExp(r'^#{1,6} [^\n]*', multiLine: true), _Token.keyword),
          (RegExp(r'\*\*[^*\n]+\*\*|__[^_\n]+__'), _Token.type),
          (RegExp(r'!?\[[^\]\n]*\]\([^)\n]*\)'), _Token.tag),
          (RegExp(r'^\s*(?:[-*+]|\d+\.) ', multiLine: true), _Token.number),
          (RegExp(r'^>[^\n]*', multiLine: true), _Token.comment),
        ]);
      case 'diff' || 'patch':
        return SyntaxLanguage._('Diff', [
          (RegExp(r'^\+[^\n]*', multiLine: true), _Token.string),
          (RegExp(r'^-[^\n]*', multiLine: true), _Token.number),
          (RegExp(r'^@@[^\n]*', multiLine: true), _Token.tag),
          (RegExp(r'^(?:diff|index|---|\+\+\+)[^\n]*', multiLine: true), _Token.keyword),
        ]);
      case 'csv' || 'tsv':
        return null;
      default:
        return null;
    }
  }

  /// Non-overlapping token ranges, earliest rule wins on ties.
  List<(int, int, _Token)> tokenize(String text) {
    final hits = <(int, int, _Token, int)>[];
    for (var r = 0; r < _rules.length; r++) {
      final (regex, token) = _rules[r];
      for (final m in regex.allMatches(text)) {
        if (m.end > m.start) hits.add((m.start, m.end, token, r));
      }
    }
    hits.sort((a, b) {
      final byStart = a.$1.compareTo(b.$1);
      return byStart != 0 ? byStart : a.$4.compareTo(b.$4);
    });
    final result = <(int, int, _Token)>[];
    var cursor = 0;
    for (final h in hits) {
      if (h.$1 < cursor) continue;
      result.add((h.$1, h.$2, h.$3));
      cursor = h.$2;
    }
    return result;
  }
}

/// TextEditingController that paints syntax colours and search matches.
class CodeEditorController extends TextEditingController {
  CodeEditorController({super.text, this.language});

  SyntaxLanguage? language;
  CodeTheme? theme;

  /// Highlighting is skipped above this size to keep typing responsive.
  static const highlightLimit = 200 * 1024;

  List<TextRange> _matches = const [];
  int _currentMatch = -1;

  List<TextRange> get matches => _matches;
  int get currentMatch => _currentMatch;

  String? _cachedText;
  List<(int, int, _Token)> _cachedTokens = const [];

  void setMatches(List<TextRange> matches, int current) {
    // Listeners re-run searches; never notify for a no-op update.
    if (current == _currentMatch && listEquals(matches, _matches)) return;
    _matches = matches;
    _currentMatch = current;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final t = theme;
    final lang = language;
    final composing = value.composing;
    final hasComposing = withComposing &&
        value.isComposingRangeValid &&
        !composing.isCollapsed;
    if (t == null ||
        hasComposing ||
        text.length > highlightLimit ||
        (lang == null && _matches.isEmpty)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    if (_cachedText != text) {
      _cachedText = text;
      _cachedTokens = lang?.tokenize(text) ?? const [];
    }

    // Boundaries where either a token or a search match starts/ends.
    final spans = <TextSpan>[];
    final boundaries = <int>{0, text.length};
    for (final tok in _cachedTokens) {
      boundaries..add(tok.$1)..add(tok.$2);
    }
    for (final m in _matches) {
      boundaries..add(m.start)..add(m.end);
    }
    final points = boundaries.where((b) => b <= text.length).toList()..sort();

    var tokenIndex = 0;
    var matchIndex = 0;
    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i], end = points[i + 1];
      if (start == end) continue;
      while (tokenIndex < _cachedTokens.length &&
          _cachedTokens[tokenIndex].$2 <= start) {
        tokenIndex++;
      }
      while (matchIndex < _matches.length && _matches[matchIndex].end <= start) {
        matchIndex++;
      }
      Color? fg;
      if (tokenIndex < _cachedTokens.length &&
          _cachedTokens[tokenIndex].$1 <= start) {
        fg = switch (_cachedTokens[tokenIndex].$3) {
          _Token.keyword => t.keyword,
          _Token.string => t.string,
          _Token.comment => t.comment,
          _Token.number => t.number,
          _Token.type => t.type,
          _Token.tag => t.tag,
        };
      }
      Color? bg;
      if (matchIndex < _matches.length && _matches[matchIndex].start <= start) {
        bg = matchIndex == _currentMatch ? t.currentMatch : t.match;
      }
      spans.add(TextSpan(
        text: text.substring(start, end),
        style: fg == null && bg == null
            ? null
            : TextStyle(
                color: fg,
                backgroundColor: bg,
                fontStyle: fg == t.comment ? FontStyle.italic : null,
              ),
      ));
    }
    return TextSpan(style: style, children: spans);
  }
}
