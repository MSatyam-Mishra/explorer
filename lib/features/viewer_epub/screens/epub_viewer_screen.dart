import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:epubx/epubx.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

class EpubViewerScreen extends StatefulWidget {
  final File epubFile;
  const EpubViewerScreen({super.key, required this.epubFile});

  @override
  State<EpubViewerScreen> createState() => _EpubViewerScreenState();
}

class _EpubViewerScreenState extends State<EpubViewerScreen> {
  EpubBook? _book;
  List<EpubChapter> _chapters = [];
  String _currentHtml = "";
  bool _isLoading = true;
  String? _error;
  int _currentChapterIndex = 0;
  InAppWebViewController? _webViewController;

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  Future<void> _loadBook() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final bytes = await widget.epubFile.readAsBytes();
      final epubBook = await EpubReader.readBook(bytes);

      setState(() {
        _book = epubBook;
        _chapters = epubBook.Chapters ?? [];
        _isLoading = false;
      });

      if (_chapters.isNotEmpty) {
        _loadChapter(0);
      } else {
        setState(() {
          _error = "No chapters found in this EPUB file";
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = "Error loading EPUB: $e";
        _isLoading = false;
      });
      debugPrint("Error loading EPUB: $e");
    }
  }
Uint8List? getImageBytes(EpubBook book, String imagePath) {
  final imageFile = book.Content?.Images?[imagePath];
  if (imageFile != null && imageFile.Content != null) {
    return Uint8List.fromList(imageFile.Content!); // ✅ Convert List<int> → Uint8List
  }
  return null;
}

String fixImagePaths(EpubBook book, String htmlContent) {
  final regex = RegExp(r'src="([^"]+)"');
  return htmlContent.replaceAllMapped(regex, (match) {
    final path = match.group(1)!;
    final bytes = getImageBytes(book, path);
    if (bytes != null) {
      final base64Image = base64Encode(bytes);
      final extension = path.split('.').last.toLowerCase();
      return 'src="data:image/$extension;base64,$base64Image"'; // ✅ Embed directly
    }
    return match.group(0)!;
  });
}

