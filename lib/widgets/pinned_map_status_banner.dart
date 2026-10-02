import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';

class PinnedMapStatusBanner extends ConsumerWidget {
  final PinnedLocationState pin;
  final LocalizationState l10n;

  const PinnedMapStatusBanner({
    super.key,
    required this.pin,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!pin.isActive) return const SizedBox.shrink();
    // The banner describes the position broadcast to other users. While the
    // user is invisible nothing is broadcast, so the banner is irrelevant
    // and stays hidden.
    final isVisible = ref.watch(isVisibleProvider);
    if (!isVisible) return const SizedBox.shrink();

    final label = pin.label?.trim();
    final labelPart = label == null || label.isEmpty ? '' : ' ($label)';
    final message = l10n.getString(
      'pinnedLocationBanner',
      params: {'label': labelPart},
    );
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      excludeSemantics: true,
      child: Material(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.push_pin_outlined,
                size: 18,
                color: colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
