import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class SingleFileEditor extends StatefulWidget {
  final File textFile;

  const SingleFileEditor({super.key, required this.textFile});

  @override
  State<SingleFileEditor> createState() => _SingleFileEditorState();
}

class _SingleFileEditorState extends State<SingleFileEditor> {
  QuillController? _controller;
  final FocusNode _focusNode = FocusNode();

  // Pagination
  bool _isLargeFile = false;
  List<String> _allLines = [];
  int _currentPage = 0;
  final int _linesPerPage = 1000;
  int _totalPages = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFileContent();
  }

  Future<void> _loadFileContent() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Check file size first? Or just read lines?
      // Reading lines is safer for memory than readAsString for huge files,
      // but readAsLines still loads all into memory list.
      // For truly huge files, we'd need a stream, but for "Large" (e.g. 5MB text), lines is okay.
      // 500KB is small enough to load all lines.

      final lines = await widget.textFile.readAsLines();
      _allLines = lines;

      if (_allLines.length > _linesPerPage) {
        _isLargeFile = true;
        _totalPages = (_allLines.length / _linesPerPage).ceil();
        _currentPage = 0;
        _loadPage(0);
      } else {
        _isLargeFile = false;
        final content = _allLines.join('\n');
        _setDocumentContent(content);
      }
    } catch (e) {
      // Fallback for read error or if file is binary/unreadable
      _setDocumentContent('Error loading file: ${e.toString()}');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _loadPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _totalPages) return;

    int start = pageIndex * _linesPerPage;
    int end = (start + _linesPerPage < _allLines.length)
        ? start + _linesPerPage
        : _allLines.length;

    final pageLines = _allLines.sublist(start, end);
    final content = pageLines.join('\n');

    _setDocumentContent(content);
    setState(() {
      _currentPage = pageIndex;
    });
  }

  void _setDocumentContent(String content) {
    final doc = Document()..insert(0, content);
    setState(() {
      _controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 0),
      );
    });
  }

  Future<void> _saveFile() async {
    if (_controller == null) return;

    final currentContent = _controller!.document.toPlainText().trim();

    try {
      if (_isLargeFile) {
        // Update the current page lines in _allLines
        final pageLines = currentContent.split('\n');

        int start = _currentPage * _linesPerPage;
        int end = (start + _linesPerPage < _allLines.length)
            ? start + _linesPerPage
            : _allLines.length;

        // Replace range
        // We need to be careful if user added/removed lines.
        // Simplified approach: Overwrite the chunk.
        // If line count changed, it shifts everything. Complex.
        // For now: Just warn user "Saving in standard mode might be safer" or implement proper replacement.
        // Let's implement replacement:
        _allLines.removeRange(start, end);
        _allLines.insertAll(start, pageLines);

        // Re-calculate totals
        _totalPages = (_allLines.length / _linesPerPage).ceil();

        // Write ALL lines back to file
        await widget.textFile.writeAsString(_allLines.join('\n'));
      } else {
        await widget.textFile.writeAsString(currentContent);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File Saved Successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving file: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Toolbar
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: QuillSimpleToolbar(
            controller: _controller!,
            config: const QuillSimpleToolbarConfig(
              showBoldButton: true,
              showItalicButton: true,
              showUnderLineButton: true,
              showStrikeThrough: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showClearFormat: true,
              showHeaderStyle: true,
              showListNumbers: true,
              showListBullets: true,
              showCodeBlock: false,
              showQuote: false,
              showIndent: false,
              showLink: false,
              showSearchButton: false,
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1),

        // Editor
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: QuillEditor(
              controller: _controller!,
              focusNode: _focusNode,
              scrollController: ScrollController(),
              config: const QuillEditorConfig(
                autoFocus: true,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),

        // Pagination Controls
        if (_isLargeFile)
          Container(
            padding: const EdgeInsets.all(8.0),
            color: Colors.grey.shade100,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: _currentPage > 0
                      ? () => _loadPage(_currentPage - 1)
                      : null,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Previous Page',
                ),
                Text('Page ${_currentPage + 1} of $_totalPages'),
                IconButton(
                  onPressed: _currentPage < _totalPages - 1
                      ? () => _loadPage(_currentPage + 1)
                      : null,
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: 'Next Page',
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Expose save method for parent
  void save() => _saveFile();
}
