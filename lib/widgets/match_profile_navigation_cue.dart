import 'package:flutter/material.dart';

class MatchProfileNavigationCue extends StatelessWidget {
  /// Retained for API compatibility. The icon no longer branches on it:
  /// `Icons.chevron_right_rounded` auto-mirrors in RTL, so the ambient
  /// [Directionality] decides the painted direction.
  final TextDirection textDirection;
  final String label;

  const MatchProfileNavigationCue({
    super.key,
    required this.textDirection,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: ExcludeSemantics(
        // Always use chevron_right_rounded: the glyph carries
        // `matchTextDirection: true`, so `Icon` mirrors it to point left
        // automatically in RTL (Hebrew/Arabic). Manually switching to
        // chevron_left_rounded in RTL would mirror twice and point right.
        child: Icon(
          Icons.chevron_right_rounded,
          size: 24,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
