import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:explorer/core/services/local_content_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders Markdown (GitHub flavoured) to HTML in a WebView. Relative image
/// links resolve against the document's folder via the loopback server.
class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    super.key,
    required this.markdown,
    required this.file,
    this.topPadding = 0,
  });

  final String markdown;
  final File file;
  final double topPadding;

  static String toHtml(String markdown) => md.markdownToHtml(
        markdown,
        extensionSet: md.ExtensionSet.gitHubWeb,
        // GFM tag filter: <script>, <iframe>, <style>... are escaped.
        enableTagfilter: true,
      );

  /// The page never runs its own scripts: content is pushed in from Dart
  /// with evaluateJavascript, which a page CSP doesn't apply to. This blocks
  /// `<script>`, inline handlers (`<img onerror>`), fetch/XHR and forms, so a
  /// hostile document can't read files next to it through the loopback
  /// mount. Remote images (badges) still load.
  static const _csp = "default-src 'none'; script-src 'none'; "
      "img-src * data: blob:; media-src * data: blob:; font-src * data:; "
      "style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; "
      "frame-src 'none'; object-src 'none'; base-uri 'none'";

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  InAppWebViewController? _controller;
  Uri? _base;
  Timer? _debounce;
  bool _pageReady = false;

  @override
  void initState() {
    super.initState();
    // Relative links only need images/media; nothing else is served.
    LocalContentServer.instance
        .mountDirectory(
          widget.file.parent.path,
          allowedExtensions: LocalContentServer.imageAndMediaExtensions,
        )
        .then((base) {
      if (!mounted) {
        LocalContentServer.instance.unmount(base);
        return;
      }
      setState(() => _base = base);
    });
  }

  @override
  void didUpdateWidget(MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.markdown != widget.markdown ||
        oldWidget.topPadding != widget.topPadding) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 250), _pushContent);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    final base = _base;
    if (base != null) LocalContentServer.instance.unmount(base);
    super.dispose();
  }

  Future<void> _pushContent() async {
    final controller = _controller;
    if (controller == null || !_pageReady) return;
    final html = MarkdownPreview.toHtml(widget.markdown);
    await controller.evaluateJavascript(
      source: 'document.getElementById("content").innerHTML = '
          '${jsonEncode(html)};'
          'document.body.style.paddingTop = "${widget.topPadding + 16}px";',
    );
  }

  String _page(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final dark = Theme.of(context).brightness == Brightness.dark;
    return '''<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${MarkdownPreview._csp}">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: ${dark ? 'dark' : 'light'}; }
  body { margin: 0; padding: ${widget.topPadding + 16}px 20px 48px;
    font: 16px/1.6 -apple-system, "Segoe UI", Roboto, sans-serif;
    color: ${hex(scheme.onSurface)}; background: ${hex(scheme.surface)};
    word-wrap: break-word; }
  #content { max-width: 860px; margin: 0 auto; }
  a { color: ${hex(scheme.primary)}; }
  img { max-width: 100%; }
  pre { background: ${dark ? '#1e1e1e' : '#f4f4f4'}; padding: 12px;
    border-radius: 8px; overflow-x: auto; }
  code { font-family: "JetBrains Mono", Consolas, monospace; font-size: .9em; }
  :not(pre) > code { background: ${dark ? '#2a2a2a' : '#eeeeee'};
    padding: 2px 5px; border-radius: 4px; }
  blockquote { margin: 0; padding: 0 1em;
    border-left: 4px solid ${hex(scheme.outlineVariant)};
    color: ${hex(scheme.onSurfaceVariant)}; }
  table { border-collapse: collapse; display: block; overflow-x: auto; }
  th, td { border: 1px solid ${hex(scheme.outlineVariant)}; padding: 6px 12px; }
  h1, h2 { border-bottom: 1px solid ${hex(scheme.outlineVariant)};
    padding-bottom: .3em; }
  hr { border: 0; border-top: 1px solid ${hex(scheme.outlineVariant)}; }
  input[type=checkbox] { margin-right: .5em; }
</style></head><body><div id="content">${MarkdownPreview.toHtml(widget.markdown)}</div></body></html>''';
  }

  @override
  Widget build(BuildContext context) {
    final base = _base;
    if (base == null) return const Center(child: CircularProgressIndicator());
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _page(context),
        baseUrl: WebUri.uri(base),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (c) => _controller = c,
      onLoadStop: (_, _) {
        _pageReady = true;
      },
      shouldOverrideUrlLoading: (controller, action) async {
        // Keep the preview in place: allow the page itself and in-page
        // anchors, block navigation to other documents.
        final url = action.request.url?.toString() ?? '';
        final page = url.split('#').first;
        return page == base.toString() || page.isEmpty || url.startsWith('about:')
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
    );
  }
}
