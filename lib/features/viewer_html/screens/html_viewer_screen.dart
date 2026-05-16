import 'dart:convert';
import 'dart:io';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

class HtmlViewerScreen extends StatefulWidget {
  final File file;
  const HtmlViewerScreen({super.key, required this.file});

  @override
  State<HtmlViewerScreen> createState() => _HtmlViewerScreenState();
}

class _HtmlViewerScreenState extends State<HtmlViewerScreen> {
  // 0 = Rendered, 1 = Source
  int _viewMode = 0;
  bool _isEditing = false;
  String? _fileContent;
  late TextEditingController _textEditingController;

  @override
  void initState() {
    super.initState();
    _textEditingController = TextEditingController();
    _loadFileContent();
  }

  @override
  void dispose() {
    _textEditingController.dispose();
    super.dispose();
  }

  Future<void> _loadFileContent() async {
    try {
      final content = await widget.file.readAsString();
      setState(() {
        _fileContent = content;
        _textEditingController.text = content;
      });
    } catch (e) {
      // Handle error
    }
  }

  Future<void> _saveFile() async {
    try {
      await widget.file.writeAsString(_textEditingController.text);
      setState(() {
        _fileContent = _textEditingController.text;
        _isEditing = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File saved successfully')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error saving file: $e')));
    }
  }

  String _generateSourceHtml(String content) {
    // Escaping HTML entities for the source view
    final escaped = const HtmlEscape().convert(content);

    // A dark theme syntax highlighting template
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css">
  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
  <style>
    body { margin: 0; padding: 0; background: #282c34; }
    pre { margin: 0; padding: 16px; }
    code { font-family: 'Fira Code', monospace; font-size: 14px; }
  </style>
</head>
<body>
  <pre><code class="language-html">$escaped</code></pre>
  <script>hljs.highlightAll();</script>
</body>
</html>
    ''';
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      trailing: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              label: Text('Render'),
              icon: Icon(Icons.web, size: 18),
            ),
            ButtonSegment(
              value: 1,
              label: Text('Source'),
              icon: Icon(Icons.code, size: 18),
            ),
          ],
          selected: {_viewMode},
          onSelectionChanged: (newSelection) {
            if (_isEditing) {
              setState(() => _isEditing = false);
            }
            setState(() {
              _viewMode = newSelection.first;
            });
          },
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
      body: _buildBody(),
      floatingActionButton: _viewMode == 1
          ? FloatingActionButton(
              onPressed: () {
                if (_isEditing) {
                  _saveFile();
                } else {
                  setState(() {
                    _isEditing = true;
                  });
                }
              },
              child: Icon(_isEditing ? Icons.save : Icons.edit),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_viewMode == 0) {
      // RENDERED VIEW
      return InAppWebView(
        key: const ValueKey('rendered'),
        initialUrlRequest: URLRequest(
          url: WebUri("file://${widget.file.path}"),
        ),
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
          // ignoreSSLErrors: true,
          javaScriptEnabled: true,
        ),
      );
    } else {
      // SOURCE VIEW
      if (_fileContent == null) {
        return const Center(child: CircularProgressIndicator());
      }

      if (_isEditing) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            controller: _textEditingController,
            maxLines: null,
            expands: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Enter HTML code...',
            ),
          ),
        );
      }

      return InAppWebView(
        key: const ValueKey('source'),
        initialData: InAppWebViewInitialData(
          data: _generateSourceHtml(_fileContent!),
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      );
    }
  }
}
