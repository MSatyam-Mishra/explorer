import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Options sheet: view, sorting, appearance and sharing.
class ExplorerOptionsSheet extends StatelessWidget {
  const ExplorerOptionsSheet({
    super.key,
    required this.fileState,
    required this.onHttpShare,
    required this.onSortChanged,
    required this.onViewModeChanged,
  });

  final FileExplorerLoaded fileState;
  final VoidCallback onHttpShare;
  final void Function(SortOption option, SortOrder order) onSortChanged;
  final void Function(ViewMode mode) onViewModeChanged;

  static Future<void> show(
    BuildContext context, {
    required FileExplorerLoaded fileState,
    required VoidCallback onHttpShare,
    required void Function(SortOption option, SortOrder order) onSortChanged,
    required void Function(ViewMode mode) onViewModeChanged,
  }) {
    return AppSheet.show<void>(
      context,
      child: ExplorerOptionsSheet(
        fileState: fileState,
        onHttpShare: onHttpShare,
        onSortChanged: onSortChanged,
        onViewModeChanged: onViewModeChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeCubit>().state;
    final cubit = context.read<ThemeCubit>();
    final text = Theme.of(context).textTheme;
    final ascending = fileState.sortOrder == SortOrder.ascending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Options', style: text.titleLarge),
        const SizedBox(height: 4),
        Text('View, sorting and appearance.', style: text.bodySmall),
        const _Heading('Layout'),
        SegmentedButton<ViewMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ViewMode.list, label: Text('List')),
            ButtonSegment(value: ViewMode.grid, label: Text('Grid')),
            ButtonSegment(value: ViewMode.compact, label: Text('Compact')),
            ButtonSegment(value: ViewMode.gallery, label: Text('Gallery')),
          ],
          selected: {fileState.viewMode},
          onSelectionChanged: (s) => onViewModeChanged(s.first),
        ),
        const _Heading('Sort by'),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<SortOption>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: SortOption.name, label: Text('Name')),
                  ButtonSegment(value: SortOption.date, label: Text('Date')),
                  ButtonSegment(value: SortOption.size, label: Text('Size')),
                  ButtonSegment(value: SortOption.type, label: Text('Type')),
                ],
                selected: {fileState.sortOption},
                onSelectionChanged: (s) =>
                    onSortChanged(s.first, fileState.sortOrder),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => onSortChanged(
                fileState.sortOption,
                ascending ? SortOrder.descending : SortOrder.ascending,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
              ),
              child: Tooltip(
                message: ascending ? 'Ascending' : 'Descending',
                child: Icon(
                  ascending
                      ? LucideIcons.arrowUpNarrowWide
                      : LucideIcons.arrowDownWideNarrow,
                  size: 18,
                ),
              ),
            ),
          ],
        ),
        const _Heading('Theme'),
        SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(LucideIcons.monitor, size: 16),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(LucideIcons.sun, size: 16),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(LucideIcons.moon, size: 16),
              label: Text('Dark'),
            ),
          ],
          selected: {settings.themeMode},
          onSelectionChanged: (s) => cubit.setThemeMode(s.first),
        ),
        const _Heading('Color'),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final spec in AppColorThemes.all)
              _Swatch(
                spec: spec,
                selected: settings.colorThemeId == spec.id,
                onTap: () => cubit.setColorTheme(spec.id),
              ),
          ],
        ),
        const _Heading('File icons'),
        SegmentedButton<FileIconStyle>(
          showSelectedIcon: false,
          segments: [
            for (final style in FileIconStyle.values)
              ButtonSegment(
                value: style,
                icon: FileIcon(path: 'preview.pdf', size: 18, style: style),
                label: Text(style.label),
              ),
          ],
          selected: {settings.fileIconStyle},
          onSelectionChanged: (s) => cubit.setFileIconStyle(s.first),
        ),
        const _Heading('Sharing'),
        _ActionRow(
          icon: LucideIcons.globe,
          title: 'HTTP file server',
          subtitle: 'Share this folder with devices on your network',
          onTap: () {
            Navigator.pop(context);
            onHttpShare();
          },
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final AppColorThemeSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final swatch = spec.swatch;
    return Tooltip(
      message: spec.name,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? colors.foreground : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: swatch,
              border: Border.all(color: colors.border),
            ),
            child: selected
                ? const Icon(LucideIcons.check, size: 16, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: colors.foreground),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(subtitle, style: text.bodySmall),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: colors.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
