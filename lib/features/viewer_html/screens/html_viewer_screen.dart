import 'dart:io';

import 'package:explorer/core/services/local_content_server.dart';
import 'package:explorer/features/viewer_text/screens/text_editor_screen.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

/// Renders an HTML page (with its relative CSS/JS/images) and lets the user
/// edit the source.
class HtmlViewerScreen extends StatefulWidget {
  final File file;
  const HtmlViewerScreen({super.key, required this.file});

  @override
  State<HtmlViewerScreen> createState() => _HtmlViewerScreenState();
}

class _HtmlViewerScreenState extends State<HtmlViewerScreen> {
  final _editorKey = GlobalKey<TextEditorPaneState>();
  bool _showSource = false;
  bool _dirty = false;
  Uri? _base;
  int _renderToken = 0;

  @override
  void initState() {
    super.initState();
    // Served over loopback HTTP: Android blocks file:// access in WebViews
    // by default, and relative resources then resolve like on a web server.
    LocalContentServer.instance.mountDirectory(widget.file.parent.path).then((base) {
      if (!mounted) {
        LocalContentServer.instance.unmount(base);
        return;
      }
      setState(() => _base = base);
    });
  }

  @override
  void dispose() {
    final base = _base;
    if (base != null) LocalContentServer.instance.unmount(base);
    super.dispose();
  }

  Future<void> _save() async {
    final ok = await _editorKey.currentState?.save() ?? false;
    if (ok && mounted) {
      setState(() => _renderToken++);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) Navigator.pop(context);
      },
      child: ExplorerScaffold(
        title: p.basename(widget.file.path),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showSource && _dirty)
              IconButton(
                icon: const Icon(Icons.save_outlined),
                tooltip: 'Save',
                onPressed: _save,
              ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.web, size: 18),
                    tooltip: 'Rendered page',
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.code, size: 18),
                    tooltip: 'Source',
                  ),
                ],
                selected: {_showSource},
                onSelectionChanged: (s) => setState(() => _showSource = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(top: DockedGlossyTopBar.contentTopInset(context)),
          child: IndexedStack(
            index: _showSource ? 1 : 0,
            children: [
              _buildRendered(),
              TextEditorPane(
                key: _editorKey,
                file: widget.file,
                onDirtyChanged: (dirty) => setState(() => _dirty = dirty),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRendered() {
    final base = _base;
    if (base == null) return const Center(child: CircularProgressIndicator());
    final url = base.resolve(Uri.encodeComponent(p.basename(widget.file.path)));
    return InAppWebView(
      key: ValueKey(_renderToken),
      initialUrlRequest: URLRequest(url: WebUri.uri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
      ),
    );
  }
}