Future<void> _loadChapter(int chapterIndex) async {
  if (chapterIndex < 0 || chapterIndex >= _chapters.length) return;

  final chapter = _chapters[chapterIndex];
  String htmlContent = chapter.HtmlContent ?? "<p>No content available</p>";
  htmlContent = fixImagePaths(_book!, htmlContent);

 String styledHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <style>
    body {
      font-family: sans-serif;
      margin: 0;
      padding: 20px;
      column-width: 90vw;
      column-gap: 40px;
      height: 100vh;
      overflow: hidden;
      transition: transform 0.6s ease; /* Smooth page turn */
    }
    img { max-width: 100%; height: auto; }
  </style>
</head>
<body>
  $htmlContent
  <script>
    let currentPage = 0;
    let totalPages = Math.ceil(document.body.scrollWidth / window.innerWidth);

    function showPage(page) {
      if (page < 0) page = 0;
      if (page >= totalPages) page = totalPages - 1;
      currentPage = page;
      window.scrollTo({ left: window.innerWidth * currentPage, behavior: 'smooth' });
    }

    let startX = 0;
    document.addEventListener('touchstart', e => startX = e.touches[0].clientX);
    document.addEventListener('touchend', e => {
      let deltaX = e.changedTouches[0].clientX - startX;
      if (Math.abs(deltaX) > 50) {
        if (deltaX < 0) showPage(currentPage + 1);
        else showPage(currentPage - 1);
      }
    });
  </script>
</body>
</html>
''';


  setState(() {
    _currentHtml = styledHtml;
    _currentChapterIndex = chapterIndex;
  });

  _webViewController?.loadData(
    data: _currentHtml,
    mimeType: 'text/html',
    encoding: 'utf-8',
  );
}


  void _previousChapter() {
    if (_currentChapterIndex > 0) {
      _loadChapter(_currentChapterIndex - 1);
    }
  }

  void _nextChapter() {
    if (_currentChapterIndex < _chapters.length - 1) {
      _loadChapter(_currentChapterIndex + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_book?.Title ?? "EPUB Reader"),
        actions: [
          // ✅ Add navigation buttons in app bar
          IconButton(
            onPressed: _currentChapterIndex > 0 ? _previousChapter : null,
            icon: const Icon(Icons.arrow_back_ios),
            tooltip: 'Previous Chapter',
          ),
          IconButton(
            onPressed: _currentChapterIndex < _chapters.length - 1 ? _nextChapter : null,
            icon: const Icon(Icons.arrow_forward_ios),
            tooltip: 'Next Chapter',
          ),
          // ✅ Chapter counter
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${_currentChapterIndex + 1}/${_chapters.length}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      drawer: _chapters.isNotEmpty ? Drawer(
        child: ListView(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    _book?.Title ?? "Book",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _book?.Author ?? "Unknown Author",
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            // ✅ Chapter list with current chapter highlight
            for (int i = 0; i < _chapters.length; i++)
              ListTile(
                leading: CircleAvatar(
                  radius: 12,
                  backgroundColor: i == _currentChapterIndex 
                    ? Theme.of(context).primaryColor 
                    : Colors.grey.shade300,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 10,
                      color: i == _currentChapterIndex ? Colors.white : Colors.black54,
                    ),
                  ),
                ),
                title: Text(
                  _chapters[i].Title ?? "Chapter ${i + 1}",
                  style: TextStyle(
                    fontWeight: i == _currentChapterIndex 
                      ? FontWeight.bold 
                      : FontWeight.normal,
                    color: i == _currentChapterIndex 
                      ? Theme.of(context).primaryColor 
                      : null,
                  ),
                ),
                selected: i == _currentChapterIndex,
                onTap: () {
                  Navigator.pop(context);
                  _loadChapter(i);
                },
              )
          ],
        ),
      ) : null,
      body: _buildBody(),
      // ✅ Add floating action button for quick navigation
      floatingActionButton: _chapters.isNotEmpty ? FloatingActionButton(
        onPressed: () => Scaffold.of(context).openDrawer(),
        child: const Icon(Icons.menu_book),
        tooltip: 'Table of Contents',
      ) : null,
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading EPUB...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(fontSize: 16, color: Colors.red),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadBook,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentHtml.isEmpty) {
      return const Center(
        child: Text('No content to display'),
      );
    }

    // ✅ Enhanced WebView with better configuration
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _currentHtml,
        encoding: 'utf-8',
      ),
      initialOptions: InAppWebViewGroupOptions(
        crossPlatform: InAppWebViewOptions(
          useShouldOverrideUrlLoading: true,
          mediaPlaybackRequiresUserGesture: false,
          useOnDownloadStart: true,
        ),
        android: AndroidInAppWebViewOptions(
          useHybridComposition: true,
          domStorageEnabled: true,
          databaseEnabled: true,
        ),
        ios: IOSInAppWebViewOptions(
          allowsInlineMediaPlayback: true,
        ),
      ),
      onWebViewCreated: (controller) {
        _webViewController = controller;
      },
      onLoadStop: (controller, url) async {
        // ✅ Add swipe gestures for chapter navigation
        await controller.evaluateJavascript(source: '''
          let startX = 0;
          let startY = 0;
          
          document.addEventListener('touchstart', function(e) {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
          });
          
          document.addEventListener('touchend', function(e) {
            let endX = e.changedTouches[0].clientX;
            let endY = e.changedTouches[0].clientY;
            
            let deltaX = endX - startX;
            let deltaY = endY - startY;
            
            // Only handle horizontal swipes (not vertical scrolling)
            if (Math.abs(deltaX) > Math.abs(deltaY) && Math.abs(deltaX) > 50) {
              if (deltaX > 0) {
                // Swipe right - previous chapter
                window.flutter_inappwebview.callHandler('previousChapter');
              } else {
                // Swipe left - next chapter
                window.flutter_inappwebview.callHandler('nextChapter');
              }
            }
          });
        ''');
      },
      onConsoleMessage: (controller, consoleMessage) {
        debugPrint("Console: ${consoleMessage.message}");
      },
    );
  }
}
