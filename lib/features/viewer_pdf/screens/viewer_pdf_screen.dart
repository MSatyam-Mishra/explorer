import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:explorer/core/services/bookmark_service.dart';

class PdfViewerScreen extends StatefulWidget {
  final File pdfFile;

  const PdfViewerScreen({super.key, required this.pdfFile});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  int _totalPages = 0;
  int _currentPage = 0;
  bool _isReady = false;
  String _errorMessage = '';
  PDFViewController? _pdfViewController;
  final BookmarkService _bookmarkService = BookmarkService();
  List<Bookmark> _bookmarks = [];

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    final bookmarks = await _bookmarkService.getBookmarks(widget.pdfFile.path);
    setState(() {
      _bookmarks = bookmarks;
    });
  }

  Future<void> _addBookmark() async {
    await _bookmarkService.addBookmark(
      widget.pdfFile.path,
      _currentPage,
      'Page ${_currentPage + 1}',
    );
    _loadBookmarks();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bookmarked page ${_currentPage + 1}')),
      );
    }
  }

  Future<void> _restoreLastRead(PDFViewController controller) async {
    final lastRead = await _bookmarkService.getLastReadPosition(
      widget.pdfFile.path,
    );
    if (lastRead != null && lastRead is int) {
      controller.setPage(lastRead);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pdfFile.path.split('/').last),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: 'Bookmark Page',
            onPressed: _isReady ? _addBookmark : null,
          ),
          if (_isReady)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Center(child: Text('${_currentPage + 1}/$_totalPages')),
            ),
        ],
      ),
      drawer: Drawer(
        child: Column(
          children: [
            const DrawerHeader(child: Center(child: Text("Bookmarks"))),
            Expanded(
              child: _bookmarks.isEmpty
                  ? const Center(child: Text("No bookmarks yet"))
                  : ListView.builder(
                      itemCount: _bookmarks.length,
                      itemBuilder: (context, index) {
                        final bookmark = _bookmarks[index];
                        return ListTile(
                          title: Text(bookmark.label),
                          subtitle: Text(
                            "${bookmark.createdAt.year}-${bookmark.createdAt.month}-${bookmark.createdAt.day}",
                          ),
                          onTap: () {
                            Navigator.pop(context); // Close drawer
                            _pdfViewController?.setPage(bookmark.position);
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () async {
                              await _bookmarkService.removeBookmark(
                                widget.pdfFile.path,
                                bookmark.id,
                              );
                              _loadBookmarks();
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: <Widget>[
          PDFView(
            nightMode: Theme.of(context).brightness == Brightness.dark,
            filePath: widget.pdfFile.path,
            enableSwipe: true,
            swipeHorizontal: false,
            autoSpacing: false,
            pageFling: true,
            onRender: (pages) {
              setState(() {
                _totalPages = pages!;
                _isReady = true;
              });
            },
            onViewCreated: (PDFViewController pdfViewController) {
              _pdfViewController = pdfViewController;
              _restoreLastRead(pdfViewController);
            },
            onError: (error) {
              setState(() {
                _errorMessage = error.toString();
              });
            },
            onPageError: (page, error) {
              setState(() {
                _errorMessage = '$page: ${error.toString()}';
              });
            },
            onPageChanged: (int? page, int? total) {
              setState(() {
                _currentPage = page!;
              });
              _bookmarkService.saveLastReadPosition(widget.pdfFile.path, page);
            },
          ),
          _errorMessage.isNotEmpty
              ? Center(child: Text(_errorMessage))
              : !_isReady
              ? const Center(child: CircularProgressIndicator())
              : const SizedBox.shrink(),
        ],
      ),
    );
  }
}
