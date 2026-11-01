import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/screens/meetup/meetup_hub_screen.dart';
import 'package:matchme/screens/meetup/meetup_screen.dart';
import 'package:matchme/utils/meetup_display.dart';
import 'package:matchme/widgets/safe_text.dart';

/// In-chat entry point for the meet-up flow.
///
/// Watches the shared meet-up state for this match, so a proposal, a wave or
/// a beacon reaches the other user even while they are typing in the chat.
class MeetupBanner extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final String matchType;
  final String? eventName;

  const MeetupBanner({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    this.matchType = 'proximity',
    this.eventName,
  });

  @override
  ConsumerState<MeetupBanner> createState() => _MeetupBannerState();
}

class _MeetupBannerState extends ConsumerState<MeetupBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Waves, beacons and the session itself all expire on a clock, and the
    // provider only changes on a database event. Rebuild every second so the
    // banner stops showing a signal the moment it expires.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = meetupProvider(widget.matchId);
    final state = ref.watch(provider);
    final l10n = ref.watch(localizationProvider);

    final wave = state.incomingWave;
    if (state.loading) return const SizedBox.shrink();

    // Tool alerts are match-scoped: they must show even when no location
    // invite exists (or the last one ended or expired).
    if (wave != null) return _signalBanner(wave, l10n);
    final beacon = state.incomingBeacon;
    if (beacon != null) return _beaconBanner(l10n);
    final cards = state.incomingSpotCards;
    if (cards.isNotEmpty) return _spotBanner(cards.last, l10n);

    final session = state.session;
    if (session == null || session.isExpired) {
      return const SizedBox.shrink();
    }

    if (state.isActive) {
      return _buildActive(session, state, l10n);
    }
    if (state.isProposed) {
      return _buildProposed(session, state, l10n);
    }
    return const SizedBox.shrink();
  }

  Widget _buildProposed(
    MeetupSession session,
    MeetupState state,
    LocalizationState l10n,
  ) {
    final mine = state.isMyProposal;
    final labels = state.roundLandmarks
        .map((item) => item.label)
        .take(2)
        .join(' · ');
    final zone = session.venueZone?.trim();
    final detail = session.isEvent && zone != null && zone.isNotEmpty
        ? meetupZoneDisplay(zone, l10n)
        : labels;

    return _BannerShell(
      icon: mine ? Icons.hourglass_top : Icons.handshake_outlined,
      title: l10n.getString(
        mine ? 'meetupBannerProposedByYou' : 'meetupBannerProposedByOther',
        params: {'name': widget.otherUserName},
      ),
      subtitle: mine || detail.isEmpty ? null : detail,
      actionLabel: l10n.getString('meetupOpen'),
      onTap: () => _openMeetup(true),
    );
  }

  Widget _buildActive(
    MeetupSession session,
    MeetupState state,
    LocalizationState l10n,
  ) {
    if (state.hasPendingPlaceChange && !state.isMyPlaceChange) {
      return _BannerShell(
        icon: Icons.swap_horiz,
        title: l10n.getString(
          'meetupChangePlaceIncomingTitle',
          params: {'name': widget.otherUserName},
        ),
        subtitle: state.pendingLandmark?.label,
        actionLabel: l10n.getString('meetupOpen'),
        onTap: () => _openMeetup(true),
      );
    }

    final zone = session.venueZone?.trim();
    final place = session.isEvent && zone != null && zone.isNotEmpty
        ? meetupZoneDisplay(zone, l10n)
        : (state.chosenLandmark?.label ?? l10n.getString('meetupPlace'));
    final title = l10n.getString(
      session.isEvent ? 'meetupBannerActiveEvent' : 'meetupBannerActive',
      params: {'place': place, 'zone': place},
    );

    return _BannerShell(
      icon: Icons.location_on_outlined,
      title: title,
      actionLabel: l10n.getString('meetupOpen'),
      onTap: () => _openMeetup(false),
    );
  }

  Widget _signalBanner(MeetupSignal signal, LocalizationState l10n) {
    final gesture = meetupSignalGesture(signal);
    return _BannerShell(
      icon: Icons.waving_hand,
      iconColor: Colors.amber.shade800,
      title: l10n.getString(
        'meetupBannerGesture',
        params: {
          'name': widget.otherUserName,
          'gesture': meetupGestureDisplay(gesture, l10n),
        },
      ),
      subtitle: l10n.getString('meetupGestureIncomingBody'),
      actionLabel: l10n.getString('meetupOpen'),
      onTap: () => _openMeetup(false),
    );
  }

  Widget _beaconBanner(LocalizationState l10n) {
    return _BannerShell(
      icon: Icons.sensors,
      title: l10n.getString(
        'meetupBannerBeacon',
        params: {'name': widget.otherUserName},
      ),
      subtitle: l10n.getString('meetupBeaconIncomingBody'),
      actionLabel: l10n.getString('meetupOpen'),
      onTap: () => _openMeetup(false),
    );
  }

  Widget _spotBanner(MeetupSpotCard card, LocalizationState l10n) {
    return _BannerShell(
      icon: Icons.photo_camera_front_outlined,
      iconColor: Colors.pink.shade400,
      title: l10n.getString(
        'meetupSpotMeIncomingTitle',
        params: {'name': widget.otherUserName},
      ),
      subtitle: l10n.getString('meetupSpotMeIncomingBody'),
      actionLabel: l10n.getString('meetupOpen'),
      onTap: () => _openMeetup(false),
    );
  }

  void _openMeetup(bool openPlan) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => openPlan
            ? MeetupScreen(
                matchId: widget.matchId,
                otherUserId: widget.otherUserId,
                otherUserName: widget.otherUserName,
                matchType: widget.matchType,
                eventName: widget.eventName,
              )
            : MeetupHubScreen(
                matchId: widget.matchId,
                otherUserId: widget.otherUserId,
                otherUserName: widget.otherUserName,
                matchType: widget.matchType,
                eventName: widget.eventName,
              ),
      ),
    );
  }
}

class _BannerShell extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final String actionLabel;
  final VoidCallback onTap;

  const _BannerShell({
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onTap,
    this.iconColor,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(icon, color: iconColor ?? scheme.primary, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SafeText(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        SafeText(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  actionLabel,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
