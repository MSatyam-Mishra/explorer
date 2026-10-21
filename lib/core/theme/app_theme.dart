import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The app's look: shadcn/ui ([ShadThemeData]) plus a Material theme built
/// from the same tokens, so Material widgets used across the viewers match
/// the shadcn components in light and dark mode.
abstract final class AppTheme {
  static const double iconSize = 20;

  /// Corner radius of controls (buttons, inputs, menus): shadcn `rounded-md`.
  static const double controlRadius = 8;

  /// Corner radius of surfaces (cards, dialogs, sheets): shadcn `rounded-xl`.
  static const double surfaceRadius = 12;

  static ShadThemeData shad(AppThemeSettings settings, Brightness brightness) =>
      ShadThemeData(
        brightness: brightness,
        colorScheme: settings.colorTheme.schemeFor(brightness),
        radius: BorderRadius.circular(controlRadius),
      );

  /// Completes the Material theme [ShadApp] derived from [shad].
  static ThemeData material(ThemeData base, ShadThemeData shad) {
    final c = shad.colorScheme;
    final dark = shad.brightness == Brightness.dark;
    final control = BorderRadius.circular(controlRadius);
    final surface = BorderRadius.circular(surfaceRadius);
    final hover = c.accent;

    final scheme = ColorScheme(
      brightness: shad.brightness,
      primary: c.primary,
      onPrimary: c.primaryForeground,
      primaryContainer: c.secondary,
      onPrimaryContainer: c.secondaryForeground,
      secondary: c.secondary,
      onSecondary: c.secondaryForeground,
      secondaryContainer: c.accent,
      onSecondaryContainer: c.accentForeground,
      tertiary: c.primary,
      onTertiary: c.primaryForeground,
      error: c.destructive,
      onError: c.destructiveForeground,
      errorContainer: c.destructive.withValues(alpha: 0.12),
      onErrorContainer: c.destructive,
      surface: c.background,
      onSurface: c.foreground,
      onSurfaceVariant: c.mutedForeground,
      surfaceDim: c.muted,
      surfaceBright: c.background,
      surfaceContainerLowest: c.background,
      surfaceContainerLow: c.card,
      surfaceContainer: c.card,
      surfaceContainerHigh: c.muted,
      surfaceContainerHighest: c.muted,
      outline: c.border,
      outlineVariant: c.border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: c.foreground,
      onInverseSurface: c.background,
      inversePrimary: c.primaryForeground,
      surfaceTint: Colors.transparent,
    );

    final text = base.textTheme
        .apply(bodyColor: c.foreground, displayColor: c.foreground)
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
            color: c.foreground,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: c.foreground,
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: c.foreground,
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            fontSize: 16,
            color: c.foreground,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: c.foreground,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: c.mutedForeground,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          labelMedium: base.textTheme.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: c.mutedForeground,
          ),
        );

    ButtonStyle buttonStyle({
      required Color background,
      required Color foreground,
      BorderSide? side,
    }) =>
        ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? background.withValues(alpha: background.a * 0.5)
                : background,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? foreground.withValues(alpha: 0.5)
                : foreground,
          ),
          overlayColor: WidgetStatePropertyAll(
            foreground.withValues(alpha: 0.08),
          ),
          elevation: const WidgetStatePropertyAll(0),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: control),
          ),
          side: side == null ? null : WidgetStatePropertyAll(side),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
        );

    final outlined = OutlineInputBorder(
      borderRadius: control,
      borderSide: BorderSide(color: c.input),
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      cardColor: c.card,
      dividerColor: c.border,
      hoverColor: hover.withValues(alpha: 0.6),
      focusColor: c.ring.withValues(alpha: 0.2),
      highlightColor: c.foreground.withValues(alpha: 0.04),
      splashColor: c.foreground.withValues(alpha: 0.06),
      splashFactory: InkRipple.splashFactory,
      textTheme: text,
      iconTheme: IconThemeData(size: iconSize, color: c.foreground),
      primaryIconTheme: IconThemeData(size: iconSize, color: c.primaryForeground),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.foreground,
        centerTitle: false,
        titleTextStyle: text.titleMedium,
        iconTheme: IconThemeData(color: c.foreground, size: iconSize),
        actionsIconTheme: IconThemeData(color: c.foreground, size: iconSize),
        shape: Border(bottom: BorderSide(color: c.border)),
      ),
      cardTheme: CardThemeData(
        color: c.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: surface,
          side: BorderSide(color: c.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.15),
        shape: RoundedRectangleBorder(
          borderRadius: surface,
          side: BorderSide(color: c.border),
        ),
        titleTextStyle: text.titleLarge?.copyWith(fontSize: 18),
        contentTextStyle: text.bodyMedium?.copyWith(color: c.mutedForeground),
        barrierColor: Colors.black.withValues(alpha: 0.6),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.background,
        modalBackgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: c.border,
        dragHandleSize: const Size(40, 4),
        modalBarrierColor: Colors.black.withValues(alpha: 0.6),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          side: BorderSide(color: c.border),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        width: 300,
        scrimColor: Colors.black.withValues(alpha: 0.5),
        shape: Border(right: BorderSide(color: c.border)),
        endShape: Border(left: BorderSide(color: c.border)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.foreground,
        textColor: c.foreground,
        selectedColor: c.accentForeground,
        selectedTileColor: c.accent,
        titleTextStyle: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: text.bodySmall,
        leadingAndTrailingTextStyle: text.bodySmall,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minLeadingWidth: 24,
        horizontalTitleGap: 12,
        shape: RoundedRectangleBorder(borderRadius: control),
      ),
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: text.bodyMedium?.copyWith(color: c.mutedForeground),
        labelStyle: text.bodyMedium?.copyWith(color: c.mutedForeground),
        floatingLabelStyle: text.bodyMedium?.copyWith(color: c.foreground),
        helperStyle: text.bodySmall,
        prefixIconColor: c.mutedForeground,
        suffixIconColor: c.mutedForeground,
        border: outlined,
        enabledBorder: outlined,
        disabledBorder: outlined.copyWith(
          borderSide: BorderSide(color: c.input.withValues(alpha: 0.5)),
        ),
        focusedBorder: outlined.copyWith(
          borderSide: BorderSide(color: c.ring, width: 2),
        ),
        errorBorder: outlined.copyWith(
          borderSide: BorderSide(color: c.destructive),
        ),
        focusedErrorBorder: outlined.copyWith(
          borderSide: BorderSide(color: c.destructive, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: buttonStyle(background: c.primary, foreground: c.primaryForeground),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: buttonStyle(
          background: c.secondary,
          foreground: c.secondaryForeground,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: buttonStyle(
          background: Colors.transparent,
          foreground: c.foreground,
          side: BorderSide(color: c.input),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: buttonStyle(
          background: Colors.transparent,
          foreground: c.foreground,
        ).copyWith(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? c.mutedForeground.withValues(alpha: 0.5)
                : c.foreground,
          ),
          overlayColor: WidgetStatePropertyAll(
            c.foreground.withValues(alpha: 0.08),
          ),
          iconSize: const WidgetStatePropertyAll(iconSize),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: control),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.primary,
        foregroundColor: c.primaryForeground,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(borderRadius: surface),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? c.secondary
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? c.secondaryForeground
                : c.mutedForeground,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: c.border)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: control),
          ),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          visualDensity: VisualDensity.compact,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: c.secondary,
        disabledColor: c.muted,
        checkmarkColor: c.secondaryForeground,
        deleteIconColor: c.mutedForeground,
        labelStyle: text.labelLarge?.copyWith(color: c.foreground),
        secondaryLabelStyle:
            text.labelLarge?.copyWith(color: c.secondaryForeground),
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: control),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        showCheckmark: false,
        elevation: 0,
        pressElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.popover,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.12),
        textStyle: text.bodyMedium?.copyWith(color: c.popoverForeground),
        labelTextStyle: WidgetStatePropertyAll(
          text.bodyMedium?.copyWith(color: c.popoverForeground),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: control,
          side: BorderSide(color: c.border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.popover),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(6),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: control,
              side: BorderSide(color: c.border),
            ),
          ),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: text.bodyMedium,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.popover),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: control,
              side: BorderSide(color: c.border),
            ),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.foreground,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.background),
        actionTextColor: c.background,
        closeIconColor: c.background,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: control),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: text.bodySmall?.copyWith(color: c.primaryForeground),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 400),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(c.background),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.primary : c.input,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbIcon: const WidgetStatePropertyAll(null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? c.primary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(c.primaryForeground),
        side: BorderSide(color: c.primary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStatePropertyAll(c.primary),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.primary,
        inactiveTrackColor: c.secondary,
        thumbColor: c.background,
        overlayColor: c.primary.withValues(alpha: 0.12),
        trackHeight: 6,
        valueIndicatorColor: c.primary,
        valueIndicatorTextStyle:
            text.bodySmall?.copyWith(color: c.primaryForeground),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.primary,
        linearTrackColor: c.secondary,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 4,
        borderRadius: BorderRadius.circular(999),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: c.foreground,
        unselectedLabelColor: c.mutedForeground,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        indicatorColor: c.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: c.border,
        overlayColor: WidgetStatePropertyAll(
          c.foreground.withValues(alpha: 0.06),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.secondary,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.background,
        indicatorColor: c.secondary,
        selectedIconTheme: IconThemeData(color: c.secondaryForeground),
        unselectedIconTheme: IconThemeData(color: c.mutedForeground),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: c.primary,
        textColor: c.primaryForeground,
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(c.background),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: c.input)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: control),
        ),
        hintStyle: WidgetStatePropertyAll(
          text.bodyMedium?.copyWith(color: c.mutedForeground),
        ),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: c.mutedForeground,
        collapsedIconColor: c.mutedForeground,
        textColor: c.foreground,
        collapsedTextColor: c.foreground,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
    );
  }
}
