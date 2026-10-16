import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:explorer/shared/icons/app_icons.dart';
import 'package:explorer/shared/liquid_glass/explorer_liquid_glass.dart';
import 'package:explorer/shared/widgets/theme_palette_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Options sheet with liquid-glass panel (sort, view, themes, etc.).
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
    return ExplorerLiquidGlassBottomSheet.show<void>(
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
    final themeSettings = context.watch<ThemeCubit>().state;
    final appearance = themeSettings.colorTheme.appearanceFor(
      themeSettings.isDark ? Brightness.dark : Brightness.light,
    );
    final fg = ExplorerLiquidGlassForeground.icon(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Options',
          style: ExplorerLiquidGlassForeground.title(context),
        ),
        const SizedBox(height: 16),
        _SectionLabel('Sort by', color: appearance.textSecondary),
        _SortSection(
          currentOption: fileState.sortOption,
          currentOrder: fileState.sortOrder,
          onChanged: onSortChanged,
        ),
        const SizedBox(height: 12),
        _SectionLabel('View mode', color: appearance.textSecondary),
        _ViewModeSection(
          current: fileState.viewMode,
          onChanged: onViewModeChanged,
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: AppIcons.globe(color: fg),
          title: Text(
            'HTTP file server',
            style: TextStyle(color: fg),
          ),
          subtitle: Text(
            'Share this folder on your network',
            style: TextStyle(
              color: appearance.textSecondary,
            ),
          ),
          onTap: () {
            Navigator.pop(context);
            onHttpShare();
          },
        ),
        Divider(color: fg.withValues(alpha: 0.15), height: 1),
        _SectionLabel('Theme mode', color: appearance.textSecondary),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: themeSettings.isDark
              ? AppIcons.moon(color: fg)
              : AppIcons.sun(color: fg),
          title: Text(
            themeSettings.isDark ? 'Night mode' : 'Day mode',
            style: TextStyle(color: fg),
          ),
          subtitle: Text(
            'Tap to switch light / dark',
            style: TextStyle(color: appearance.textSecondary),
          ),
          value: themeSettings.isDark,
          onChanged: (_) {
            context.read<ThemeCubit>().toggleBrightness();
          },
        ),
        const SizedBox(height: 8),
        _SectionLabel('File icons', color: appearance.textSecondary),
        Wrap(
          spacing: 8,
          children: [
            for (final style in FileIconStyle.values)
              ChoiceChip(
                avatar: FileIcon(path: 'preview.pdf', size: 20, style: style),
                label: Text(style.label),
                selected: themeSettings.fileIconStyle == style,
                onSelected: (_) =>
                    context.read<ThemeCubit>().setFileIconStyle(style),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _SectionLabel('Color theme', color: appearance.textSecondary),
        ...AppColorThemes.all.map(
          (spec) => _ColorThemeTile(
            spec: spec,
            selected: themeSettings.colorThemeId == spec.id,
            onTap: () {
              context.read<ThemeCubit>().setColorTheme(spec.id);
            },
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.06,
          color: color,
        ),
      ),
    );
  }
}

class _SortSection extends StatelessWidget {
  const _SortSection({
    required this.currentOption,
    required this.currentOrder,
    required this.onChanged,
  });

  final SortOption currentOption;
  final SortOrder currentOrder;
  final void Function(SortOption option, SortOrder order) onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in SortOption.values)
          FilterChip(
            label: Text(_sortLabel(option)),
            selected: currentOption == option,
            onSelected: (_) => onChanged(option, currentOrder),
          ),
        FilterChip(
          label: const Text('Ascending'),
          selected: currentOrder == SortOrder.ascending,
          onSelected: (_) => onChanged(currentOption, SortOrder.ascending),
        ),
        FilterChip(
          label: const Text('Descending'),
          selected: currentOrder == SortOrder.descending,
          onSelected: (_) => onChanged(currentOption, SortOrder.descending),
        ),
      ],
    );
  }

  String _sortLabel(SortOption option) {
    return switch (option) {
      SortOption.name => 'Name',
      SortOption.size => 'Size',
      SortOption.date => 'Date',
      SortOption.type => 'Type',
    };
  }
}

class _ViewModeSection extends StatelessWidget {
  const _ViewModeSection({
    required this.current,
    required this.onChanged,
  });

  final ViewMode current;
  final void Function(ViewMode mode) onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final mode in ViewMode.values)
          ChoiceChip(
            label: Text(_viewLabel(mode)),
            selected: current == mode,
            onSelected: (_) => onChanged(mode),
          ),
      ],
    );
  }

  String _viewLabel(ViewMode mode) {
    return switch (mode) {
      ViewMode.list => 'List',
      ViewMode.grid => 'Grid',
      ViewMode.compact => 'Compact',
      ViewMode.gallery => 'Gallery',
    };
  }
}

class _ColorThemeTile extends StatelessWidget {
  const _ColorThemeTile({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final AppColorThemeSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final themeSettings = context.watch<ThemeCubit>().state;
    final appearance = spec.appearanceFor(
      themeSettings.isDark ? Brightness.dark : Brightness.light,
    );
    final fg = ExplorerLiquidGlassForeground.icon(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ThemePaletteCircle(
        colors: spec.paletteSwatches,
        selected: selected,
      ),
      title: Text(
        spec.name,
        style: TextStyle(
          color: appearance.textPrimary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      trailing: selected ? AppIcons.check(color: fg) : null,
      onTap: onTap,
    );
  }
}
