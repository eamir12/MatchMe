// lib/screens/main_navigation_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/providers/meetup_activity_provider.dart';
import 'package:matchme/providers/invisibility_rules_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/screens/home/home_screen.dart';
import 'package:matchme/screens/chats/chats_screen.dart';
import 'package:matchme/screens/matches/matches_screen.dart';
import 'package:matchme/screens/profile/profile_screen.dart';
import 'package:matchme/screens/events/events_screen.dart';
import 'package:matchme/widgets/match_notification_overlay.dart';
import 'package:matchme/widgets/custom_app_bar.dart';
import 'package:matchme/widgets/offline_indicator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/rating_prompt_watcher.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/mobile_local_notification_service.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/screens/settings/invisibility_rules_screen.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/providers/chat_key_provider.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/providers/connected_online_accounts_provider.dart';
import 'package:matchme/providers/calendar_sync_provider.dart';
import 'package:matchme/utils/meetup_alert_card.dart';
import 'package:matchme/utils/resume_route_restore.dart';
import 'package:matchme/screens/onboarding/onboarding_intro_screen.dart';
import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/services/onboarding_intro_service.dart';
import 'package:matchme/widgets/startup_loader.dart';
import 'package:matchme/screens/profile/verification_screen.dart';
import 'package:matchme/services/verification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final supabase = Supabase.instance.client;

/// Width of the desktop navigation rail, in logical pixels.
///
/// Must be wide enough for the widest destination label ("Matches") plus the
/// rail's own 8px horizontal padding on each side. Shared with
/// `buildCustomAppBar` so the app bar's centre strip lines up with the content
/// column rather than the whole window.
const double kMainNavRailWidth = 88;

/// Subscribes to cached location updates without forcing [MainNavigationScreen] to rebuild.
class _KeepCurrentLocationAlive extends ConsumerWidget {
  const _KeepCurrentLocationAlive();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentLocationProvider);
    return const SizedBox.shrink();
  }
}

/// Keeps all Realtime stream providers alive while the user is in the main
/// navigation flow, so that admin-side changes (verification, profile edits,
/// subscription tiers, intents/interests, translations) propagate instantly.
class _CurrentUserRealtimeWatcher extends ConsumerWidget {
  const _CurrentUserRealtimeWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentUserUsersTableProvider);
    return const SizedBox.shrink();
  }
}

/// Keeps subscription-related Realtime streams alive.
class _SubscriptionRealtimeWatcher extends ConsumerWidget {
  const _SubscriptionRealtimeWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(subscriptionTiersRealtimeProvider);
    ref.watch(subscriptionPlansRealtimeProvider);
    return const SizedBox.shrink();
  }
}

/// Keeps intents/interests Realtime streams alive.
class _IntentsInterestsRealtimeWatcher extends ConsumerWidget {
  const _IntentsInterestsRealtimeWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(intentsRealtimeProvider);
    ref.watch(interestsRealtimeProvider);
    return const SizedBox.shrink();
  }
}

/// Keeps translations Realtime stream alive.
class _TranslationsRealtimeWatcher extends ConsumerWidget {
  const _TranslationsRealtimeWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(translationsRealtimeProvider);
    return const SizedBox.shrink();
  }
}

/// App-bar center strip: connectivity, visibility, invisibility rules — isolated rebuild scope.
class _MainNavAppBarCenter extends ConsumerWidget {
  final bool isVerySmallScreen;
  final bool isSmallScreen;

  const _MainNavAppBarCenter({
    required this.isVerySmallScreen,
    required this.isSmallScreen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? false;
    final isVisible = ref.watch(isVisibleProvider);
    final rules = ref.watch(invisibilityRulesProvider);
    final isLoaded = rules.isLoaded;
    final currentInvisibilityReasons = ref.watch(
      currentInvisibilityReasonsProvider,
    );
    final currentInvisibilityReason = ref.watch(
      currentInvisibilityReasonProvider,
    );
    final hasActiveRules = currentInvisibilityReasons.isNotEmpty;

    if (!isLoaded && isOnline) {
      return _mainNavVisibilityDetailWidget(
        context,
        l10n,
        hasActiveRules,
        currentInvisibilityReason,
        isOnline,
        isVisible,
        isLoaded,
        null,
        null,
        isVerySmallScreen,
        isSmallScreen,
      );
    }

    if (hasActiveRules) {
      return _mainNavVisibilityDetailWidget(
        context,
        l10n,
        hasActiveRules,
        currentInvisibilityReason,
        isOnline,
        isVisible,
        isLoaded,
        () {
          final activeRuleIds = ref.read(activeRuleIdsProvider);
          final firstActiveRuleId = activeRuleIds.keys.isNotEmpty
              ? activeRuleIds.keys.first
              : null;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  InvisibilityRulesScreen(highlightRuleId: firstActiveRuleId),
            ),
          );
        },
        null,
        isVerySmallScreen,
        isSmallScreen,
      );
    }

    String text;
    Color color;
    Widget? switchWidget;

    if (!isOnline) {
      text = isVerySmallScreen
          ? l10n.getString('generalOffShort')
          : (isSmallScreen
                ? l10n.getString('generalOffline')
                : l10n.getString('youAreOffline'));
      color = Theme.of(context).colorScheme.error;
      switchWidget = null;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        decoration: BoxDecoration(
          color: color.withAlpha((0.1 * 255).round()),
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: color.withAlpha((0.2 * 255).round()),
            width: 1,
          ),
        ),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.visible,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    if (isVisible) {
      text = isVerySmallScreen
          ? l10n.getString('generalOnShort')
          : l10n.getString('youAreCurrentlyOnlineAndVisible');
      final semantic = Theme.of(context).extension<SemanticColors>();
      final Color c = semantic?.success ?? const Color(0xFF10B981);
      final Color bg = semantic?.successContainer ?? const Color(0xFFDCFCE7);
      switchWidget = Transform.scale(
        scale: isSmallScreen ? 0.8 : 0.88,
        child: Switch(
          value: isVisible,
          onChanged: (value) {
            ref.read(isVisibleProvider.notifier).setVisibility(value);
          },
          activeThumbColor: c,
          inactiveThumbColor: Theme.of(context).colorScheme.error,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(color: c.withAlpha((0.2 * 255).round()), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.visible,
                softWrap: true,
                style: TextStyle(
                  color: c,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 4),
            switchWidget,
          ],
        ),
      );
    }

