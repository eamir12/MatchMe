import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_partner_provider.dart';

/// Small "🏠 Home base" chip shown when the match partner currently matches
/// from a pinned home-base location (i.e. they are physically elsewhere).
///
/// Realtime: watches the shared [pinnedPartnerProvider] (RPC) while keeping
/// [pinnedPartnerRealtimeProvider] alive so pin/unpin/extend/expire broadcasts
/// invalidate immediately in both the match row and the match profile.
/// Fail-closed to hidden on any error.
///
/// Lives in its own file (instead of inside match_box.dart) so both
/// MatchBox and MatchProfileScreen can reuse it without a circular import.
class PinnedPartnerChip extends ConsumerWidget {
  final String otherUserId;
  const PinnedPartnerChip({super.key, required this.otherUserId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    // Keep the broadcast/poll subscription alive while any chip is visible.
    ref.watch(pinnedPartnerRealtimeProvider);
    final async = ref.watch(pinnedPartnerProvider(otherUserId));
    return async.maybeWhen(
      data: (pinned) => pinned
          ? Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.push_pin_outlined,
                    size: 12,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      l10n.getString('pinnedPartnerBadge'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
      orElse: () => const SizedBox.shrink(),
    );
  }
}
