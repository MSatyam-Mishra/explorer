import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/features/viewer_text/code_editor_controller.dart';
import 'package:explorer/features/viewer_text/text_document.dart';
import 'package:explorer/features/viewer_text/widgets/markdown_preview.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Editor for one plain-text/code file: line numbers, syntax colours,
/// find & replace, undo/redo, and Markdown preview. Encoding and line endings
/// are preserved on save.
class TextEditorPane extends StatefulWidget {
  const TextEditorPane({
    super.key,
    required this.file,
    this.onDirtyChanged,
    this.topPadding = 0,
  });

  final File file;
  final ValueChanged<bool>? onDirtyChanged;

  /// Space reserved above the content for the floating top bar.
  final double topPadding;

  @override
  State<TextEditorPane> createState() => TextEditorPaneState();
}

enum _MarkdownMode { edit, preview, split }

class TextEditorPaneState extends State<TextEditorPane> {
  static const _fontFamily = 'monospace';
  static const _fallbackFonts = ['Consolas', 'Menlo', 'Roboto Mono', 'Courier'];

  late final CodeEditorController _controller;
  final UndoHistoryController _undo = UndoHistoryController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();
  final ScrollController _gutterScroll = ScrollController();
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  TextDocument? _document;
  String? _error;
  bool _loading = true;
  bool _readOnly = false;
  bool _tooLarge = false;
  String _savedText = '';
  bool _dirty = false;

  late bool _wrap;
  double _fontSize = 14;
  bool _showFind = false;
  bool _showReplace = false;
  bool _caseSensitive = false;
  _MarkdownMode _mdMode = _MarkdownMode.edit;

  int _lineCount = 1;
  String _gutterText = '1';
  int _longestLine = 0;
  int _cursorLine = 1;
  int _cursorColumn = 1;

  late final String _ext = FileTypes.extensionOf(widget.file.path);
  late final FileKind _kind = FileTypes.kindOf(widget.file.path);
  bool get _isMarkdown => _kind == FileKind.markdown;
  bool get _isJson => _kind == FileKind.json || _ext == 'ipynb';

  bool get isDirty => _dirty;

