// Heads-up banner for live meet-up tool alerts, mounted above the Navigator
// so a wave, beacon, Spot card, proposal or place-change request reaches the
// receiver on every screen — not only inside the match chat.
//
// The bar shows the alert at full detail — what to look for. Swiping it
// sideways or up (or tapping the X) clears that match's alerts; it also
// slides away by itself once the tool's timer runs out. It hides itself while
// one of the alert's own surfaces (the match chat or profile, the meet-up hub,
// or the Meet-up screen) is open, because those already show the same live state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/main.dart' show navigatorKey;
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/screens/meetup/beacon_screen.dart';
import 'package:matchme/screens/meetup/meetup_coordination_widgets.dart';
import 'package:matchme/screens/meetup/meetup_hub_screen.dart';
import 'package:matchme/screens/meetup/meetup_screen.dart';
import 'package:matchme/utils/meetup_display.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:matchme/widgets/swipe_to_dismiss.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MeetupAlertOverlay extends ConsumerWidget {
  const MeetupAlertOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(meetupAlertsProvider);
    final alert = state.latest;
    final surfaces = ref.watch(meetupSurfacesProvider);

    // A tool that arrives while its own surface is already open is on screen
    // there, so it is seen the moment it lands: clear it like entering the
    // surface does, instead of leaving its badges set until it expires.
    ref.listen<MeetupAlertsState>(meetupAlertsProvider, (previous, next) {
      final latest = next.latest;
      if (latest == null) return;
      if ((ref.read(meetupSurfacesProvider)[latest.matchId] ?? 0) == 0) return;
      unawaited(
        ref.read(meetupAlertsProvider.notifier).clearMatch(latest.matchId),
      );
    });

    // The chat shows MeetupBanner and the coordination screens show the same
    // tools and feed, so there the global bar would only repeat the screen.
    final onOwnSurface = alert != null && (surfaces[alert.matchId] ?? 0) > 0;

    final Widget child;
    if (alert == null || onOwnSurface) {
      child = const SizedBox.shrink(key: ValueKey('meetupAlertHidden'));
    } else {
      child = _buildBar(context, ref, alert);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -1),
          end: Offset.zero,
        ).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: child,
    );
  }

  Widget _buildBar(BuildContext context, WidgetRef ref, MeetupAlert alert) {
    final l10n = ref.watch(localizationProvider);
    final scheme = Theme.of(context).colorScheme;
    final (icon, iconColor) = _icon(alert);
    final leading = alert.kind == kMeetupAlertBeacon
        ? MeetupBeaconShape(
            sessionId:
                ref.watch(meetupProvider(alert.matchId)).session?.id ??
                alert.matchId,
            size: 28,
            animate: false,
          )
        : Icon(icon, color: iconColor ?? scheme.primary, size: 24);
    final title = _title(ref, alert, l10n);
    final subtitle = _subtitle(alert, l10n);

    return SwipeToDismiss(
      key: ValueKey(alert.id),
      onDismissed: () =>
          ref.read(meetupAlertsProvider.notifier).clearMatch(alert.matchId),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(14),
        color: scheme.surfaceContainerHighest,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(ref, alert),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.45)),
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SafeText(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        SafeText(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ShrinkText(
                  l10n.getString('meetupOpen'),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                InkResponse(
                  onTap: () => ref
                      .read(meetupAlertsProvider.notifier)
                      .clearMatch(alert.matchId),
                  radius: 20,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                      // This overlay mounts above the Navigator, where no
                      // Overlay exists, so a Tooltip would throw. Keep the
                      // label on the icon's semantics instead.
                      semanticLabel: l10n.getString(
                        'systemNotificationDismiss',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (IconData, Color?) _icon(MeetupAlert alert) {
    switch (alert.kind) {
      case kMeetupAlertSignal:
        return (meetupGestureIcon(alert.gesture), Colors.amber.shade800);
      case kMeetupAlertBeacon:
        return (Icons.sensors, null);
      case kMeetupAlertSpot:
        return (Icons.photo_camera_front_outlined, Colors.pink.shade400);
      case kMeetupAlertPlaceChange:
        return (Icons.swap_horiz, null);
      case kMeetupAlertProposal:
      default:
        return (Icons.handshake_outlined, null);
    }
  }

  /// Resolves the match display name so the bar matches the naming used
  /// everywhere else ("First L. is signaling: …") instead of the server-baked
  /// push title. Returns null while the chats are not loaded yet.
  String? _otherUserName(WidgetRef ref, MeetupAlert alert) {
    if (alert.matchId.isEmpty) return null;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return null;
    final chats = ref.watch(recentChatsProvider(userId)).value;
    if (chats == null) return null;
    for (final ChatModel chat in chats) {
      if (chat.matchId == alert.matchId) return chat.otherUserName;
    }
    return null;
  }

  String _title(WidgetRef ref, MeetupAlert alert, LocalizationState l10n) {
    final name = _otherUserName(ref, alert);
    // Falls back to the server-baked inbox title until the chats resolve.
    if (name == null) return alert.title;
    switch (alert.kind) {
      case kMeetupAlertSignal:
        return l10n.getString(
          'meetupBannerGesture',
          params: {
            'name': name,
            'gesture': meetupGestureDisplay(alert.gesture, l10n),
          },
        );
      case kMeetupAlertBeacon:
        return l10n.getString('meetupBannerBeacon', params: {'name': name});
      case kMeetupAlertSpot:
        return l10n.getString(
          'meetupSpotMeIncomingTitle',
          params: {'name': name},
        );
      case kMeetupAlertProposal:
        return l10n.getString(
          'meetupBannerProposedByOther',
          params: {'name': name},
        );
      case kMeetupAlertPlaceChange:
        return l10n.getString(
          'meetupChangePlaceIncomingTitle',
          params: {'name': name},
        );
      default:
        return alert.title;
    }
  }

  String _subtitle(MeetupAlert alert, LocalizationState l10n) {
    switch (alert.kind) {
      case kMeetupAlertSignal:
        return l10n.getString('meetupGestureIncomingBody');
      case kMeetupAlertBeacon:
        return l10n.getString('meetupBeaconIncomingBody');
      default:
        return alert.body;
    }
  }

  Future<void> _open(WidgetRef ref, MeetupAlert alert) async {
    await ref.read(meetupAlertsProvider.notifier).clearMatch(alert.matchId);
    final l10n = ref.read(localizationProvider);
    var otherUserName = l10n.getString('generalUnknown');
    var matchType = 'proximity';
    String? eventName;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      final chats = ref.read(recentChatsProvider(userId)).value;
      if (chats != null) {
        for (final ChatModel chat in chats) {
          if (chat.matchId == alert.matchId) {
            otherUserName = chat.otherUserName;
            matchType = chat.matchType;
            eventName = chat.eventName;
            break;
          }
        }
      }
    }
    // Proposal and place-change alerts open the planning screen, where the
    // accept/counter decision lives; every other kind opens the hub, and
    // proposals/place changes continue from its plan card.
    final openPlan =
        alert.kind == kMeetupAlertProposal ||
        alert.kind == kMeetupAlertPlaceChange;
    await navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => openPlan
            ? MeetupScreen(
                matchId: alert.matchId,
                otherUserId: alert.senderId,
                otherUserName: otherUserName,
                matchType: matchType,
                eventName: eventName,
              )
            : MeetupHubScreen(
                matchId: alert.matchId,
                otherUserId: alert.senderId,
                otherUserName: otherUserName,
                matchType: matchType,
                eventName: eventName,
              ),
      ),
    );
  }
}
