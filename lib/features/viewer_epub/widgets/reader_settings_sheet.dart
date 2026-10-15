import 'package:flutter/material.dart';

import '../reader/reader_settings.dart';

/// Appearance settings; every change is applied live through [onChanged].
class ReaderSettingsSheet extends StatefulWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
    this.fixedLayout = false,
  });

  final ReaderSettings initial;
  final ValueChanged<ReaderSettings> onChanged;

  /// Fixed-layout books ignore most typography settings.
  final bool fixedLayout;

  static Future<void> show(
    BuildContext context, {
    required ReaderSettings initial,
    required ValueChanged<ReaderSettings> onChanged,
    bool fixedLayout = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => ReaderSettingsSheet(
        initial: initial,
        onChanged: onChanged,
        fixedLayout: fixedLayout,
      ),
    );
  }

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late ReaderSettings _s = widget.initial;

  void _set(ReaderSettings s) {
    if (s == _s) return;
    setState(() => _s = s);
    widget.onChanged(s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reading settings', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            _label(context, 'Theme'),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (final t in ReaderTheme.values) _themeSwatch(context, t),
              ],
            ),
            if (!widget.fixedLayout) ...[
              const SizedBox(height: 20),
              _label(context, 'Text size'),
              Row(
                children: [
                  IconButton.outlined(
                    tooltip: 'Smaller text',
                    icon: const Icon(Icons.text_decrease),
                    onPressed: _s.fontScale <= 0.6
                        ? null
                        : () => _set(_s.copyWith(
                              fontScale: _round(_s.fontScale - 0.1, 0.6, 2.5),
                            )),
                  ),
                  Expanded(
                    child: Slider(
                      value: _s.fontScale.clamp(0.6, 2.5),
                      min: 0.6,
                      max: 2.5,
                      divisions: 19,
                      label: '${(_s.fontScale * 100).round()}%',
                      onChanged: (v) =>
                          _set(_s.copyWith(fontScale: _round(v, 0.6, 2.5))),
                    ),
                  ),
                  IconButton.outlined(
                    tooltip: 'Larger text',
                    icon: const Icon(Icons.text_increase),
                    onPressed: _s.fontScale >= 2.5
                        ? null
                        : () => _set(_s.copyWith(
                              fontScale: _round(_s.fontScale + 0.1, 0.6, 2.5),
                            )),
                  ),
                ],
              ),
              Center(
                child: Text(
                  '${(_s.fontScale * 100).round()}%',
                  style: theme.textTheme.labelMedium,
                ),
              ),
              const SizedBox(height: 16),
              _label(context, 'Font'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in ReaderFont.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: _s.font == f,
                      onSelected: (_) => _set(_s.copyWith(font: f)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _label(context, 'Line spacing'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final lh in ReaderSettings.lineHeights)
                    ChoiceChip(
                      label: Text(lh == null ? 'Publisher' : lh.toStringAsFixed(1)),
                      selected: _s.lineHeight == lh,
                      onSelected: (_) => _set(_s.copyWith(lineHeight: () => lh)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _label(context, 'Margins'),
              Slider(
                value: _s.margin.clamp(0, 80),
                min: 0,
                max: 80,
                divisions: 10,
                label: '${_s.margin.round()} px',
                onChanged: (v) => _set(_s.copyWith(margin: v.roundToDouble())),
              ),
              _label(context, 'Alignment'),
              SegmentedButton<ReaderAlign>(
                segments: [
                  for (final a in ReaderAlign.values)
                    ButtonSegment(value: a, label: Text(a.label)),
                ],
                selected: {_s.align},
                showSelectedIcon: false,
                onSelectionChanged: (v) => _set(_s.copyWith(align: v.first)),
              ),
              const SizedBox(height: 20),
              _label(context, 'Layout'),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.auto_stories_outlined),
                    label: Text('Pages'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.swap_vert),
                    label: Text('Scroll'),
                  ),
                ],
                selected: {_s.paginated},
                showSelectedIcon: false,
                onSelectionChanged: (v) =>
                    _set(_s.copyWith(paginated: v.first)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Two-page spreads'),
                subtitle: const Text(
                  'On wide screens, landscape and unfolded foldables',
                ),
                value: _s.spreads,
                onChanged: _s.paginated
                    ? (v) => _set(_s.copyWith(spreads: v))
                    : null,
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset to defaults'),
                onPressed: () => _set(const ReaderSettings()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static double _round(double v, double min, double max) =>
      ((v * 10).round() / 10).clamp(min, max);

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );

  Widget _themeSwatch(BuildContext context, ReaderTheme t) {
    final selected = _s.theme == t;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${t.label} theme',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _set(_s.copyWith(theme: t)),
        child: Container(
          width: 72,
          height: 56,
          decoration: BoxDecoration(
            color: t.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Aa',
                style: TextStyle(
                  color: t.foreground,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                t.label,
                style: TextStyle(color: t.foreground, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
