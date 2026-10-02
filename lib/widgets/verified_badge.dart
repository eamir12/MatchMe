// lib/widgets/verified_badge.dart
// Widget to display a verified badge on user profiles

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

class VerifiedBadge extends ConsumerWidget {
  final double size;
  final bool showText;
  final String? text;

  const VerifiedBadge({
    super.key,
    this.size = 18.0,
    this.showText = false,
    this.text,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = ref.watch(localizationProvider);
    final displayText = text ?? l10n.getString('verified');

    return Semantics(
      container: true,
      label: displayText,
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: showText ? 10.0 : 4.0,
            vertical: 4.0,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(size * 0.6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: Directionality.of(context),
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
                Icon(
                  Icons.verified,
                  color: theme.colorScheme.onPrimary,
                  size: size,
                ),
                if (showText) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      displayText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A smaller, more subtle version of the verified badge
class VerifiedBadgeSmall extends ConsumerWidget {
  final double size;

  const VerifiedBadgeSmall({super.key, this.size = 12.0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = ref.watch(localizationProvider);

    return Semantics(
      container: true,
      label: l10n.getString('verified'),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(1.0),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.9),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.verified,
            color: theme.colorScheme.onPrimary,
            size: size,
          ),
        ),
      ),
    );
  }
}

/// A widget that shows verified status with conditional rendering
class VerifiedStatusIndicator extends StatelessWidget {
  final bool isVerified;
  final double size;
  final bool showText;

  const VerifiedStatusIndicator({
    super.key,
    required this.isVerified,
    this.size = 16.0,
    this.showText = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isVerified) {
      return const SizedBox.shrink();
    }

    return VerifiedBadge(size: size, showText: showText);
  }
}
