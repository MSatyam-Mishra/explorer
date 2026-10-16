import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/core/files/safe_write.dart';
import 'package:explorer/features/viewer_image/image_codec.dart';
import 'package:explorer/features/viewer_image/raw_image.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Crop, rotate, flip, adjust and filter an image. Pops with the saved file
/// path, or null when nothing was saved.
class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.file});

  final File file;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

enum _Tool { crop, adjust, filters }

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  img.Image? _source;
  String? _error;
  bool _saving = false;
  final ImageEdits _edits = ImageEdits();
  _Tool _tool = _Tool.crop;
  double? _aspect; // width / height in pixels; null = free

  late final String _ext = FileTypes.extensionOf(widget.file.path);

  /// Only formats we can write byte-for-byte as their own format are saved
  /// in place; the rest are saved as a PNG copy with a .png name.
  bool get _canOverwrite => ImageCodec.canWrite(_ext);

  /// Camera raws are edited through their embedded preview and only ever
  /// saved as a JPEG or PNG copy; the raw file is never touched.
  late final bool _isRaw = RawImages.isRaw(widget.file.path);

  @override
  void initState() {
    super.initState();
    ImageCodec.decodeForEditing(widget.file).then((image) {
      if (mounted) setState(() => _source = image);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = "This image can't be edited: $e");
    });
  }

  Size get _orientedSize {
    final s = _source!;
    return _edits.quarterTurns.isOdd
        ? Size(s.height.toDouble(), s.width.toDouble())
        : Size(s.width.toDouble(), s.height.toDouble());
  }

  void _rotate(int delta) => setState(() {
        _edits.quarterTurns = (_edits.quarterTurns + delta) % 4;
        _edits.crop = null;
        _aspect = null;
      });

  void _setAspect(double? aspect) {
    setState(() {
      _aspect = aspect;
      if (aspect == null) return;
      final size = _orientedSize;
      // Largest centred rect with this pixel aspect ratio.
      var w = 1.0;
      var h = size.width / (size.height * aspect);
      if (h > 1) {
        w = 1 / h;
        h = 1;
      }
      _edits.crop = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    });
  }

  /// [format] forces the copy's format ('jpg' or 'png').
  Future<void> _save({required bool asCopy, String? format}) async {
    final source = _source;
    if (source == null) return;
    setState(() => _saving = true);
    try {
      final ext = format ?? (_canOverwrite ? _ext : 'png');
      final bytes = await ImageCodec.applyAndEncode(source, _edits, ext);
      final File target;
      if (asCopy || !_canOverwrite || format != null) {
        final dir = widget.file.parent.path;
        final base = p.basenameWithoutExtension(widget.file.path);
        var candidate = File(p.join(dir, '${base}_edited.$ext'));
        for (var i = 2; await candidate.exists(); i++) {
          candidate = File(p.join(dir, '${base}_edited_$i.$ext'));
        }
        target = candidate;
      } else {
        target = widget.file;
      }
      if (identical(target, widget.file) && !_isRaw) {
        // Overwrite via temp file + rename: a failed write can't truncate
        // the original photo.
        await writeFileAtomically(target, bytes);
      } else {
        await target.writeAsBytes(bytes, flush: true);
      }
      if (mounted) Navigator.pop(context, target.path);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    if (_edits.isIdentity) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard edits?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    final ready = _source != null && !_saving;

    return PopScope(
      canPop: _edits.isIdentity,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: ExplorerScaffold(
        title: 'Edit ${p.basename(widget.file.path)}',
        backgroundColor: Colors.black,
        trailing: ExplorerTopBar.actions(context, [
          ExplorerTopBar.iconButton(
            context: context,
            icon: Icon(Icons.restart_alt, color: iconColor),
            tooltip: 'Reset',
            onPressed: ready && !_edits.isIdentity
                ? () => setState(() {
                      _edits
                        ..quarterTurns = 0
                        ..flipHorizontal = false
                        ..flipVertical = false
                        ..crop = null
                        ..brightness = 0
                        ..contrast = 0
                        ..saturation = 0
                        ..filter = ImageFilterPreset.none;
                      _aspect = null;
                    })
                : null,
          ),
          PopupMenuButton<String>(
            // A raw's preview is worth exporting even without edits.
            enabled: ready && (_isRaw || !_edits.isIdentity),
            tooltip: 'Save',
            icon: Icon(Icons.save_outlined, color: iconColor),
            onSelected: (choice) => switch (choice) {
              'save' => _save(asCopy: false),
              'jpg' => _save(asCopy: true, format: 'jpg'),
              'png' => _save(asCopy: true, format: 'png'),
              _ => _save(asCopy: true),
            },
            itemBuilder: (_) => [
              if (_isRaw) ...const [
                PopupMenuItem(value: 'jpg', child: Text('Save as JPEG copy')),
                PopupMenuItem(value: 'png', child: Text('Save as PNG copy')),
              ] else ...[
                if (_canOverwrite)
                  const PopupMenuItem(value: 'save', child: Text('Save')),
                PopupMenuItem(
                  value: 'copy',
                  child: Text(
                    _canOverwrite ? 'Save as copy' : 'Save as PNG copy',
                  ),
                ),
              ],
            ],
          ),
        ]),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
      );
    }
    if (_source == null || _saving) {
      return const Center(child: CircularProgressIndicator());
    }
    final top = DockedGlossyTopBar.contentTopInset(context);
    final wide = WindowSize.of(context).isAtLeastMedium &&
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final preview = Padding(
      padding: const EdgeInsets.all(16),
      child: _buildPreview(),
    );
    final tools = Theme(
      data: ThemeData(brightness: Brightness.dark, colorSchemeSeed: Theme.of(context).colorScheme.primary),
      child: Material(color: const Color(0xFF151515), child: _buildTools(wide)),
    );
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: wide
          ? Row(
              children: [
                Expanded(child: preview),
                SizedBox(width: 340, child: tools),
              ],
            )
          : Column(
              children: [
                Expanded(child: preview),
                Padding(
                  padding: EdgeInsets.only(bottom: bottom),
                  child: tools,
                ),
              ],
            ),
    );
  }

  Widget _buildPreview() {
    final matrix = _edits.colorMatrix();
    final size = _orientedSize;
    // The preview only needs screen resolution; the edits are applied to the
    // full-size pixels in [_source].
    final previewSide = (MediaQuery.sizeOf(context).longestSide *
            MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(1024, 4096);
    Widget image = RotatedBox(
      quarterTurns: _edits.quarterTurns,
      child: Image(
        image: ImageCodec.displayProviderFor(widget.file, previewSide),
        fit: BoxFit.fill,
        gaplessPlayback: true,
      ),
    );
    image = Transform.flip(
      flipX: _edits.flipHorizontal,
      flipY: _edits.flipVertical,
      child: image,
    );
    if (matrix != null) {
      image = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: image);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = math.min(
          constraints.maxWidth / size.width,
          constraints.maxHeight / size.height,
        );
        final display = Size(size.width * scale, size.height * scale);
        return Center(
          child: SizedBox.fromSize(
            size: display,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                if (_tool == _Tool.crop)
                  _CropOverlay(
                    rect: _edits.crop ?? const Rect.fromLTWH(0, 0, 1, 1),
                    displaySize: display,
                    pixelAspect: _aspect == null
                        ? null
                        : _aspect! * size.height / size.width,
                    onChanged: (r) => setState(() {
                      final full = r.left <= 0.001 &&
                          r.top <= 0.001 &&
                          r.right >= 0.999 &&
                          r.bottom >= 0.999;
                      _edits.crop = full ? null : r;
                    }),
                  )
                else if (_edits.crop != null)
                  CustomPaint(painter: _DimPainter(_edits.crop!)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTools(bool wide) {
    final content = switch (_tool) {
      _Tool.crop => _buildCropTools(),
      _Tool.adjust => _buildAdjustTools(),
      _Tool.filters => _buildFilterTools(),
    };
    return Column(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (_isRaw)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Editing the embedded preview '
                    '(${_source!.width} × ${_source!.height}). '
                    'The raw file is not changed; edits are saved as a copy.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: SegmentedButton<_Tool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Tool.crop, icon: Icon(Icons.crop_rotate), label: Text('Crop')),
              ButtonSegment(value: _Tool.adjust, icon: Icon(Icons.tune), label: Text('Adjust')),
              ButtonSegment(value: _Tool.filters, icon: Icon(Icons.filter), label: Text('Filters')),
            ],
            selected: {_tool},
            onSelectionChanged: (s) => setState(() => _tool = s.first),
          ),
        ),
        if (wide) Expanded(child: SingleChildScrollView(child: content)) else content,
      ],
    );
  }

  Widget _buildCropTools() {
    final original = _source!.width / _source!.height;
    final oriented = _edits.quarterTurns.isOdd ? 1 / original : original;
    final ratios = <String, double?>{
      'Free': null,
      'Original': oriented,
      '1:1': 1,
      '4:3': 4 / 3,
      '3:4': 3 / 4,
      '16:9': 16 / 9,
      '9:16': 9 / 16,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.rotate_left),
                tooltip: 'Rotate left',
                onPressed: () => _rotate(3),
              ),
              IconButton(
                icon: const Icon(Icons.rotate_right),
                tooltip: 'Rotate right',
                onPressed: () => _rotate(1),
              ),
              IconButton(
                icon: const Icon(Icons.flip),
                tooltip: 'Flip horizontally',
                isSelected: _edits.flipHorizontal,
                onPressed: () => setState(
                    () => _edits.flipHorizontal = !_edits.flipHorizontal),
              ),
              IconButton(
                icon: const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)),
                tooltip: 'Flip vertically',
                isSelected: _edits.flipVertical,
                onPressed: () =>
                    setState(() => _edits.flipVertical = !_edits.flipVertical),
              ),
            ],
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final e in ratios.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(e.key),
                      selected: e.value == null
                          ? _aspect == null
                          : _aspect != null && (_aspect! - e.value!).abs() < 1e-6,
                      onSelected: (_) => _setAspect(e.value),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdjustTools() {
    Widget slider(String label, double value, ValueChanged<double> onChanged) {
      return Row(
        children: [
          SizedBox(width: 92, child: Text(label)),
          Expanded(
            child: Slider(
              value: value,
              min: -100,
              max: 100,
              divisions: 200,
              label: value.round().toString(),
              onChanged: (v) => setState(() => onChanged(v)),
            ),
          ),
          SizedBox(width: 36, child: Text(value.round().toString())),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          slider('Brightness', _edits.brightness, (v) => _edits.brightness = v),
          slider('Contrast', _edits.contrast, (v) => _edits.contrast = v),
          slider('Saturation', _edits.saturation, (v) => _edits.saturation = v),
        ],
      ),
    );
  }

  Widget _buildFilterTools() {
    const names = {
      ImageFilterPreset.none: 'Original',
      ImageFilterPreset.vivid: 'Vivid',
      ImageFilterPreset.warm: 'Warm',
      ImageFilterPreset.cool: 'Cool',
      ImageFilterPreset.grayscale: 'Mono',
      ImageFilterPreset.sepia: 'Sepia',
      ImageFilterPreset.invert: 'Invert',
    };
    return SizedBox(
      height: 112,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        children: [
          for (final e in names.entries)
            GestureDetector(
              onTap: () => setState(() => _edits.filter = e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _edits.filter == e.key
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(
                          (ImageEdits()..filter = e.key).colorMatrix() ??
                              const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
                        ),
                        child: Image(
                          image: ResizeImage(
                            ImageCodec.providerFor(widget.file),
                            width: 128,
                          ),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(e.value, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Darkens everything outside a normalised crop rect.
class _DimPainter extends CustomPainter {
  _DimPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.6));
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.rect != rect;
}

/// Interactive crop rectangle in normalised coordinates.
class _CropOverlay extends StatelessWidget {
  const _CropOverlay({
    required this.rect,
    required this.displaySize,
    required this.onChanged,
    this.pixelAspect,
  });

  final Rect rect;
  final Size displaySize;

  /// Required normalised width/height ratio, or null for free cropping.
  final double? pixelAspect;
  final ValueChanged<Rect> onChanged;

  static const _minSize = 0.05;
  static const _handle = 28.0;

  Rect _clamp(Rect r) {
    final w = r.width.clamp(_minSize, 1.0);
    final h = r.height.clamp(_minSize, 1.0);
    final left = r.left.clamp(0.0, 1.0 - w);
    final top = r.top.clamp(0.0, 1.0 - h);
    return Rect.fromLTWH(left, top, w, h);
  }

  void _dragCorner(Alignment corner, Offset delta) {
    final dx = delta.dx / displaySize.width;
    final dy = delta.dy / displaySize.height;
    var left = rect.left, top = rect.top, right = rect.right, bottom = rect.bottom;
    if (corner.x < 0) {
      left += dx;
    } else {
      right += dx;
    }
    if (corner.y < 0) {
      top += dy;
    } else {
      bottom += dy;
    }
    left = left.clamp(0.0, right - _minSize);
    right = right.clamp(left + _minSize, 1.0);
    top = top.clamp(0.0, bottom - _minSize);
    bottom = bottom.clamp(top + _minSize, 1.0);
    final aspect = pixelAspect;
    if (aspect != null) {
      final width = right - left;
      var height = width / aspect;
      if (corner.y < 0) {
        top = bottom - height;
        if (top < 0) {
          top = 0;
          height = bottom;
        }
      } else {
        bottom = top + height;
        if (bottom > 1) {
          bottom = 1;
          height = 1 - top;
        }
      }
      final fixedWidth = height * aspect;
      if (corner.x < 0) {
        left = right - fixedWidth;
      } else {
        right = left + fixedWidth;
      }
    }
    onChanged(_clamp(Rect.fromLTRB(left, top, right, bottom)));
  }

  @override
  Widget build(BuildContext context) {
    final r = Rect.fromLTRB(
      rect.left * displaySize.width,
      rect.top * displaySize.height,
      rect.right * displaySize.width,
      rect.bottom * displaySize.height,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: CustomPaint(painter: _DimPainter(rect))),
        Positioned.fromRect(
          rect: r,
          child: GestureDetector(
            onPanUpdate: (d) => onChanged(_clamp(rect.shift(Offset(
              d.delta.dx / displaySize.width,
              d.delta.dy / displaySize.height,
            )))),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: CustomPaint(painter: _GridPainter()),
            ),
          ),
        ),
        for (final corner in const [
          Alignment.topLeft,
          Alignment.topRight,
          Alignment.bottomLeft,
          Alignment.bottomRight,
        ])
          Positioned(
            left: (corner.x < 0 ? r.left : r.right) - _handle / 2,
            top: (corner.y < 0 ? r.top : r.bottom) - _handle / 2,
            width: _handle,
            height: _handle,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => _dragCorner(corner, d.delta),
              child: Center(
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.5;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), paint);
      canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}
