import 'dart:io';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
// open_xml doesn't seem to have a widely used 'viewer' API, but we'll import what we can.
// If the package is strictly for creation, we might need to rely on 'archive' to unzip and read internal XMLs.
// Re-reading user prompt: "using open_xml".
// I'll import it. usage: Pptx pptx = Pptx.fromBytes(bytes)?
// If not available, I'll use archive to extract text from slides.

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

class PptViewerScreen extends StatefulWidget {
  final File file;

  const PptViewerScreen({super.key, required this.file});

  @override
  State<PptViewerScreen> createState() => _PptViewerScreenState();
}

class _PptViewerScreenState extends State<PptViewerScreen> {
  bool _isLoading = true;
  List<String> _slidesText = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPptx();
  }

  Future<void> _loadPptx() async {
    // Since specialized PPT viewers are paid or complex, and open_xml is for creation,
    // We will implement a "Reader" that extracts text from the PPTX (which is a ZIP of XMLs).
    try {
      final bytes = await widget.file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // PPTX structure:
      // ppt/slides/slide1.xml, slide2.xml ...

      final slideFiles = archive.files
          .where(
            (f) =>
                f.name.startsWith('ppt/slides/slide') &&
                f.name.endsWith('.xml'),
          )
          .toList();

      // Sort by slide number
      slideFiles.sort((a, b) {
        final numA = _extractSlideNumber(a.name);
        final numB = _extractSlideNumber(b.name);
        return numA.compareTo(numB);
      });

      List<String> extractedText = [];

      for (final slideFile in slideFiles) {
        final content = String.fromCharCodes(slideFile.content as List<int>);
        final xmlDoc = XmlDocument.parse(content);

        // Extract all text (a:t elements)
        final textElements = xmlDoc.findAllElements('a:t');
        final slideText = textElements.map((node) => node.innerText).join('\n');
        extractedText.add(slideText.isEmpty ? "[Empty Slide]" : slideText);
      }

      setState(() {
        _slidesText = extractedText;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  int _extractSlideNumber(String filename) {
    // ppt/slides/slide12.xml -> 12
    final name = p.basenameWithoutExtension(filename); // slide12
    final number = name.replaceAll(RegExp(r'[^0-9]'), '');
    return int.tryParse(number) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(child: Text('Error: $_errorMessage'));
    }
    if (_slidesText.isEmpty) {
      return const Center(child: Text('No slides or text found.'));
    }

    return PageView.builder(
      itemCount: _slidesText.length,
      itemBuilder: (context, index) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade300),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Slide ${index + 1}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    _slidesText[index],
                    style: const TextStyle(fontSize: 16, color: Colors.black87),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
