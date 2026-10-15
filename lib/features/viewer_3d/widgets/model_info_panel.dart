import 'dart:math' as math;

import 'package:explorer/features/viewer_3d/models/viewer_3d_models.dart';
import 'package:explorer/features/viewer_3d/services/three_d_viewer_controller.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Model details and scene controls.
///
/// Used as the docked side pane on wide screens and inside a bottom sheet on
/// phones. Rebuilds itself from [controller].
class ModelInfoPanel extends StatelessWidget {
  const ModelInfoPanel({
    super.key,
    required this.controller,
    required this.fileName,
    required this.fileSize,
    required this.onScreenshot,
    this.scrollable = true,
    this.onClose,
  });

  final ThreeDViewerController controller;
  final String fileName;
  final int? fileSize;
  final VoidCallback onScreenshot;

  /// False when the parent already scrolls (bottom sheet).
  final bool scrollable;

  /// Shows a close button in the header (docked pane).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final children = _buildChildren(context);
        if (!scrollable) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: children,
        );
      },
    );
  }

  List<Widget> _buildChildren(BuildContext context) {
    final fg = ClearGlassForeground.icon(context);
    final muted = fg.withValues(alpha: 0.68);
    final theme = Theme.of(context);
    final stats = controller.stats;
    final ready = controller.isReady;

    final subtitle = [
      if (stats != null && stats.format.isNotEmpty) stats.format,
      if (fileSize != null) filesize(fileSize),
    ].join(' · ');

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ClearGlassForeground.title(context),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: muted, fontSize: 13)),
                ],
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: Icon(Icons.close, color: fg),
              tooltip: 'Hide details',
              onPressed: onClose,
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (!ready)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            controller.phase == ViewerPhase.error
                ? (controller.errorMessage ?? 'The model could not be displayed.')
                : 'Loading model…',
            style: TextStyle(color: muted),
          ),
        ),
      if (controller.warnings.isNotEmpty)
        _WarningsBox(warnings: controller.warnings),
      if (stats != null) ...[
        _SectionTitle('Model', color: muted),
        _StatsTable(stats: stats, color: fg, muted: muted),
      ],
      if (ready && controller.clips.isNotEmpty) ...[
        _SectionTitle('Animations', color: muted),
        _AnimationList(controller: controller, color: fg, muted: muted),
      ],
      if (ready) ...[
        _SectionTitle('View', color: muted),
        _ToggleRow(
          icon: Icons.threesixty,
          label: 'Auto-rotate',
          value: controller.autoRotate,
          onChanged: controller.setAutoRotate,
          color: fg,
        ),
        if (controller.hasMeshes)
          _ToggleRow(
            icon: Icons.change_history,
            label: 'Wireframe',
            value: controller.wireframe,
            onChanged: controller.setWireframe,
            color: fg,
          ),
        _ToggleRow(
          icon: Icons.grid_4x4,
          label: 'Ground grid',
          value: controller.grid,
          onChanged: controller.setGrid,
          color: fg,
        ),
        _ToggleRow(
          icon: Icons.open_with,
          label: 'Axes',
          value: controller.axes,
          onChanged: controller.setAxes,
          color: fg,
        ),
        _ToggleRow(
          icon: Icons.screen_rotation_alt,
          label: 'Z axis is up',
          value: controller.zUp,
          onChanged: controller.setZUp,
          color: fg,
        ),
        if (controller.hasMeshes) ...[
          _SectionTitle('Shading', color: muted),
          SegmentedButton<ViewerShading>(
            segments: [
              for (final s in ViewerShading.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {controller.shading},
            showSelectedIcon: false,
            onSelectionChanged: (v) => controller.setShading(v.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ],
        if (controller.hasPoints) ...[
          _SectionTitle('Point size', color: muted),
          Slider(
            // Logarithmic scale: -2..2 maps to 0.25×..4×.
            value: (math.log(controller.pointScale) / math.ln2).clamp(-2.0, 2.0),
            min: -2,
            max: 2,
            divisions: 16,
            label: '${controller.pointScale.toStringAsFixed(2)}×',
            onChanged: (v) => controller.setPointScale(
              double.parse(math.pow(2, v).toStringAsFixed(3)),
            ),
          ),
        ],
        _SectionTitle('Background', color: muted),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final b in ViewerBackground.values)
              ChoiceChip(
                label: Text(b.label),
                selected: controller.background == b,
                onSelected: (_) => controller.setBackground(b),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: controller.resetView,
                icon: const Icon(Icons.center_focus_strong_outlined),
                label: const Text('Reset view'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onScreenshot,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Screenshot'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Drag to rotate · pinch to zoom · two fingers to pan · double-tap to reset',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _WarningsBox extends StatelessWidget {
  const _WarningsBox({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onTertiaryContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      w,
                      style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsTable extends StatelessWidget {
  const _StatsTable({
    required this.stats,
    required this.color,
    required this.muted,
  });

  final ModelStats stats;
  final Color color;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final n = NumberFormat.decimalPattern();
    final rows = <(String, String)>[
      if (stats.meshes > 0) ('Meshes', n.format(stats.meshes)),
      ('Vertices', n.format(stats.vertices)),
      if (stats.meshes > 0) ('Triangles', n.format(stats.triangles)),
      if (stats.points > 0) ('Points', n.format(stats.points)),
      if (stats.lines > 0) ('Line segments', n.format(stats.lines)),
      if (stats.meshes > 0) ('Materials', n.format(stats.materials)),
      if (stats.meshes > 0) ('Textures', n.format(stats.textures)),
      if (stats.skinnedMeshes > 0) ('Skinned meshes', n.format(stats.skinnedMeshes)),
      ('Animations', n.format(stats.animations)),
      (
        'Size (W × H × D)',
        '${_dim(stats.sizeX)} × ${_dim(stats.sizeY)} × ${_dim(stats.sizeZ)}',
      ),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(child: Text(label, style: TextStyle(color: muted))),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            'Sizes are in model units',
            style: TextStyle(color: muted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  static String _dim(double v) {
    final a = v.abs();
    if (a == 0) return '0';
    if (a >= 1000) return v.toStringAsFixed(0);
    if (a >= 100) return v.toStringAsFixed(1);
    if (a >= 1) return _trim(v.toStringAsFixed(2));
    return _trim(v.toStringAsPrecision(3));
  }

  static String _trim(String s) =>
      s.contains('.') && !s.contains('e') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

class _AnimationList extends StatelessWidget {
  const _AnimationList({
    required this.controller,
    required this.color,
    required this.muted,
  });

  final ThreeDViewerController controller;
  final Color color;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final clips = controller.clips;
    final primary = Theme.of(context).colorScheme.primary;
    Widget tile({
      required int index,
      required String title,
      String? subtitle,
    }) {
      final active = controller.animationIndex == index;
      final playing = active && controller.animationPlaying;
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          playing ? Icons.pause_circle_filled : Icons.play_circle_outline,
          color: active ? primary : color,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? primary : color,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: TextStyle(color: muted, fontSize: 12)),
        onTap: () => active
            ? controller.toggleAnimation()
            : controller.playAnimation(index),
      );
    }

    return Column(
      children: [
        for (final clip in clips)
          tile(
            index: clip.index,
            title: clip.name,
            subtitle: '${clip.duration.toStringAsFixed(2)} s',
          ),
        if (clips.length > 1) tile(index: -1, title: 'Play all together'),
        if (controller.animationIndex != -2)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: controller.stopAnimation,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.color,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: color, size: 20),
      title: Text(label, style: TextStyle(color: color)),
      value: value,
      onChanged: onChanged,
    );
  }
}
