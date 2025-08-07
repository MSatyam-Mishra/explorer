import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pdfFile.path.split('/').last),
        // Show page count in the app bar when ready
        actions: _isReady
            ? [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Center(
                    child: Text('${_currentPage + 1}/$_totalPages'),
                  ),
                ),
              ]
            : [],
      ),
      body: Stack(
        children: <Widget>[
          PDFView(
            nightMode :true,
            filePath: widget.pdfFile.path,
            enableSwipe: true,
            swipeHorizontal: false, // For vertical scrolling
            autoSpacing: false,
            pageFling: true,
            onRender: (pages) {
              setState(() {
                _totalPages = pages!;
                _isReady = true;
              });
            },
            onError: (error) {
              setState(() {
                _errorMessage = error.toString();
              });
              print(error.toString());
            },
            onPageError: (page, error) {
              setState(() {
                _errorMessage = '$page: ${error.toString()}';
              });
              print('$page: ${error.toString()}');
            },
            onPageChanged: (int? page, int? total) {
              setState(() {
                _currentPage = page!;
              });
            },
          ),
          // If there's an error, show it. Otherwise, if not ready, show a loader.
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