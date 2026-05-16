import 'dart:io';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:lottie/lottie.dart';

class LottieViewerScreen extends StatefulWidget {
  final File file;

  const LottieViewerScreen({super.key, required this.file});

  @override
  State<LottieViewerScreen> createState() => _LottieViewerScreenState();
}

class _LottieViewerScreenState extends State<LottieViewerScreen> {
  late PageController _pageController;
  List<File> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSiblingFiles();
  }

  Future<void> _loadSiblingFiles() async {
    try {
      final parentDir = widget.file.parent;
      final entities = parentDir.listSync();
      final files = entities
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();

      // Sort to ensure consistent order
      files.sort((a, b) => a.path.compareTo(b.path));

      final initialIndex = files.indexWhere((f) => f.path == widget.file.path);
      final safeIndex = initialIndex != -1 ? initialIndex : 0;

      setState(() {
        _files = files;
        _isLoading = false;
        _pageController = PageController(initialPage: safeIndex);
      });
    } catch (e) {
      debugPrint('Error loading sibling files: $e');
      setState(() {
        _files = [widget.file]; // Fallback to just opening the single file
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
          return LottiePlayerPage(file: _files[index]);
        },
      ),
    );
  }
}

class LottiePlayerPage extends StatefulWidget {
  final File file;

  const LottiePlayerPage({super.key, required this.file});

  @override
  State<LottiePlayerPage> createState() => _LottiePlayerPageState();
}

class _LottiePlayerPageState extends State<LottiePlayerPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      backgroundColor: Colors.black,
      title: p.basename(widget.file.path),
      body: Stack(
        children: [
          Center(
            child: Lottie.file(
              widget.file,
              controller: _controller,
              onLoaded: (composition) {
                setState(() {
                  _controller.duration = composition.duration;
                  if (_isPlaying) {
                    _controller.forward();
                    _controller.repeat();
                  }
                });
              },
            ),
          ),
          Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_controller.duration != null)
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      return Slider(
                        value: _controller.value,
                        onChanged: (value) {
                          _controller.value = value;
                        },
                        activeColor: Colors.white,
                        inactiveColor: Colors.grey,
                      );
                    },
                  ),
                IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 48,
                  ),
                  onPressed: () {
                    setState(() {
                      _isPlaying = !_isPlaying;
                      if (_isPlaying) {
                        _controller.repeat();
                      } else {
                        _controller.stop();
                      }
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        ],
      ),
    );
  }
}
