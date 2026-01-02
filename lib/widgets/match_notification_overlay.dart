// lib/widgets/match_notification_overlay.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/widgets/signed_image.dart';

class MatchNotificationOverlay extends ConsumerStatefulWidget {
  const MatchNotificationOverlay({super.key});

  @override
  ConsumerState<MatchNotificationOverlay> createState() => _MatchNotificationOverlayState();
}

class _MatchNotificationOverlayState extends ConsumerState<MatchNotificationOverlay> with SingleTickerProviderStateMixin {
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
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController!,
      curve: Curves.easeOutBack,
    ));
  }

  @override
  void dispose() {
    _animationController?.dispose();
    super.dispose();
  }

  void _showNotification(MatchNotification notification) {
    setState(() {
      _currentNotification = notification;
    });
    
    // Play haptic feedback
    HapticFeedback.mediumImpact();
    
    // Animate in
    _animationController?.forward();

    // Auto-dismiss after 5 seconds
    Future.delayed(const Duration(seconds: 5), () {
      _dismissNotification();
    });
  }

  void _dismissNotification() {
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
          otherUserName: l10n.getString('newMatchPlaceholderName'), // Will be loaded from profile
          matchedIntent: match.matchedIntent,
          eventId: match.eventId,
          eventName: match.eventName,
          eventLink: match.eventLink,
          createdAt: match.createdAt,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Listen for new notifications
    ref.listen<MatchNotificationState>(matchNotificationProvider, (previous, next) {
      // Check if there's a new unviewed notification
      final newNotification = next.notifications.firstOrNull;
      if (newNotification != null && 
          !newNotification.viewed && 
          (previous?.notifications.firstOrNull?.match.id != newNotification.match.id)) {
        _showNotification(newNotification);
      }
    });

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
    final matchedIntentDisplay = l10n.getString(matchedIntentObj.translationKey);

    return SlideTransition(
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
                  colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.secondary],
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
                        final photoUrl = (profile?.photos.isNotEmpty == true) ? profile!.photos[0] : null;
                        return CircleAvatar(
                          radius: 30,
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          child: photoUrl != null
                              ? ClipOval(
                                  child: SignedImage(
                                    source: photoUrl,
                                    width: 60,
                                    height: 60,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : Icon(Icons.person, size: 30, color: Theme.of(context).colorScheme.primary),
                        );
                      },
                      loading: () => CircleAvatar(
                        radius: 30,
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                      error: (_, _) => CircleAvatar(
                        radius: 30,
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        child: Icon(Icons.person, size: 30, color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Match info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '🎉 ${l10n.getString('newMatchTitle')}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          profileAsync.when(
                            data: (profile) => Text(
                              profile?.name ?? l10n.getString('generalUnknown'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontSize: 14,
                              ),
                            ),
                            loading: () => Text(
                              l10n.getString('generalLoading'),
                              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 14),
                            ),
                            error: (_, _) => Text(
                              l10n.getString('generalUnknown'),
                              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 14),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            match.matchType == 'event' && match.eventName != null
                                ? '${l10n.getString('matchedAt')} ${match.eventName}'
                                : '${l10n.getString('matchedOn')} $matchedIntentDisplay',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary.withValues(alpha:0.9),
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
                          icon: Icon(Icons.visibility, color: Theme.of(context).colorScheme.onPrimary),
                          onPressed: _viewMatch,
                          tooltip: l10n.getString('viewMatch'),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onPrimary, size: 20),
                          onPressed: () {
                            ref.read(matchNotificationProvider.notifier).markAsViewed(match.id);
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
    );
  }
}
