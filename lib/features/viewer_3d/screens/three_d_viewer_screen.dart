import 'dart:io';

import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';
import 'package:path/path.dart' as p;

class ThreeDViewerScreen extends StatefulWidget {
  final File file;

  const ThreeDViewerScreen({super.key, required this.file});

  @override
  State<ThreeDViewerScreen> createState() => _ThreeDViewerScreenState();
}

class _ThreeDViewerScreenState extends State<ThreeDViewerScreen> {
  final Flutter3DController _controller = Flutter3DController();
  bool _isLoading = true;
  String _status = 'Loading...';

  @override
  void initState() {
    super.initState();
    _controller.onModelLoaded.addListener(_onModelLoaded);
  }

  void _onModelLoaded() {
    if (mounted) {
      final isLoaded = _controller.onModelLoaded.value;
      if (isLoaded) {
        setState(() {
          _isLoading = false;
          _status = 'Loaded';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.onModelLoaded.removeListener(_onModelLoaded);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Determine if OBJ or GLB/GLTF
    final ext = p.extension(widget.file.path).toLowerCase();
    final isObj = ext == '.obj';

    final barFg = ClearGlassForeground.icon(context);

    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      trailing: isObj
          ? null
          : ExplorerTopBar.actions(
              context,
              [
                IconButton(
                  icon: Icon(Icons.refresh, color: barFg),
                  tooltip: 'Reset Camera',
                  onPressed: () {
                    _controller.resetCameraOrbit();
                    _controller.resetCameraTarget();
                  },
                ),
                IconButton(
                  icon: Icon(Icons.play_arrow, color: barFg),
                  tooltip: 'Play Animation',
                  onPressed: _controller.playAnimation,
                ),
                IconButton(
                  icon: Icon(Icons.pause, color: barFg),
                  tooltip: 'Pause Animation',
                  onPressed: _controller.pauseAnimation,
                ),
              ],
            ),
      body: Stack(
        children: [
          _buildViewer(isObj),
          if (_isLoading)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      "Loading 3D Model...",
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildViewer(bool isObj) {
    // NOTE: flutter_3d_controller uses a webview under the hood for mobile/macos.
    // It takes 'src' which can be file path or asset.
    // Ensure we pass the absolute path.

    // For local files on devices, we often need 'file://' prefix or trusted path.
    // The library documentation says: src: 'path/to/file'.

    if (isObj) {
      return Flutter3DViewer.obj(
        src: widget.file.path,
        scale: 5,
        cameraZ: 10,
        onProgress: (progress) {
          debugPrint('Progress: $progress');
        },
        onLoad: (address) {
          debugPrint('Loaded: $address');
          setState(() {
            _isLoading = false;
            _status = 'Loaded';
          });
        },
        onError: (error) {
          debugPrint('Error: $error');
          setState(() {
            _isLoading = false;
            _status = 'Error: $error';
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to load: $error')));
        },
      );
    } else {
      // GLB / GLTF
      return Flutter3DViewer(
        src: widget.file.path,
        controller: _controller,

        // Optional customizations
        progressBarColor: Colors.orange,
        activeGestureInterceptor: true,
        enableTouch: true,

        onProgress: (progress) {
          debugPrint('Progress: $progress');
        },
        onLoad: (address) {
          debugPrint('Loaded: $address');
          setState(() {
            _isLoading = false;
            _status = 'Loaded';
          });
        },
        onError: (error) {
          debugPrint('Error: $error');
          setState(() {
            _isLoading = false;
            _status = 'Error: $error';
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to load: $error')));
        },
      );
    }
  }
}
