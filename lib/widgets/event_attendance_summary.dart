import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';

class EventAttendanceSummary extends StatelessWidget {
  final int? attendeeCount;
  final LocalizationState l10n;
  final EdgeInsetsGeometry padding;

  const EventAttendanceSummary({
    super.key,
    required this.attendeeCount,
    required this.l10n,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final count = attendeeCount ?? 0;
    // The user is always attending on this screen, so nothing to say for 0/1.
    if (count <= 1) return const SizedBox.shrink();

    final countText = l10n.getString(
      'eventAttendeeCount',
      params: {'count': count.toString()},
    );

    return Semantics(
      container: true,
      label: countText,
      excludeSemantics: true,
      child: Padding(
        padding: padding,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Icon(
              Icons.event_available_outlined,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            Text(
              countText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
