import 'package:explorer/features/viewer_vector/svg_path_loader.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

class SvgViewerScreen extends StatefulWidget {
  const SvgViewerScreen({super.key, required this.filePath});

  final String filePath;

  @override
  State<SvgViewerScreen> createState() => _SvgViewerScreenState();
}

class _SvgViewerScreenState extends State<SvgViewerScreen> {
  String? _svg;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final markup = await loadSvgFromPath(widget.filePath);
      if (!mounted) return;
      setState(() => _svg = markup);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      backgroundColor: Colors.white,
      title: p.basename(widget.filePath),
      body: Center(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Could not load SVG:\n$_error',
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_svg == null) {
      return const CircularProgressIndicator();
    }
    return SvgPicture.string(
      _svg!,
      placeholderBuilder: (context) => const CircularProgressIndicator(),
    );
  }
}
