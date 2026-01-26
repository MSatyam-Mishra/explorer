import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:rive/rive.dart';

class RiveViewerScreen extends StatefulWidget {
  final io.File riveFile;

  const RiveViewerScreen({super.key, required this.riveFile});

  @override
  State<RiveViewerScreen> createState() => _RiveViewerScreenState();
}

class _RiveViewerScreenState extends State<RiveViewerScreen> {
  late PageController _pageController;
  List<io.File> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSiblingFiles();
  }

  Future<void> _loadSiblingFiles() async {
    try {
      final parentDir = widget.riveFile.parent;
      final entities = parentDir.listSync();
      final files = entities
          .whereType<io.File>()
          .where((f) => f.path.toLowerCase().endsWith('.riv'))
          .toList();

      // Sort to ensure consistent order
      files.sort((a, b) => a.path.compareTo(b.path));

      final initialIndex = files.indexWhere(
        (f) => f.path == widget.riveFile.path,
      );
      final safeIndex = initialIndex != -1 ? initialIndex : 0;

      setState(() {
        _files = files;
        _isLoading = false;
        _pageController = PageController(initialPage: safeIndex);
      });
    } catch (e) {
      debugPrint('Error loading sibling files: $e');
      setState(() {
        _files = [widget.riveFile]; // Fallback
        _isLoading = false;
        _pageController = PageController();
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.horizontal,
        itemCount: _files.length,
        itemBuilder: (context, index) {
          return RivePlayerPage(file: _files[index]);
        },
      ),
    );
  }
}

class RivePlayerPage extends StatefulWidget {
  final io.File file;

  const RivePlayerPage({super.key, required this.file});

  @override
  State<RivePlayerPage> createState() => _RivePlayerPageState();
}

class _RivePlayerPageState extends State<RivePlayerPage> {
  RiveWidgetController? _controller;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRiveFile();
  }

  Future<void> _loadRiveFile() async {
    try {
      final bytes = await widget.file.readAsBytes();
      // Decode the Rive file from bytes using the 0.14.x Factory
      final file = await File.decode(bytes, riveFactory: Factory.rive);
      if (file == null) {
        throw Exception('Failed to decode Rive file');
      }

      _controller = RiveWidgetController(file);

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading Rive file: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to load Rive file: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Content
        Center(
          child: _isLoading
              ? const CircularProgressIndicator()
              : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                )
              : _controller == null
              ? const Text(
                  'Unable to initialize Rive controller',
                  style: TextStyle(color: Colors.white),
                )
              : RiveWidget(controller: _controller!, fit: Fit.contain),
        ),

        // Top Bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: AppBar(
              title: Text(widget.file.path.split('/').last),
              backgroundColor: Colors.transparent,
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              titleTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 20,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
