// lib/widgets/match_notification_overlay.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/web_imports.dart' as html;

/// The overlay carries two banner kinds — a new match, and "the other
/// participant extended this match" — so the in-app gate has to be satisfied
/// for whichever kind is actually showing.
bool _inAppEnabled(NotificationPreferencesState notifs) {
  return notifs.isMethodEnabled(
        NotificationType.newMatch,
        NotificationMethod.inApp,
      ) ||
      notifs.isMethodEnabled(
        NotificationType.matchExtended,
        NotificationMethod.inApp,
      );
}

class MatchNotificationOverlay extends ConsumerStatefulWidget {
  const MatchNotificationOverlay({super.key});

  @override
  ConsumerState<MatchNotificationOverlay> createState() =>
      _MatchNotificationOverlayState();
}

class _MatchNotificationOverlayState
    extends ConsumerState<MatchNotificationOverlay>
    with SingleTickerProviderStateMixin {
  MatchNotification? _currentNotification;
  AnimationController? _animationController;
  Animation<Offset>? _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _animationController!,
            curve: Curves.easeOutBack,
          ),
        );
  }

  @override
  void dispose() {
    _animationController?.dispose();
    super.dispose();
  }

  void _showNotification(MatchNotification notification) async {
    final notifs = ref.read(userPreferencesProvider).notifications;
    if (notifs.isPausedNow) return;
    if (!notifs.isMethodEnabled(
      NotificationType.newMatch,
      NotificationMethod.inApp,
    )) {
      return;
    }

    setState(() {
      _currentNotification = notification;
    });

    // Play haptic feedback
    final allowVibrate = notifs.isMethodEnabled(
      NotificationType.newMatch,
      NotificationMethod.vibrate,
    );
    if (allowVibrate) {
      if (kIsWeb) {
        html.safeVibrate(20);
      } else {
        HapticFeedback.mediumImpact();
      }
    }

    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _animationController?.value = 1;
    } else {
      _animationController?.forward();
    }

    // Auto-dismiss after configured duration
    final dismissDuration = await appConfigService.getDuration(
      'notification.match_auto_dismiss_seconds',
      defaultValue: const Duration(seconds: 5),
    );
    Future.delayed(dismissDuration, () {
      _dismissNotification();
    });
  }

  void _dismissNotification() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      if (mounted) {
        setState(() {
          _currentNotification = null;
        });
      }
      return;
    }
    _animationController?.reverse().then((_) {
      if (mounted) {
        setState(() {
          _currentNotification = null;
        });
      }
    });
  }

  void _viewMatch() {
    if (_currentNotification == null) return;

    final match = _currentNotification!.match;
    final l10n = ref.read(localizationProvider);
    final cachedProfile = ref
        .read(userProfileProvider(match.otherUserId))
        .asData
        ?.value;
    final otherName =
        cachedProfile?.name.formatAsFirstNameLastInitial() ??
        l10n.getString('newMatchPlaceholderName');

    // Mark as viewed
    ref.read(matchNotificationProvider.notifier).markAsViewed(match.id);

    // Dismiss notification
    _dismissNotification();

    // Navigate to match profile
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MatchProfileScreen(
          matchId: match.id,
          otherUserId: match.otherUserId,
          otherUserName: otherName,
          matchedIntent: match.matchedIntent,
          matchType: match.matchType,
          eventId: match.eventId,
          eventName: match.eventName,
          eventLink: match.eventLink,
          createdAt: match.createdAt,
          // Pass cached location/rematch fields so the profile (incl. the
          // minimap and name) renders offline without a fresh DB fetch.
          matchOccurrence: match.matchOccurrence,
          user1Latitude: match.user1Latitude,
          user1Longitude: match.user1Longitude,
          user2Latitude: match.user2Latitude,
          user2Longitude: match.user2Longitude,
          mapCenterLat: match.mapCenterLat,
          mapCenterLng: match.mapCenterLng,
          mapZoom: match.mapZoom,
          previousLocations: match.previousLocations,
          allMatchLocationsOverride: match.allMatchLocations,
          isRetroactive: match.isRetroactive,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notifs = ref.watch(userPreferencesProvider).notifications;

    // Listen for new notifications
    ref.listen<MatchNotificationState>(matchNotificationProvider, (
      previous,
      next,
    ) {
      final currentNotifs = ref.read(userPreferencesProvider).notifications;
      if (currentNotifs.isPausedNow) return;
      if (!_inAppEnabled(currentNotifs)) {
        return;
      }
      // Check if there's a new unviewed notification
      final newNotification = next.notifications.firstOrNull;
      if (newNotification != null &&
          !newNotification.viewed &&
          (previous?.notifications.firstOrNull?.match.id !=
              newNotification.match.id)) {
        _showNotification(newNotification);
      }
    });

    if (notifs.isPausedNow) {
      return const SizedBox.shrink();
    }
    if (!_inAppEnabled(notifs)) {
      return const SizedBox.shrink();
    }

    if (_currentNotification == null) {
      return const SizedBox.shrink();
    }

    final match = _currentNotification!.match;
    final l10n = ref.watch(localizationProvider);
    // Get other user's profile
    final profileAsync = ref.watch(userProfileProvider(match.otherUserId));
    // Use the new provider for intent display if needed
    final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];
    final matchedIntentObj = allIntents.firstWhere(
      (intent) => intent.key == match.matchedIntent,
      orElse: () => AppIntent(id: 0, key: '', translationKey: '', sortOrder: 0),
    );
    final matchedIntentDisplay =
        matchedIntentObj.translationKey.isNotEmpty &&
            l10n.containsKey(matchedIntentObj.translationKey)
        ? l10n.getString(matchedIntentObj.translationKey)
        : matchedIntentObj.translationKey
              .replaceAll('_', ' ')
              .split(' ')
              .map(
                (w) => w.isNotEmpty
                    ? '${w[0].toUpperCase()}${w.substring(1)}'
                    : '',
              )
              .join(' ');

    return Semantics(
      liveRegion: true,
      child: SlideTransition(
        position: _slideAnimation!,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.secondary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      // User photo
                      profileAsync.when(
                        data: (profile) {
                          final photoUrl = (profile?.photos.isNotEmpty == true)
                              ? profile!.photos[0]
                              : null;
                          return CircleAvatar(
                            radius: 30,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surface,
                            child: photoUrl != null
                                ? ClipOval(
                                    child: SignedImage(
                                      source: photoUrl,
                                      width: 60,
                                      height: 60,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : Icon(
                                    Icons.person,
                                    size: 30,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                          );
                        },
                        loading: () => CircleAvatar(
                          radius: 30,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surface,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        ),
                        error: (_, _) => CircleAvatar(
                          radius: 30,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surface,
                          child: Icon(
                            Icons.person,
                            size: 30,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Match info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Use gender-aware translation for the title if the other user's gender is known
                            Text(
                              () {
                                final profileSync = profileAsync.asData?.value;
                                final isExtension =
                                    _currentNotification?.isExtension ?? false;
                                final title = l10n.getString(
                                  isExtension
                                      ? 'matchExtendedBannerTitle'
                                      : 'newMatchTitle',
                                  gender: profileSync?.gender,
                                );
                                return '${isExtension ? '⏱️' : '🎉'} $title';
                              }(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            profileAsync.when(
                              data: (profile) {
                                final displayName =
                                    profile?.name.formatAsFirstNameLastInitial() ??
                                    l10n.getString('generalUnknown');
                                final layout = displayName.displayTextLayout(
                                  Directionality.of(context),
                                );
                                return Text(
                                  displayName,
                                  textAlign: layout.textAlign,
                                  textDirection: layout.textDirection,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                    fontSize: 14,
                                  ),
                                );
                              },
                              loading: () => Text(
                                l10n.getString('generalLoading'),
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  fontSize: 14,
                                ),
                              ),
                              error: (_, _) => Text(
                                l10n.getString('generalUnknown'),
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              match.matchType == 'event' &&
                                      match.eventName != null
                                  ? '${l10n.getString('matchedAt')} ${match.eventName}'
                                  : '${l10n.getString('matchedOn')} $matchedIntentDisplay',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimary.withValues(alpha: 0.9),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Actions
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.visibility,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                            onPressed: _viewMatch,
                            tooltip: l10n.getString('viewMatch'),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              color: Theme.of(context).colorScheme.onPrimary,
                              size: 20,
                            ),
                            onPressed: () {
                              ref
                                  .read(matchNotificationProvider.notifier)
                                  .markAsViewed(match.id);
                              _dismissNotification();
                            },
                            tooltip: l10n.getString('generalClose'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
