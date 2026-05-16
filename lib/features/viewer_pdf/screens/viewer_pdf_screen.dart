import 'dart:io';

import 'package:explorer/core/services/bookmark_service.dart';
import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:explorer/shared/widgets/glossy_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:path/path.dart' as p;

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
  bool _pdfNightMode = false;
  bool _initialPositionRestored = false;
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

  void _togglePdfNightMode() {
    setState(() {
      _pdfNightMode = !_pdfNightMode;
      _isReady = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);

    return ExplorerScaffold(
      title: p.basename(widget.pdfFile.path),
      drawer: GlossyDrawer(
        child: Theme(
          data: Theme.of(context).copyWith(
            listTileTheme: ListTileThemeData(
              textColor: iconColor,
              iconColor: iconColor,
            ),
          ),
          child: Column(
            children: [
              DrawerHeader(
                child: Center(
                  child: Text(
                    'Bookmarks',
                    style: ClearGlassForeground.title(context),
                  ),
                ),
              ),
              Expanded(
                child: _bookmarks.isEmpty
                    ? Center(
                        child: Text(
                          'No bookmarks yet',
                          style: TextStyle(color: iconColor),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _bookmarks.length,
                        itemBuilder: (context, index) {
                          final bookmark = _bookmarks[index];
                          return ListTile(
                            title: Text(bookmark.label),
                            subtitle: Text(
                              '${bookmark.createdAt.year}-'
                              '${bookmark.createdAt.month}-'
                              '${bookmark.createdAt.day}',
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _pdfViewController?.setPage(bookmark.position);
                            },
                            trailing: IconButton(
                              icon: AppIcons.delete(color: Colors.redAccent),
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
      ),
      trailing: ExplorerTopBar.actions(
        context,
        [
          ExplorerTopBar.iconButton(
            context: context,
            icon: _pdfNightMode
                ? AppIcons.sun(color: iconColor)
                : AppIcons.moon(color: iconColor),
            tooltip: _pdfNightMode ? 'Light mode' : 'Dark mode',
            onPressed: _togglePdfNightMode,
          ),
          ExplorerTopBar.iconButton(
            context: context,
            icon: AppIcons.bookmark(color: iconColor),
            tooltip: 'Bookmark page',
            onPressed: _isReady ? _addBookmark : null,
          ),
          if (_isReady)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  '${_currentPage + 1}/$_totalPages',
                  style: ExplorerTopBar.pageIndicatorStyle(context),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          PDFView(
            key: ValueKey(_pdfNightMode),
            nightMode: _pdfNightMode,
            defaultPage: _currentPage,
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
              if (!_initialPositionRestored) {
                _initialPositionRestored = true;
                _restoreLastRead(pdfViewController);
              }
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
          if (_errorMessage.isNotEmpty)
            Center(child: Text(_errorMessage))
          else if (!_isReady)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