  @override
  void initState() {
    super.initState();
    _wrap = _kind == FileKind.text || _isMarkdown;
    _controller = CodeEditorController(
      language: SyntaxLanguage.forExtension(_ext),
    );
    _controller.addListener(_onChanged);
    _vScroll.addListener(() {
      if (_gutterScroll.hasClients &&
          _gutterScroll.offset != _vScroll.offset) {
        _gutterScroll.jumpTo(
          _vScroll.offset.clamp(0, _gutterScroll.position.maxScrollExtent),
        );
      }
    });
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _undo.dispose();
    _focusNode.dispose();
    _vScroll.dispose();
    _hScroll.dispose();
    _gutterScroll.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final size = await widget.file.length();
      final doc = await TextDocument.load(widget.file);
      if (!mounted) return;
      _document = doc;
      _savedText = doc.text;
      _tooLarge = size > TextDocument.editableLimit;
      _readOnly = _tooLarge;
      _controller.value = TextEditingValue(text: doc.text);
      _recomputeLines();
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open this file as text.\n$e';
        _loading = false;
      });
    }
  }

  void _onChanged() {
    final text = _controller.text;
    final dirty = text != _savedText;
    if (dirty != _dirty) {
      _dirty = dirty;
      widget.onDirtyChanged?.call(dirty);
    }
    final lines = '\n'.allMatches(text).length + 1;
    if (lines != _lineCount) _recomputeLines();
    final sel = _controller.selection;
    if (sel.isValid) {
      final before = text.substring(0, math.min(sel.extentOffset, text.length));
      final lastBreak = before.lastIndexOf('\n');
      _cursorLine = '\n'.allMatches(before).length + 1;
      _cursorColumn = before.length - lastBreak;
    }
    if (_showFind) _runSearch(keepIndex: true);
    if (mounted) setState(() {});
  }

  void _recomputeLines() {
    final text = _controller.text;
    var count = 1, longest = 0, current = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        count++;
        longest = math.max(longest, current);
        current = 0;
      } else {
        current++;
      }
    }
    _longestLine = math.max(longest, current);
    _lineCount = count;
    _gutterText = List.generate(count, (i) => '${i + 1}').join('\n');
  }

  /// Writes the file; returns false (and shows why) on failure.
  Future<bool> save() async {
    final doc = _document;
    if (doc == null || _readOnly) return false;
    try {
      await widget.file.writeAsBytes(doc.encode(_controller.text), flush: true);
      _savedText = _controller.text;
      _dirty = false;
      widget.onDirtyChanged?.call(false);
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
      return false;
    }
  }

  // ---- Search ------------------------------------------------------------

  void toggleFind({bool replace = false}) {
    setState(() {
      if (_showFind && _showReplace == replace) {
        _showFind = false;
        _controller.setMatches(const [], -1);
      } else {
        _showFind = true;
        _showReplace = replace;
        final sel = _controller.selection;
        if (sel.isValid && !sel.isCollapsed) {
          _findController.text = sel.textInside(_controller.text);
        }
        _runSearch();
      }
    });
  }

  void _runSearch({bool keepIndex = false}) {
    final query = _findController.text;
    if (query.isEmpty) {
      _controller.setMatches(const [], -1);
      return;
    }
    final haystack = _caseSensitive ? _controller.text : _controller.text.toLowerCase();
    final needle = _caseSensitive ? query : query.toLowerCase();
    final matches = <TextRange>[];
    var from = 0;
    while (matches.length < 10000) {
      final i = haystack.indexOf(needle, from);
      if (i < 0) break;
      matches.add(TextRange(start: i, end: i + needle.length));
      from = i + math.max(1, needle.length);
    }
    var current = keepIndex ? _controller.currentMatch : 0;
    if (current >= matches.length) current = matches.isEmpty ? -1 : 0;
    if (matches.isEmpty) current = -1;
    _controller.setMatches(matches, current);
    if (!keepIndex && current >= 0) _revealOffset(matches[current].start);
  }

  void _gotoMatch(int delta) {
    final matches = _controller.matches;
    if (matches.isEmpty) return;
    final next = (_controller.currentMatch + delta) % matches.length;
    _controller.setMatches(matches, next < 0 ? next + matches.length : next);
    final m = matches[_controller.currentMatch];
    _controller.selection = TextSelection(baseOffset: m.start, extentOffset: m.end);
    _revealOffset(m.start);
  }

  void _replaceCurrent() {
    final matches = _controller.matches;
    final i = _controller.currentMatch;
    if (_readOnly || i < 0 || i >= matches.length) return;
    final m = matches[i];
    final replacement = _replaceController.text;
    _controller.value = TextEditingValue(
      text: _controller.text.replaceRange(m.start, m.end, replacement),
      selection: TextSelection.collapsed(offset: m.start + replacement.length),
    );
    _runSearch(keepIndex: true);
  }

  void _replaceAll() {
    final query = _findController.text;
    if (_readOnly || query.isEmpty) return;
    final pattern = RegExp(RegExp.escape(query), caseSensitive: _caseSensitive);
    final count = pattern.allMatches(_controller.text).length;
    _controller.value = TextEditingValue(
      text: _controller.text.replaceAll(pattern, _replaceController.text),
    );
    _runSearch();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Replaced $count occurrence${count == 1 ? '' : 's'}')),
    );
  }

  TextStyle get _textStyle => TextStyle(
        fontFamily: _fontFamily,
        fontFamilyFallback: _fallbackFonts,
        fontSize: _fontSize,
        height: 1.45,
        color: Theme.of(context).colorScheme.onSurface,
      );

  StrutStyle get _strut => StrutStyle(
        fontFamily: _fontFamily,
        fontFamilyFallback: _fallbackFonts,
        fontSize: _fontSize,
        height: 1.45,
        forceStrutHeight: true,
      );

  double get _lineHeight => _fontSize * 1.45;

  double _charWidth() {
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: _textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  /// Scrolls so the line containing [offset] is visible.
  void _revealOffset(int offset) {
    if (!_vScroll.hasClients) return;
    final text = _controller.text;
    double y;
    if (_wrap) {
      final width = (context.size?.width ?? 400) - 32;
      final painter = TextPainter(
        text: TextSpan(text: text, style: _textStyle),
        strutStyle: _strut,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      y = painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy;
    } else {
      final line = '\n'.allMatches(text.substring(0, offset)).length;
      y = line * _lineHeight;
      if (_hScroll.hasClients) {
        final col = offset - (text.lastIndexOf('\n', math.max(0, offset - 1)) + 1);
        final x = col * _charWidth();
        final viewport = _hScroll.position.viewportDimension;
        if (x < _hScroll.offset || x > _hScroll.offset + viewport - 40) {
          _hScroll.jumpTo((x - viewport / 3).clamp(0, _hScroll.position.maxScrollExtent));
        }
      }
    }
    final viewport = _vScroll.position.viewportDimension;
    final target = (y - viewport / 3).clamp(0.0, _vScroll.position.maxScrollExtent);
    _vScroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  // ---- Commands ----------------------------------------------------------

  void _insertText(String insert) {
    if (_readOnly) return;
    final value = _controller.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(sel.start, sel.end, insert),
      selection: TextSelection.collapsed(offset: sel.start + insert.length),
    );
  }

  void _formatJson() {
    try {
      final decoded = jsonDecode(_controller.text);
      _controller.value = TextEditingValue(
        text: '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
      );
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid JSON: ${e.message}')),
      );
    }
  }

  void _showInfo() {
    final doc = _document;
    final text = _controller.text;
    final words = RegExp(r'\S+').allMatches(text).length;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Document info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lines: $_lineCount'),
            Text('Words: $words'),
            Text('Characters: ${text.length}'),
            if (doc != null) Text('Encoding: ${doc.encodingLabel}'),
            if (doc != null) Text('Line endings: ${doc.lineEnding.label}'),
            if (_controller.language != null)
              Text('Highlighting: ${_controller.language!.name}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    _controller.theme = CodeTheme.of(context);

    final wide = AdaptiveSplitView.isSplit(context);
    final mdMode = _isMarkdown && _mdMode == _MarkdownMode.split && !wide
        ? _MarkdownMode.preview
        : _mdMode;

    Widget content;
    if (_isMarkdown && mdMode == _MarkdownMode.preview) {
      content = MarkdownPreview(markdown: _controller.text, file: widget.file);
    } else if (_isMarkdown && mdMode == _MarkdownMode.split) {
      content = Row(
        children: [
          Expanded(child: _buildEditor()),
          const VerticalDivider(width: 1),
          Expanded(
            child: MarkdownPreview(markdown: _controller.text, file: widget.file),
          ),
        ],
      );
    } else {
      content = _buildEditor();
    }

    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding),
      child: Column(
        children: [
          _buildToolbar(wide),
          if (_tooLarge && _readOnly) _buildLargeFileBanner(),
          if (_showFind) _buildFindBar(),
          const Divider(height: 1),
          Expanded(child: content),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildToolbar(bool wide) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          ValueListenableBuilder<UndoHistoryValue>(
            valueListenable: _undo,
            builder: (context, value, _) => Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: 'Undo',
                  onPressed: value.canUndo && !_readOnly ? _undo.undo : null,
                ),
                IconButton(
                  icon: const Icon(Icons.redo),
                  tooltip: 'Redo',
                  onPressed: value.canRedo && !_readOnly ? _undo.redo : null,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find',
            isSelected: _showFind && !_showReplace,
            onPressed: () => toggleFind(),
          ),
          IconButton(
            icon: const Icon(Icons.find_replace),
            tooltip: 'Find and replace',
            isSelected: _showFind && _showReplace,
            onPressed: _readOnly ? null : () => toggleFind(replace: true),
          ),
          IconButton(
            icon: const Icon(Icons.wrap_text),
            tooltip: _wrap ? 'Disable word wrap' : 'Enable word wrap',
            isSelected: _wrap,
            onPressed: () => setState(() => _wrap = !_wrap),
          ),
          IconButton(
            icon: const Icon(Icons.text_decrease),
            tooltip: 'Smaller text',
            onPressed: _fontSize > 9
                ? () => setState(() => _fontSize -= 1)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            tooltip: 'Larger text',
            onPressed: _fontSize < 32
                ? () => setState(() => _fontSize += 1)
                : null,
          ),
          if (_isJson)
            IconButton(
              icon: const Icon(Icons.data_object),
              tooltip: 'Format JSON',
              onPressed: _readOnly ? null : _formatJson,
            ),
          if (_isMarkdown) ...[
            const SizedBox(width: 8),
            Center(
              child: SegmentedButton<_MarkdownMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  const ButtonSegment(
                    value: _MarkdownMode.edit,
                    icon: Icon(Icons.edit_note, size: 18),
                    tooltip: 'Edit',
                  ),
                  if (wide)
                    const ButtonSegment(
                      value: _MarkdownMode.split,
                      icon: Icon(Icons.vertical_split, size: 18),
                      tooltip: 'Edit and preview',
                    ),
                  const ButtonSegment(
                    value: _MarkdownMode.preview,
                    icon: Icon(Icons.visibility, size: 18),
                    tooltip: 'Preview',
                  ),
                ],
                selected: {
                  !wide && _mdMode == _MarkdownMode.split
                      ? _MarkdownMode.preview
                      : _mdMode,
                },
                onSelectionChanged: (s) => setState(() => _mdMode = s.first),
              ),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Document info',
            onPressed: _showInfo,
          ),
        ],
      ),
    );
  }

  Widget _buildLargeFileBanner() {
    return MaterialBanner(
      content: const Text(
        'Large file opened read-only for speed. Editing may be slow.',
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _readOnly = false),
          child: const Text('Edit anyway'),
        ),
      ],
    );
  }

  Widget _buildFindBar() {
    final matches = _controller.matches;
    final current = _controller.currentMatch;
    final label = _findController.text.isEmpty
        ? ''
        : matches.isEmpty
            ? 'No results'
            : '${current + 1}/${matches.length}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _findController,
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Find',
                    suffixText: label,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(_runSearch),
                  onSubmitted: (_) => _gotoMatch(1),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.text_fields,
                  color: _caseSensitive
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                tooltip: 'Match case',
                onPressed: () => setState(() {
                  _caseSensitive = !_caseSensitive;
                  _runSearch();
                }),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up),
                tooltip: 'Previous',
                onPressed: matches.isEmpty ? null : () => _gotoMatch(-1),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: 'Next',
                onPressed: matches.isEmpty ? null : () => _gotoMatch(1),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => toggleFind(replace: _showReplace),
              ),
            ],
          ),
          if (_showReplace)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replaceController,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Replace with',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: matches.isEmpty ? null : _replaceCurrent,
                    child: const Text('Replace'),
                  ),
                  TextButton(
                    onPressed: matches.isEmpty ? null : _replaceAll,
                    child: const Text('All'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    final scheme = Theme.of(context).colorScheme;
    final field = TextField(
      controller: _controller,
      undoController: _undo,
      focusNode: _focusNode,
      readOnly: _readOnly,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      style: _textStyle,
      strutStyle: _strut,
      scrollPhysics: const NeverScrollableScrollPhysics(),
      decoration: const InputDecoration.collapsed(hintText: ''),
    );
    final editable = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.tab): () => _insertText('  '),
      },
      child: field,
    );

    final showGutter = !_wrap;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutterWidth = showGutter
            ? 16 + '$_lineCount'.length * _charWidth()
            : 0.0;
        Widget editor;
        if (_wrap) {
          editor = Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
            child: editable,
          );
        } else {
          final contentWidth = math.max(
            constraints.maxWidth - gutterWidth,
            (_longestLine + 4) * _charWidth() + 32,
          );
          editor = Scrollbar(
            controller: _hScroll,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 16, 48),
                  child: editable,
                ),
              ),
            ),
          );
        }

        final body = Scrollbar(
          controller: _vScroll,
          child: SingleChildScrollView(
            controller: _vScroll,
            child: editor,
          ),
        );

        if (!showGutter) return GestureDetector(onTap: _focusNode.requestFocus, child: body);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: gutterWidth,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: ScrollConfiguration(
                behavior: const ScrollBehavior().copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  controller: _gutterScroll,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(4, 12, 8, 48),
                  child: Text(
                    _gutterText,
                    textAlign: TextAlign.right,
                    style: _textStyle.copyWith(color: scheme.outline),
                    strutStyle: _strut,
                  ),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  Widget _buildStatusBar() {
    final doc = _document;
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        4 + MediaQuery.paddingOf(context).bottom,
      ),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: [
          Text('Ln $_cursorLine, Col $_cursorColumn', style: style),
          const Spacer(),
          if (_readOnly) Text('Read-only  ·  ', style: style),
          if (_dirty) Text('Modified  ·  ', style: style),
          if (doc != null)
            Text('${doc.encodingLabel}  ·  ${doc.lineEnding.label}', style: style),
        ],
      ),
    );
  }
}