    text = isVerySmallScreen
        ? l10n.getString('generalOnInvisibleShort')
        : '${l10n.getString('youAreCurrentlyOnline').trimRight()} ${l10n.getString('andInvisible').trimLeft()}';
    color = Theme.of(context).colorScheme.error;
    switchWidget = Transform.scale(
      scale: isSmallScreen ? 0.8 : 0.88,
      child: Switch(
        value: isVisible,
        onChanged: (value) {
          ref.read(isVisibleProvider.notifier).setVisibility(value);
        },
        activeThumbColor: Theme.of(context).colorScheme.secondary,
        inactiveThumbColor: Theme.of(context).colorScheme.error,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: color.withAlpha((0.1 * 255).round()),
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(
          color: color.withAlpha((0.2 * 255).round()),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.visible,
              softWrap: true,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 4),
          switchWidget,
        ],
      ),
    );
  }
}

Widget _mainNavVisibilityDetailWidget(
  BuildContext context,
  LocalizationState l10n,
  bool hasActiveRules,
  String? currentInvisibilityReason,
  bool isOnline,
  bool isVisible,
  bool isLoaded,
  VoidCallback? onTap,
  ValueChanged<bool>? onVisibilityChanged,
  bool isVerySmallScreen,
  bool isSmallScreen,
) {
  if (!isLoaded && isOnline) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(color: scheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.hardEdge,
      child: Text(
        l10n.getString('generalLoadingDots'),
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget child;
  if (!isOnline) {
    final color = Theme.of(context).colorScheme.error;
    child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: color.withAlpha((0.1 * 255).round()),
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(
          color: color.withAlpha((0.2 * 255).round()),
          width: 1,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Text(
        l10n.getString('youAreOffline'),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  } else if (hasActiveRules) {
    final color = Theme.of(context).colorScheme.tertiary;
    final reasonText = currentInvisibilityReason!.replaceFirst(
      l10n.getString('youAreInvisibleDueTo'),
      l10n.getString('invisibleDueTo'),
    );
    child = InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        decoration: BoxDecoration(
          color: color.withAlpha((0.1 * 255).round()),
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: color.withAlpha((0.2 * 255).round()),
            width: 1,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                l10n
                    .getString('youAreCurrentlyOnlineAnd')
                    .replaceAll('{reason}', reasonText),
                maxLines: 2,
                overflow: TextOverflow.visible,
                softWrap: true,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  } else {
    if (isVisible) {
      final semantic = Theme.of(context).extension<SemanticColors>();
      final Color color = semantic?.success ?? const Color(0xFF10B981);
      final Color bg = semantic?.successContainer ?? const Color(0xFFDCFCE7);
      child = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: color.withAlpha((0.2 * 255).round()),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                l10n.getString('youAreCurrentlyOnlineAndVisible'),
                maxLines: 2,
                overflow: TextOverflow.visible,
                softWrap: true,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Transform.scale(
              scale: isSmallScreen ? 0.8 : 0.88,
              child: Switch(
                value: isVisible,
                onChanged: onVisibilityChanged,
                activeThumbColor: color,
                // M3 dark semantics: an almost-white track glared on the dark
                // status chip; the container-highest role keeps it in tune.
                inactiveTrackColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                inactiveThumbColor: Theme.of(context).colorScheme.outline,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      );
    } else {
      final semantic = Theme.of(context).extension<SemanticColors>();
      final Color onlineColor =
          semantic?.success ?? Theme.of(context).colorScheme.secondary;
      final Color onlineBg =
          semantic?.successContainer ??
          onlineColor.withAlpha((0.1 * 255).round());
      child = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        decoration: BoxDecoration(
          color: onlineBg,
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: onlineColor.withAlpha((0.2 * 255).round()),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: l10n.getString('youAreCurrentlyOnline').trimRight(),
                      style: TextStyle(
                        color: onlineColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: l10n.getString('andInvisible').trimLeft(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Transform.scale(
              scale: isSmallScreen ? 0.8 : 0.88,
              child: Switch(
                value: isVisible,
                onChanged: onVisibilityChanged,
                activeThumbColor: onlineColor,
                inactiveTrackColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                inactiveThumbColor: Theme.of(context).colorScheme.outline,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      );
    }
  }

  return child;
}

class MainNavigationScreen extends ConsumerStatefulWidget {
  final int initialIndex;
  const MainNavigationScreen({super.key, this.initialIndex = 0});
  @override
  ConsumerState<MainNavigationScreen> createState() =>
      _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen>
    with WidgetsBindingObserver {
  Timer? _activityTimer;
  final GlobalKey<NavigatorState> _eventsNavigatorKey =
      GlobalKey<NavigatorState>();
  final List<ScrollController> _tabScrollControllers =
      List<ScrollController>.generate(
        5,
        (_) => ScrollController(),
        growable: false,
      );
  bool _didAttemptPendingRouteRestore = false;
  bool _isLoggingOut = false;
  bool _didLaunchOnboardingIntro = false;

  /// True while the one-time intro tour decision is still pending.
  ///
  /// The Home tab is held back until it resolves so the tour really comes
  /// before the member's first Home screen — a tour that pops up over a Home
  /// screen they already walked into is not "before" anything.
  bool _onboardingIntroPending = true;

  /// How long the Home tab waits for the intro-tour decision before it is
  /// released anyway. The tour has to come first, but a slow or unreachable
  /// server must never keep the member staring at a splash screen.
  static const Duration _onboardingIntroDecisionGrace = Duration(seconds: 3);

  /// Releases the Home tab if the intro-tour decision takes too long.
  Timer? _onboardingIntroGraceTimer;

  /// Process-wide record of accounts the intro tour has already auto-launched
  /// for. [MainNavigationScreen] states can be recreated (ProfileCheckScreen
  /// emits this screen from two tree positions), so an instance flag alone
  /// cannot stop two racing states from pushing duplicate tours.
  static final Set<String> _onboardingAutoLaunchedUserIds = <String>{};

  /// Process-wide record of accounts already prompted for photo verification
  /// during this app run. Requirement: prompt on every launch while the
  /// verification is not completed — but at most once per launch, never for
  /// approved accounts and never while a submission is already under review.
  static final Set<String> _verificationPromptShownUserIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The intro-tour decision starts right away: the Home tab is held back
    // until it resolves, so the tour comes before the first Home screen.
    unawaited(
      _maybeLaunchOnboardingIntro().then(
        (_) => _maybePromptPhotoVerification(),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateUserActivity();
        unawaited(_restoreNavigationContext());
        // Start background service for authenticated user
        final currentUserId = supabase.auth.currentUser?.id;
        if (currentUserId != null) {
          _saveLoginState(currentUserId);

          // Ensure location service is started for the authenticated user
          unawaited(
            ref.read(isVisibleProvider.notifier).ensureServiceStarted(),
          );
        }
      }
    });
  }

  /// Releases the Home tab. Idempotent — the decision and the grace timer can
  /// both call it.
  void _releaseHomeTab() {
    if (!_onboardingIntroPending) return;
    _onboardingIntroPending = false;
    if (mounted) setState(() {});
  }

  /// Runs the interactive introduction tour exactly once per ACCOUNT, right
  /// after their first profile completion: this State is created fresh on
  /// app startup AND right after the profile wizard flips
  /// [ProfileCheckScreen] over to main navigation, so both entry points are
  /// covered here.
  ///
  /// The tour is a one-time experience for the whole account, not for a
  /// device: the decision comes from the account record (and, where the
  /// database provides it, from an atomic server-side claim), so a member
  /// who already saw the tour on another device never sees it again. The
  /// launch is consumed the single time it fires (persisted immediately, not
  /// only when the tour is finished) so it can never auto-launch again — not
  /// on later cold starts, not after subsequent profile edits. It can always
  /// be replayed manually from Settings, which pushes
  /// [OnboardingIntroScreen] directly and bypasses this gate.
  Future<void> _maybeLaunchOnboardingIntro() async {
    // The Home tab must not stay hidden forever while the account is asked.
    _onboardingIntroGraceTimer?.cancel();
    _onboardingIntroGraceTimer = Timer(
      _onboardingIntroDecisionGrace,
      _releaseHomeTab,
    );
    try {
      final userId = supabase.auth.currentUser?.id;
      final launchKey = (userId == null || userId.isEmpty) ? 'anon' : userId;
      if (_onboardingAutoLaunchedUserIds.contains(launchKey)) {
        _releaseHomeTab();
        return;
      }
      // This device already consumed the tour: no account round-trip, no
      // delay, Home is released immediately.
      if (await OnboardingIntroService.instance.hasSeenCoreTourLocally(
        userId: userId,
      )) {
        _releaseHomeTab();
        return;
      }
      // Auto-launch only after first profile completion. Main navigation is
      // normally reached only via a complete profile, but offline fallbacks
      // can land here early — never consume the one auto-launch then.
      // A negative result claims nothing, so a later State (after the real
      // completion) can still fire the single launch.
      final isComplete = await _isProfileCompleteForOnboardingIntro(userId);
      if (!isComplete) {
        _releaseHomeTab();
        return;
      }
      // The ACCOUNT decides whether the tour was ever seen. Anything but an
      // explicit "launch" (already seen, or state unknown because the server
      // could not be reached) keeps the tour away: a one-time tour that shows
      // up twice is worse than one that never shows up.
      final decision = await OnboardingIntroService.instance
          .decideCoreTourLaunch(userId: userId);
      if (decision != CoreTourLaunchDecision.launch) {
        debugPrint(
          '[MainNavigation] Onboarding intro not launched ($decision)',
        );
        _releaseHomeTab();
        return;
      }
      if (!mounted) return;
      // Claim the single auto-launch synchronously: this section has no
      // awaits, so a racing State instance cannot slip past it.
      if (_didLaunchOnboardingIntro) {
        _releaseHomeTab();
        return;
      }
      if (_onboardingAutoLaunchedUserIds.contains(launchKey)) {
        _releaseHomeTab();
        return;
      }
      _didLaunchOnboardingIntro = true;
      _onboardingAutoLaunchedUserIds.add(launchKey);
      // Give the startup transition (please-wait dialog hide, pending route
      // restore) a moment to settle so the tour opens on a calm screen.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => OnboardingIntroScreen(tour: kOnboardingCoreTour),
        ),
      );
    } catch (e) {
      debugPrint('[MainNavigation] Onboarding intro launch failed: $e');
    } finally {
      // The tour is done (or was never coming): the member reaches Home.
      _releaseHomeTab();
    }
  }

  /// Best-effort profile-completion read for the launch gate: provider first,
  /// local cache fallback. Unknown (still loading, no cache) resolves to
  /// false so the one auto-launch is never spent blindly.
  Future<bool> _isProfileCompleteForOnboardingIntro(String? userId) async {
    if (userId == null || userId.isEmpty) return false;
    try {
      final cached = ref.read(userProfileProvider(userId)).asData?.value;
      if (cached != null) return cached.isProfileComplete;
    } catch (_) {}
    try {
      final raw = await ref.read(localDbProvider).getLocalProfile(userId);
      if (raw == null) return false;
      return UserProfile.fromMap(raw).isProfileComplete;
    } catch (_) {
      return false;
    }
  }

  /// Asks the user to complete photo verification on app launch when their
  /// verification is not completed yet (`unverified` or `rejected`).
  /// Approved accounts are done, and pending/analyzing submissions cannot be
  /// resubmitted — neither is prompted. Runs at most once per app launch per
  /// account (process-wide set, mirroring the intro-tour gate), and only
  /// after the intro tour has finished so dialogs never stack.
  Future<void> _maybePromptPhotoVerification() async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) return;
      if (_verificationPromptShownUserIds.contains(userId)) return;
      // Claim the once-per-launch slot synchronously: everything after this
      // point awaits, and a racing State instance must not double-prompt.
      _verificationPromptShownUserIds.add(userId);
      // Give the startup transition a moment to settle on a calm screen.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      // Offline: the prompt could only lead to a failed submission flow.
      if (OfflineCacheManager.instance.shouldUseCachedData()) return;

      // Server status first (the source of truth for admin decisions), with
      // the cached profile as fallback when the status read fails.
      String? status;
      try {
        final statusData = await VerificationService().getVerificationStatus(
          userId,
        );
        if (statusData != null) {
          status = statusData['is_verified'] == true
              ? 'approved'
              : statusData['verification_status']?.toString();
        }
      } catch (_) {}
      if (!mounted) return;
      final profile = ref.read(userProfileProvider(userId)).asData?.value;
      if (status == null || status.isEmpty) {
        if (profile == null) return;
        status = profile.isVerified ? 'approved' : profile.verificationStatus;
      }
      if (status != 'unverified' && status != 'rejected') return;

      // Only prompt when the user can actually submit: a complete profile
      // with at least one photo (the AI compares the verification selfie
      // against profile photo #1).
      if (profile == null || !profile.isProfileComplete) return;
      if (profile.photos.isEmpty) return;

      if (!mounted) return;
      final l10n = ref.read(localizationProvider);
      final startVerification = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(l10n.getString('verificationPromptTitle')),
            // The launch prompt is an invitation to verify in every case;
            // the details of a prior rejection belong to the verification
            // screen's status card.
            content: Text(l10n.getString('verificationPromptBodyUnverified')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.getString('verificationPromptLater')),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.getString('verifyNow')),
              ),
            ],
          );
        },
      );
      if (startVerification == true && mounted) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const VerificationScreen()));
      }
    } catch (e) {
      debugPrint('[MainNavigation] Verification prompt failed: $e');
    }
  }

  Future<void> _restoreNavigationContext() async {
    // Start at Home on a genuine cold start, or when the account changes - but
    // NOT every time this State is created. ProfileCheckScreen emits this screen
    // from two different tree positions, so its State is recreated whenever the
    // profile future re-resolves (e.g. during a calendar OAuth's session
    // churn). Resetting unconditionally threw the user back to Home mid-task.
    if (!mounted) return;

    final userId = supabase.auth.currentUser?.id;
    final init = ref.read(navigationContextInitProvider.notifier);
    if (!init.isInitialisedFor(userId)) {
      if (userId != null && userId.isNotEmpty) {
        init.markInitialisedFor(userId);
      }
      ref.read(navigationIndexProvider.notifier).setIndex(widget.initialIndex);
    }

    if (_didAttemptPendingRouteRestore) return;
    _didAttemptPendingRouteRestore = true;

    final initialRoute = await BackgroundService.getInitialRoute();
    final hasExternalLaunchIntent =
        initialRoute?['route'] != null ||
        initialRoute?['sharedText'] != null ||
        initialRoute?['sharedFilePath'] != null ||
        initialRoute?['tabIndex'] != null;

    if (hasExternalLaunchIntent) {
      await ResumeRouteRestore.clearPendingRoute();
      return;
    }

    final pendingRouteName = await ResumeRouteRestore.consumePendingRouteName();
    if (!mounted || pendingRouteName == null || pendingRouteName == '/') return;

    switch (pendingRouteName) {
      case ResumeRouteRestore.settingsRoute:
      case ResumeRouteRestore.notificationsSettingsRoute:
      case ResumeRouteRestore.securityCenterRoute:
        Navigator.of(context).pushNamed(pendingRouteName);
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activityTimer?.cancel();
    _onboardingIntroGraceTimer?.cancel();
    for (final controller in _tabScrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _updateUserActivity() async {
    final user = supabase.auth.currentUser;
    if (user != null) {
      await UserActivityService.instance.pingIfDue(
        user.id,
        source: 'main-navigation',
      );
    }
  }

  void _scrollTabToTop(int index) {
    if (index < 0 || index >= _tabScrollControllers.length) return;
    final controller = _tabScrollControllers[index];
    if (controller.hasClients) controller.jumpTo(0);
  }

  void _selectTab(int index) {
    if (index == ref.read(navigationIndexProvider)) {
      _scrollTabToTop(index);
    }
    ref.read(navigationIndexProvider.notifier).setIndex(index);
    unawaited(ResumeRouteRestore.saveLastMainTabIndex(index));
  }

  Future<void> _saveLoginState(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('was_logged_in', true);
      await prefs.setString('user_id', userId);
      // Store Supabase config for background service
      // These are set during app initialization in main.dart
      final supabaseUrl =
          prefs.getString('supabase_url') ?? 'https://your-project.supabase.co';
      final supabaseKey = prefs.getString('supabase_key') ?? 'your-anon-key';
      await prefs.setString('stored_supabase_url', supabaseUrl);
      await prefs.setString('stored_supabase_key', supabaseKey);
    } catch (e) {
      print('Error saving login state: $e');
    }
  }

  Future<void> _requestLogout() async {
    if (!mounted || _isLoggingOut) return;
    final l10n = ref.read(localizationProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.getString('authLogoutConfirmTitle')),
        content: Text(l10n.getString('authLogoutConfirmBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.getString('authLogout')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _handleLogout();
  }

  Future<void> _handleLogout() async {
    if (!mounted || _isLoggingOut) return;
    setState(() => _isLoggingOut = true);
    // A later sign-in - even as the same account - should start on Home.
    ref.read(navigationContextInitProvider.notifier).reset();
    Future<void> clearLoginState() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('was_logged_in');
        await prefs.remove('user_id');
        await prefs.remove('supabase_url');
        await prefs.remove('supabase_key');
        // Visibility is per-user and persists across sessions; the provider
        // clears only the shared native mirror on the sign-out event.
      } catch (_) {}
    }

    // Capture the outgoing identity BEFORE any teardown: the server-side
    // cleanup below and the auth listener both need it.
    final loggedOutUser = supabase.auth.currentUser;
    final outgoingUserId = loggedOutUser?.id;
    // Offline-aware gate. When Supabase is unreachable we must not await a
    // single network round trip — logout has to stay instant and local.
    final canReachServer = OfflineCacheManager.instance.isSupabaseAvailable;

    // Best-effort remote cleanup. Every action swallows its own errors so a
    // dead/slow backend can never abort the logout.
    Future<void> quiet(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {}
    }

    // These cleanups need the active JWT, so they run BEFORE sign-out and are
    // skipped entirely offline. In particular, never fire them without
    // awaiting: a late RPC would execute as `anon` after the local sign-out.
    if (canReachServer) {
      final locationShare = ref.read(locationShareProvider);
      final authBoundCleanup = <Future<void>>[
        // Stop any active live location sharing (best-effort; the peer sees
        // our share stop and our DB signal is cleaned up).
        if (locationShare != null)
          quiet(() => ref.read(locationShareProvider.notifier).stopSharing()),
        // End ONLY this device's session. A user may be signed in on several
        // devices at once: the server keeps them online (and visible/pinned as
        // configured) while another non-revoked session still exists. The RPC
        // also marks the account offline when this was the last active device.
        // Never call revoke_all_user_sessions here - that signs every other
        // device out too.
        if (outgoingUserId != null)
          quiet(
            () => SessionService.logoutCurrentDevice(
              userId: outgoingUserId,
              clearPinnedLocation: true,
              timeout: const Duration(seconds: 2),
            ),
          ),
      ];

      try {
        // The helper bounds itself below this outer budget, so it cannot keep
        // running after auth is torn down.
        await Future.wait(
          authBoundCleanup,
        ).timeout(const Duration(seconds: 3), onTimeout: () => const []);
      } catch (_) {}
    }

    // Clear this device's FCM token mapping so the next account that logs in
    // here doesn't inherit pushes meant for the signed-out user.
    // upsert_user_session also steals tokens server-side; this is the client
    // half: rotate the token + drop the cached copy. It does not need the
    // session and is pure best-effort, so it never blocks the critical path.
    unawaited(quiet(SessionService.deleteFcmToken));

    // LOCAL cleanup (offline-safe). Each step is isolated so a failure in one
    // never blocks the sign-out below.
    try {
      if (outgoingUserId != null && outgoingUserId.isNotEmpty) {
        await OfflineCacheManager.instance.clearAllOfflineCache(
          userId: outgoingUserId,
        );
      }
    } catch (e) {
      debugPrint('[AUTH] Offline cache wipe on logout failed: $e');
    }
    clearUserScopedHomeMemoryCaches();
    try {
      ref.read(globalSyncManagerProvider).dispose();
    } catch (_) {}
    await clearLoginState();
    try {
      await SessionService.clearLocalFcmToken();
    } catch (e) {
      print('clearLocalFcmToken on logout failed: $e');
    }
    // Windows: drop the cached WNS channel URI so the next account on this
    // machine re-registers its own (WNS has no client unregister; the server
    // prunes via session upsert steal / revoked rows).
    try {
      await SessionService.clearLocalWnsChannel();
    } catch (e) {
      print('clearLocalWnsChannel on logout failed: $e');
    }

    // Invalidate the outgoing user's home-screen providers (and the shared
    // dashboard/unread/tab state) BEFORE the session is torn down, while this
    // widget's ref is still usable. Otherwise the next account on this device
    // can briefly reuse the previous account's already-resolved providers and
    // skip the home-screen loading gate.
    SessionService.markExplicitUserSignOut();
    try {
      if (outgoingUserId != null && outgoingUserId.isNotEmpty && mounted) {
        ref.invalidate(recentMatchesProvider(outgoingUserId));
        ref.invalidate(recentChatsProvider(outgoingUserId));
        ref.invalidate(userChatIdsProvider(outgoingUserId));
        ref.invalidate(userProfileProvider(outgoingUserId));
        try {
          ref.read(profileSyncStateProvider(outgoingUserId).notifier).reset();
          ref.read(profileSyncProvider).invalidateUser(outgoingUserId);
        } catch (_) {}
        // Re-arm the initial-server-sync gate so the next login (even the same
        // account) waits for fresh server data instead of reusing a completed
        // gate with a now-wiped cache.
        ref.invalidate(initialHomeSyncProvider(outgoingUserId));
      }
      if (mounted) {
        ref.invalidate(dashboardStatsProvider);
        ref.invalidate(totalUnreadChatCountProvider);
        ref.invalidate(connectedOnlineAccountsProvider);
        // Drop the calendar service instance so its in-memory Google token /
        // account caches cannot be reused by the next user in this process.
        ref.invalidate(calendarSyncServiceProvider);
        try {
          ref.read(navigationIndexProvider.notifier).setIndex(0);
        } catch (_) {}
      }
    } catch (_) {}

    // SIGN OUT LOCALLY, IMMEDIATELY. `signOut` clears the in-memory session
    // synchronously and then fires the `signedOut` event (which routes the app
    // to the login screen) BEFORE it attempts the SDK's server-side revocation
    // round trip. We deliberately do NOT await that round trip: an unreachable
    // or slow Supabase must never keep the user on the logout spinner. The
    // bounded timeout drops a hung future after 3s.
    try {
      unawaited(
        supabase.auth
            .signOut(scope: SignOutScope.local)
            .timeout(const Duration(seconds: 3))
            .catchError((Object e) {
              debugPrint('[AUTH] signOut network revocation failed: $e');
            }),
      );
    } catch (e) {
      debugPrint('[AUTH] signOut call failed: $e');
    }

    // Safety net: the local session removal and the `signedOut` event are
    // synchronous-ish, but if a wedged platform channel ever prevented the
    // event from propagating, release the logout spinner instead of leaving
    // the user permanently stuck. A successful logout unmounts this widget, so
    // this is a no-op in the normal case.
    Future<void>.delayed(const Duration(seconds: 10), () {
      if (mounted && _isLoggingOut) {
        setState(() => _isLoggingOut = false);
      }
    });

    // Post-sign-out local resets. The auth listener also fires an unawaited
    // snapshot clear, but awaiting it here guarantees the credentials are gone
    // from disk even if the app is killed immediately after logout (otherwise
    // the next launch re-authenticates the signed-out user).
    try {
      await SessionService.clearPersistedSupabaseSessionSnapshot();
    } catch (_) {}
    // Reset the singleton heartbeat coalescer so the next user starts with a
    // clean ping window.
    UserActivityService.instance.reset();
    // Reset the chat key provider: it is a process-lifetime singleton, so
    // without this the next login (any user) would start from the previous
    // user's state. Also purge in-memory decryption/peer-key caches.
    try {
      if (mounted) {
        ref.invalidate(chatKeyProvider);
      }
      ChatKeyService.instance.clearMemoryCaches();
      debugPrint('[AUTH] Chat key provider invalidated on logout');
    } catch (e) {
      print('Chat key provider reset on logout failed: $e');
    }
    print(
      '[AUTH] User logged out: id=${loggedOutUser?.id}, email=${loggedOutUser?.email}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(navigationIndexProvider);
    ref.listen<int>(navigationIndexProvider, (previous, next) {
      if (previous != next) _scrollTabToTop(next);
    });
    final userId = supabase.auth.currentUser?.id;

    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;
    final isSmallScreen = screenWidth < 400;
    final isVerySmallScreen = screenWidth < 350;
    final isWideScreen = screenWidth >= 900;
    // Landscape phones/tablets have very little vertical space but plenty of
    // horizontal space. A bottom bar there steals ~80px of the already-short
    // height, while a side rail fits easily. Use the rail for any landscape
    // orientation so the main buttons are never squeezed by a bottom bar, and
    // make the rail itself scrollable (below) so its 5 destinations can never
    // be cut off by a short viewport.
    final isLandscape = screenWidth > screenHeight;
    final useRail = isWideScreen || isLandscape;

    final List<Widget> screens = [
      PrimaryScrollController(
        controller: _tabScrollControllers[0],
        // Held back while the one-time intro tour decision is pending, so
        // the tour comes before the member's first Home screen.
        child: _onboardingIntroPending
            ? const StartupLoaderScaffold()
            : const HomeScreen(),
      ),
      PrimaryScrollController(
        controller: _tabScrollControllers[1],
        child: const MatchesScreen(),
      ),
      PrimaryScrollController(
        controller: _tabScrollControllers[2],
        child: const ChatsScreen(),
      ),
      EventsTab(
        navigatorKey: _eventsNavigatorKey,
        scrollController: _tabScrollControllers[3],
      ),
      PrimaryScrollController(
        controller: _tabScrollControllers[4],
        child: const ProfileScreen(),
      ),
    ];

    final List<String> appBarTitleKeys = [
      'navHome',
      'navMatches',
      'navChats',
      'navEvents',
      'navProfile',
    ];
    final safeIndex = currentIndex < 0
        ? 0
        : (currentIndex >= appBarTitleKeys.length
              ? appBarTitleKeys.length - 1
              : currentIndex);
    final mainContent = IndexedStack(index: safeIndex, children: screens);

    // The rail spans the FULL window height beside the content Scaffold -
    // not inside its body below the app bar. A body-level rail can never rise
    // above the content's first row, which is exactly why Home sat level with
    // "Good evening" no matter how much padding changed. Full-height, the
    // group centers on the screen itself and Home sits up by the logo.
    // Fixed width, not Flexible: a loose flex child still hands
    // NavigationRail a huge maxWidth, and the rail's internal
    // Align then stretches the destinations' background to fill
    // it - which on a 1920px window pushed the icons to the
    // middle and left a ~450px dead zone on the left.
    Widget railPane() {
      return SizedBox(
        width: kMainNavRailWidth,
        // The rail is a sibling of the content Scaffold now (not its child),
        // so it needs its own Material ancestor for the InkWell ripples and
        // the surface background the Scaffold used to provide.
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            right: false,
            // Short windows (landscape) cannot fit the 5 full-size labeled
            // destinations (~500px). Below 520px of rail height switch to a
            // compact LABELED rail whose 5 buttons share the height exactly
            // (Expanded) - every icon and name stays visible with no sliding,
            // and the spare room spreads evenly instead of pooling above and
            // below. At/above 520px the full-size rail fits, centered. The
            // scroll view on the full rail is only an extreme-case safety net
            // (huge fonts); in normal use nothing scrolls.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final railHeight = constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : 520.0;
                if (railHeight < 520) {
                  return _CompactRail(
                    safeIndex: safeIndex,
                    onSelectTab: _selectTab,
                  );
                }
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: railHeight),
                    child: IntrinsicHeight(
                      child: _MainNavRail(
                        safeIndex: safeIndex,
                        onSelectTab: _selectTab,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    Widget contentScaffold() {
      return Scaffold(
        // The app bar only spans the content column now (the rail is its
        // sibling, not its child), so no leading inset is needed to-skew
        // the center strip.
        appBar: _MainNavAppBar(
          safeIndex: safeIndex,
          appBarTitleKeys: appBarTitleKeys,
          isSmallScreen: isSmallScreen,
          isVerySmallScreen: isVerySmallScreen,
          userId: userId,
          onLogout: () {
            unawaited(_requestLogout());
          },
          onSelectTab: _selectTab,
        ),
        // Offline banner across all tabs: shown whenever the device is
        // offline — including the cold-cache failure path where the app
        // entered with empty sections after the first sync could not land.
        body: Column(
          children: [
            const OfflineIndicator(),
            Expanded(child: mainContent),
          ],
        ),
        bottomNavigationBar: useRail
            ? null
            : SafeArea(
                child: _MainNavBottomBar(
                  safeIndex: safeIndex,
                  onSelectTab: _selectTab,
                ),
              ),
      );
    }

    return Stack(
      children: [
        Row(
          children: [
            if (useRail) railPane() else const SizedBox.shrink(),
            Expanded(child: contentScaffold()),
          ],
        ),
        const MatchNotificationOverlay(),
        const _NotificationInboxWatcher(),
        const _MeetupDesktopToastWatcher(),
        const RatingPromptWatcher(),
        const _KeepCurrentLocationAlive(),
        const _CurrentUserRealtimeWatcher(),
        const _SubscriptionRealtimeWatcher(),
        const _IntentsInterestsRealtimeWatcher(),
        const _TranslationsRealtimeWatcher(),
        if (_isLoggingOut)
          Positioned.fill(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

class _MainNavAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final int safeIndex;
  final List<String> appBarTitleKeys;
  final bool isSmallScreen;
  final bool isVerySmallScreen;
  final String? userId;
  final VoidCallback? onLogout;
  final ValueChanged<int> onSelectTab;

  const _MainNavAppBar({
    required this.safeIndex,
    required this.appBarTitleKeys,
    required this.isSmallScreen,
    required this.isVerySmallScreen,
    required this.userId,
    required this.onSelectTab,
    this.onLogout,
  });

  /// Must match [buildCustomAppBar] bottom [PreferredSize] height (56).
  static const double _centerStripHeight = 56;

  @override
  Size get preferredSize =>
      const Size.fromHeight(kToolbarHeight + _centerStripHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final screenName = l10n.getString(appBarTitleKeys[safeIndex]);
    final unreadInbox = ref.watch(unreadInboxCountProvider);
    final iconPadding = isSmallScreen ? 6.0 : 8.0;

    final List<Widget> actions = [
      // Notification inbox: persistent, re-readable record of every
      // notification the user has been sent (broadcasts, expirations, ...).
      IconButton(
        icon: Container(
          padding: EdgeInsets.all(iconPadding),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.notifications_outlined,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              if (unreadInbox > 0)
                PositionedDirectional(
                  top: -4,
                  end: -5,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    constraints: const BoxConstraints(minWidth: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      unreadInbox > 99 ? '99+' : '$unreadInbox',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onError,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        tooltip: l10n.getString('inboxTitle'),
        onPressed: () {
          if (userId == null) return;
          Navigator.of(
            context,
          ).pushNamed(ResumeRouteRestore.notificationInboxRoute);
        },
      ),
      IconButton(
        icon: Container(
          padding: EdgeInsets.all(iconPadding),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.settings_outlined,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        tooltip: l10n.getString('settingsTitle'),
        onPressed: () {
          if (userId == null) return;
          Navigator.of(context).pushNamed(ResumeRouteRestore.settingsRoute);
        },
      ),
      IconButton(
        icon: Container(
          padding: EdgeInsets.all(iconPadding),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
              l10n.textDirection == TextDirection.rtl ? -1.0 : 1.0,
              1.0,
              1.0,
            ),
            child: Icon(
              Icons.logout_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
        tooltip: l10n.getString('authLogout'),
        onPressed: onLogout,
      ),
    ];

    return buildCustomAppBar(
      context,
      l10n,
      screenName,
      actions,
      onHomePressed: () => onSelectTab(0),
      // The rail is a full-height sibling of this Scaffold, so the app bar
      // already spans only the content column: no leading inset needed.
      // (Kept as an explicit 0 while the parameter exists.)
      centerStripLeadingInset: 0,
      centerWidget: _MainNavAppBarCenter(
        isVerySmallScreen: isVerySmallScreen,
        isSmallScreen: isSmallScreen,
      ),
    );
  }
}

/// Keeps the notification inbox provider (realtime channel + unread count)
/// alive for the whole session so the app-bar bell badge stays current.
class _NotificationInboxWatcher extends ConsumerWidget {
  const _NotificationInboxWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(notificationInboxProvider);
    return const SizedBox.shrink();
  }
}

/// Windows has no FCM channel, so background pushes never arrive and the
/// inbox realtime row is the only cue. Mirror fresh meet-up tool rows into a
/// local toast so desktop gets the same alert mobile gets from push.
class _MeetupDesktopToastWatcher extends ConsumerStatefulWidget {
  const _MeetupDesktopToastWatcher();

  @override
  ConsumerState<_MeetupDesktopToastWatcher> createState() =>
      _MeetupDesktopToastWatcherState();
}

class _MeetupDesktopToastWatcherState
    extends ConsumerState<_MeetupDesktopToastWatcher> {
  late final DateTime _mountedAt = DateTime.now();

  @override
  Widget build(BuildContext context) {
    ref.listen<NotificationInboxState>(notificationInboxProvider, (
      previous,
      next,
    ) {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
      final previousIds =
          previous?.items.map((item) => item.id).toSet() ?? const <String>{};
      for (final item in next.items) {
        if (previousIds.contains(item.id)) continue;
        if (!item.createdAt.isAfter(_mountedAt)) continue;
        final kind = item.data['kind']?.toString() ?? item.type;
        if (!kMeetupAlertKinds.contains(kind)) continue;
        // The same key the alert sweep cancels by, so a tool that stops being
        // news also loses its desktop toast.
        final cardKey = meetupAlertCardKey(kind, item.data);
        if (cardKey.isEmpty) continue;
        unawaited(
          MobileLocalNotificationService.showMeetupNotification(
            notificationId: cardKey,
            title: item.title,
            body: item.body,
            matchId: item.data['matchId']?.toString() ?? '',
            kind: kind,
            expiresIn: kMeetupAlertDefaultTtl[kind],
          ),
        );
      }
    });
    return const SizedBox.shrink();
  }
}

class _MainNavBottomBar extends ConsumerWidget {
  final int safeIndex;
  final ValueChanged<int> onSelectTab;

  const _MainNavBottomBar({required this.safeIndex, required this.onSelectTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);

    return NavigationBar(
      selectedIndex: safeIndex,
      onDestinationSelected: onSelectTab,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l10n.getString('navHome'),
        ),
        NavigationDestination(
          icon: const _UnreadMatchesNavIcon(icon: Icons.people_outline),
          selectedIcon: const _UnreadMatchesNavIcon(icon: Icons.people),
          label: l10n.getString('navMatches'),
        ),
        NavigationDestination(
          icon: const _UnreadChatsNavIcon(icon: Icons.chat_bubble_outline),
          selectedIcon: const _UnreadChatsNavIcon(icon: Icons.chat_bubble),
          label: l10n.getString('navChats'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.calendar_today_outlined),
          selectedIcon: const Icon(Icons.calendar_today),
          label: l10n.getString('navEvents'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: l10n.getString('navProfile'),
        ),
      ],
    );
  }
}

/// Compact LABELED rail for short viewports (landscape): the 5 buttons share
/// the available body height exactly (Expanded), so every icon AND name is
/// visible at once with no sliding. Home starts right below the app-bar logo
/// and the spare room spreads evenly instead of pooling above/below.
class _CompactRail extends ConsumerWidget {
  final int safeIndex;
  final ValueChanged<int> onSelectTab;

  const _CompactRail({required this.safeIndex, required this.onSelectTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final colors = Theme.of(context).colorScheme;
    final labels = [
      l10n.getString('navHome'),
      l10n.getString('navMatches'),
      l10n.getString('navChats'),
      l10n.getString('navEvents'),
      l10n.getString('navProfile'),
    ];

    Widget iconFor(int index) {
      final bool selected = index == safeIndex;
      if (index == 1) {
        return _UnreadMatchesNavIcon(
          icon: selected ? Icons.people : Icons.people_outline,
        );
      }
      if (index == 2) {
        return _UnreadChatsNavIcon(
          icon: selected ? Icons.chat_bubble : Icons.chat_bubble_outline,
        );
      }
      final IconData icon;
      switch (index) {
        case 0:
          icon = selected ? Icons.home : Icons.home_outlined;
        case 3:
          icon = selected
              ? Icons.calendar_today
              : Icons.calendar_today_outlined;
        default:
          icon = selected ? Icons.person : Icons.person_outline;
      }
      return Icon(icon, size: 20);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: List.generate(5, (index) {
        final selected = index == safeIndex;
        final Color iconColor = selected
            ? colors.onPrimaryContainer
            : colors.onSurfaceVariant;
        return Expanded(
          child: Tooltip(
            message: labels[index],
            child: InkWell(
              onTap: () => onSelectTab(index),
              child: Semantics(
                button: true,
                selected: selected,
                label: labels[index],
                excludeSemantics: true,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? colors.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: IconTheme(
                          data: IconThemeData(size: 20, color: iconColor),
                          child: iconFor(index),
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        labels[index],
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.1,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _MainNavRail extends ConsumerWidget {
  final int safeIndex;
  final ValueChanged<int> onSelectTab;

  const _MainNavRail({required this.safeIndex, required this.onSelectTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);

    return NavigationRail(
      selectedIndex: safeIndex,
      onDestinationSelected: onSelectTab,
      labelType: NavigationRailLabelType.all,
      // Top-aligned so Home starts right below the app-bar logo instead of
      // leaving a block of white space above it.
      groupAlignment: -1.0,
      // Must equal the SizedBox that wraps this rail, otherwise the selection
      // indicator is laid out against a different width than the rail is given.
      minWidth: kMainNavRailWidth,
      minExtendedWidth: 120,
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: Text(l10n.getString('navHome')),
        ),
        NavigationRailDestination(
          icon: const _UnreadMatchesNavIcon(icon: Icons.people_outline),
          selectedIcon: const _UnreadMatchesNavIcon(icon: Icons.people),
          label: Text(l10n.getString('navMatches')),
        ),
        NavigationRailDestination(
          icon: const _UnreadChatsNavIcon(icon: Icons.chat_bubble_outline),
          selectedIcon: const _UnreadChatsNavIcon(icon: Icons.chat_bubble),
          label: Text(l10n.getString('navChats')),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.calendar_today_outlined),
          selectedIcon: const Icon(Icons.calendar_today),
          label: Text(l10n.getString('navEvents')),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: Text(l10n.getString('navProfile')),
        ),
      ],
    );
  }
}

class _UnreadMatchesNavIcon extends ConsumerWidget {
  final IconData icon;
  const _UnreadMatchesNavIcon({required this.icon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // New matches plus incoming live meet-up tools (the same activity the
    // match cards announce with a banner).
    final int newMatches = ref.watch(unreadMatchCountProvider);
    final int liveMeetups = ref.watch(incomingMeetupActivityCountProvider);
    return _NavBadgeIcon(icon: icon, count: newMatches + liveMeetups);
  }
}

class _UnreadChatsNavIcon extends ConsumerWidget {
  final IconData icon;
  const _UnreadChatsNavIcon({required this.icon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(totalUnreadChatCountProvider);
    return _NavBadgeIcon(icon: icon, count: count);
  }
}

class _NavBadgeIcon extends StatelessWidget {
  final IconData icon;
  final int count;
  const _NavBadgeIcon({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Icon(icon),
        if (count > 0)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                count > 99 ? '99+' : count.toString(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onError,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}
