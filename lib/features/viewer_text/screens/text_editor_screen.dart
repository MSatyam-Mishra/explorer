import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class TextEditorScreen extends StatefulWidget {
  final File textFile;

  const TextEditorScreen({super.key, required this.textFile});

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  QuillController? _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadFileContent();
  }

  Future<void> _loadFileContent() async {
    try {
      final plainText = await widget.textFile.readAsString();
      final doc = Document()..insert(0, plainText);
      setState(() {
        _controller = QuillController(
          document: doc,
          selection: const TextSelection.collapsed(offset: 0),
        );
      });
    } catch (e) {
      setState(() {
        final doc = Document()..insert(0, 'Error loading file: ${e.toString()}');
        _controller = QuillController(document: doc, selection: const TextSelection.collapsed(offset: 0));
      });
    }
  }

  Future<void> _saveFile() async {
    if (_controller == null) return;
    final plainText = _controller!.document.toPlainText();
    try {
      await widget.textFile.writeAsString(plainText);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.textFile.path.split('/').last),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt_outlined),
            onPressed: _saveFile,
            tooltip: 'Save File',
          ),
        ],
      ),
      // Inside the TextEditorScreen build method...
body: _controller == null
    ? const Center(child: CircularProgressIndicator())
    : Column(
        children: [
          // This makes the toolbar scroll horizontally instead of wrapping
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: QuillSimpleToolbar(
              controller: _controller!,
              // We provide a custom config to control the buttons
              config: const QuillSimpleToolbarConfig(
                // Show only the buttons we want
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
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: QuillEditor(
                controller: _controller!,
                focusNode: _focusNode,
                scrollController: ScrollController(),
                config: const QuillEditorConfig(
                  autoFocus: true,
                 // readOnly: false,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          )
        ],
      ),
    );
  }
}