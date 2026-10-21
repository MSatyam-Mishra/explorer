import 'package:flutter/material.dart';

/// Bottom sheet with the app's sheet styling (drag handle, rounded top,
/// border; see the bottomSheetTheme in AppTheme) and scrolling content.
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.child,
    this.maxHeightFraction = 0.85,
    // Kept for callers of the previous glass sheet; unused.
    this.horizontalMargin,
    this.bottomMargin,
    this.cornerRadius,
  });

  final Widget child;
  final double maxHeightFraction;
  final double? horizontalMargin;
  final double? bottomMargin;
  final double? cornerRadius;

  static Future<T?> show<T>(
    BuildContext context, {
    required Widget child,
    double maxHeightFraction = 0.85,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => AppSheet(
        maxHeightFraction: maxHeightFraction,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: media.size.height * maxHeightFraction,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + media.viewInsets.bottom + media.padding.bottom,
        ),
        child: child,
      ),
    );
  }
}
