import 'package:explorer/core/theme/app_theme.dart';

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rive/rive.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart'; // <-- Make sure this is imported

class RiveViewerScreen extends StatefulWidget {
  final File riveFile;

  const RiveViewerScreen({super.key, required this.riveFile});

  @override
  State<RiveViewerScreen> createState() => _RiveViewerScreenState();
}

class _RiveViewerScreenState extends State<RiveViewerScreen> {
  Artboard? _riveArtboard;
  // Let's use a simpler controller for basic play/pause
  SimpleAnimation? _animationController;

  // NEW: State to track if the animation is playing
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();
    _loadRiveFile();
  }

  Future<void> _loadRiveFile() async {
    try {
      final bytes = await widget.riveFile.readAsBytes();
      final file = RiveFile.import(ByteData.view(bytes.buffer));
      final artboard = file.mainArtboard;

      // Find the first animation in the artboard
      if (artboard.animations.isNotEmpty) {
        final animationName = artboard.animations.first.name;
        // Create a simple controller for that animation
        _animationController = SimpleAnimation(animationName, autoplay: true);
        artboard.addController(_animationController!);
      }
      
      setState(() => _riveArtboard = artboard);
    } catch (e) {
      print("Error loading Rive file: $e");
    }
  }

  void _togglePlay() {
    if (_animationController == null) return;
    
    // Use the controller's isActive property to play/pause
    setState(() {
      _animationController!.isActive = !_animationController!.isActive;
      _isPlaying = _animationController!.isActive;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.riveFile.path.split('/').last),
      ),
      body: Center(
        child: _riveArtboard == null
            ? const CircularProgressIndicator()
            : Rive(artboard: _riveArtboard!),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _togglePlay,
        // Using our app's gradient for the FAB background
        shape: const CircleBorder(),
        child: Ink(
          decoration: BoxDecoration(
            gradient: AppTheme.primaryGradient, // Using our signature gradient
            shape: BoxShape.circle,
          ),
          child: Center(
            // Conditionally show the correct Bootstrap Icon
            child: Icon(
              _isPlaying ? BootstrapIcons.pause_fill : BootstrapIcons.play_fill,
              color: Colors.white,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}

// You might need to add this import to the top of rive_viewer_screen.dart
