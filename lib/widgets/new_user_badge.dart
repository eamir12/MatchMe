// lib/widgets/new_user_badge.dart
// Widget to display a new user badge on profiles

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

class NewUserBadge extends ConsumerWidget {
  final double size;
  final bool showText;
  final String? text;
  final String? gender;

  const NewUserBadge({
    super.key,
    this.size = 18.0,
    this.showText = false,
    this.text,
    this.gender,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = ref.watch(localizationProvider);
    final displayText = text ?? l10n.getString('newUser');

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: showText ? 10.0 : 4.0,
        vertical: 4.0,
      ),
      decoration: BoxDecoration(
        color: Colors.green,
        borderRadius: BorderRadius.circular(size * 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // Follow the UI direction (RTL/LTR) explicitly so the icon stays
        // leading even when the badge is placed inside a differently-directed
        // text span (e.g. an LTR name inside an RTL profile row).
        textDirection: Directionality.of(context),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.fiber_new, color: Colors.white, size: size),
          if (showText) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                displayText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A smaller, more subtle version of the new user badge
class NewUserBadgeSmall extends StatelessWidget {
  final double size;

  const NewUserBadgeSmall({super.key, this.size = 12.0});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(1.0),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.fiber_new, color: Colors.white, size: size),
    );
  }
}

/// A widget that shows new user status with conditional rendering
class NewUserStatusIndicator extends StatelessWidget {
  final DateTime? createdAt;
  final double size;
  final bool showText;
  final String? text;
  final String? gender;

  const NewUserStatusIndicator({
    super.key,
    required this.createdAt,
    this.size = 16.0,
    this.showText = false,
    this.text,
    this.gender,
  });

  bool get _isNewUser {
    if (createdAt == null) return false;
    final now = DateTime.now();
    final difference = now.difference(createdAt!);
    return difference.inDays < 7;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isNewUser) {
      return const SizedBox.shrink();
    }

    return NewUserBadge(
      size: size,
      showText: showText,
      text: text,
      gender: gender,
    );
  }
}
