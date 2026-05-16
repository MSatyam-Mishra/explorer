import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:explorer/shared/widgets/glossy_drawer.dart';
import 'package:flutter/material.dart';
import 'package:epubx/epubx.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:explorer/core/services/bookmark_service.dart';

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
  final BookmarkService _bookmarkService = BookmarkService();
  List<Bookmark> _bookmarks = [];

  @override
  void initState() {
    super.initState();
    _loadBook();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    final bookmarks = await _bookmarkService.getBookmarks(widget.epubFile.path);
    setState(() {
      _bookmarks = bookmarks;
    });
  }

  Future<void> _addBookmark() async {
    String label = "Chapter ${_currentChapterIndex + 1}";
    if (_chapters.isNotEmpty &&
        _currentChapterIndex < _chapters.length &&
        _chapters[_currentChapterIndex].Title != null) {
      label = _chapters[_currentChapterIndex].Title!;
    }

    await _bookmarkService.addBookmark(
      widget.epubFile.path,
      _currentChapterIndex,
      label,
    );
    _loadBookmarks();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bookmarked current chapter')),
      );
    }
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
        int initialChapter = 0;
        final lastRead = await _bookmarkService.getLastReadPosition(
          widget.epubFile.path,
        );
        if (lastRead != null && lastRead is int) {
          initialChapter = lastRead.clamp(0, _chapters.length - 1);
        }
        _loadChapter(initialChapter);
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

  Future<void> _loadChapter(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return;

    _bookmarkService.saveLastReadPosition(widget.epubFile.path, chapterIndex);

    final chapter = _chapters[chapterIndex];
    String htmlContent = chapter.HtmlContent ?? "<p>No content available</p>";
    htmlContent = fixImagePaths(_book!, htmlContent);

    String styledHtml =
        '''
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
      transition: transform 0.6s ease;
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
    if (page < 0) {
      window.flutter_inappwebview.callHandler('previousChapter');
      return;
    }
    if (page >= totalPages) {
      window.flutter_inappwebview.callHandler('nextChapter');
      return;
    }
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
    final barFg = ClearGlassForeground.icon(context);

    return ExplorerScaffold(
      title: _book?.Title ?? 'EPUB Reader',
      trailing: ExplorerTopBar.actions(
        context,
        [
          IconButton(
            onPressed: _addBookmark,
            icon: Icon(Icons.bookmark_border, color: barFg),
            tooltip: 'Bookmark Chapter',
          ),
          IconButton(
            onPressed: _currentChapterIndex > 0 ? _previousChapter : null,
            icon: Icon(Icons.arrow_back_ios, color: barFg, size: 18),
            tooltip: 'Previous Chapter',
          ),
          IconButton(
            onPressed: _currentChapterIndex < _chapters.length - 1
                ? _nextChapter
                : null,
            icon: Icon(Icons.arrow_forward_ios, color: barFg, size: 18),
            tooltip: 'Next Chapter',
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                '${_currentChapterIndex + 1}/${_chapters.length}',
                style: ExplorerTopBar.pageIndicatorStyle(context),
              ),
            ),
          ),
        ],
      ),
      drawer: _chapters.isNotEmpty
          ? GlossyDrawer(
              child: Column(
                children: [
                  DrawerHeader(
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor,
                    ),
                    child: SizedBox(
                      width: double.infinity,
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
                              overflow: TextOverflow.ellipsis,
                            ),
                            maxLines: 2,
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
                  ),
                  Expanded(
                    child: DefaultTabController(
                      length: 2,
                      child: Column(
                        children: [
                          const TabBar(
                            tabs: [
                              Tab(text: "Index"),
                              Tab(text: "Bookmarks"),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                // Tab 1: Index
                                ListView.builder(
                                  itemCount: _chapters.length,
                                  itemBuilder: (context, i) => ListTile(
                                    leading: CircleAvatar(
                                      radius: 12,
                                      backgroundColor: i == _currentChapterIndex
                                          ? Theme.of(context).primaryColor
                                          : Colors.grey.shade300,
                                      child: Text(
                                        '${i + 1}',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: i == _currentChapterIndex
                                              ? Colors.white
                                              : Colors.black54,
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
                                  ),
                                ),
                                // Tab 2: Bookmarks
                                _bookmarks.isEmpty
                                    ? const Center(child: Text("No bookmarks"))
                                    : ListView.builder(
                                        itemCount: _bookmarks.length,
                                        itemBuilder: (context, index) {
                                          final bookmark = _bookmarks[index];
                                          return ListTile(
                                            title: Text(bookmark.label),
                                            subtitle: Text(
                                              "${bookmark.createdAt.year}-${bookmark.createdAt.month}-${bookmark.createdAt.day}",
                                            ),
                                            trailing: IconButton(
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.red,
                                              ),
                                              onPressed: () async {
                                                await _bookmarkService
                                                    .removeBookmark(
                                                      widget.epubFile.path,
                                                      bookmark.id,
                                                    );
                                                _loadBookmarks();
                                              },
                                            ),
                                            onTap: () {
                                              Navigator.pop(context);
                                              _loadChapter(
                                                bookmark.position as int,
                                              );
                                            },
                                          );
                                        },
                                      ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: _buildBody(),
      floatingActionButton: _chapters.isNotEmpty
          ? FloatingActionButton(
              onPressed: () => Scaffold.of(context).openDrawer(),
              child: const Icon(Icons.menu_book),
              tooltip: 'Table of Contents',
            )
          : null,
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
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(fontSize: 16, color: Colors.red),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadBook, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_currentHtml.isEmpty) {
      return const Center(child: Text('No content to display'));
    }

    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _currentHtml,
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: false,
        useOnDownloadStart: true,
        javaScriptEnabled: true,
      ),
      onWebViewCreated: (controller) {
        _webViewController = controller;
        _webViewController?.addJavaScriptHandler(
          handlerName: 'nextChapter',
          callback: (args) {
            _nextChapter();
            return null;
          },
        );
        _webViewController?.addJavaScriptHandler(
          handlerName: 'previousChapter',
          callback: (args) {
            _previousChapter();
            return null;
          },
        );
      },
      onLoadStop: (controller, url) async {
        await controller.evaluateJavascript(
          source: '''
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
            
            if (Math.abs(deltaX) > Math.abs(deltaY) && Math.abs(deltaX) > 50) {
              if (deltaX > 0) {
                window.flutter_inappwebview.callHandler('previousChapter');
              } else {
                window.flutter_inappwebview.callHandler('nextChapter');
              }
            }
          });
        ''',
        );
      },
      onConsoleMessage: (controller, consoleMessage) {
        debugPrint("Console: ${consoleMessage.message}");
      },
    );
  }
}

// Helper functions
Uint8List? getImageBytes(EpubBook book, String imagePath) {
  final imageFile = book.Content?.Images?[imagePath];
  if (imageFile != null && imageFile.Content != null) {
    return Uint8List.fromList(imageFile.Content!);
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
      return 'src="data:image/$extension;base64,$base64Image"';
    }
    return match.group(0)!;
  });
}
