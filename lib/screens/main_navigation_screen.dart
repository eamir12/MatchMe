// lib/screens/main_navigation_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
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
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/rating_prompt_watcher.dart';
import 'package:matchme/services/user_activity_service.dart';
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
import 'package:matchme/utils/resume_route_restore.dart';
import 'package:matchme/screens/onboarding/onboarding_intro_screen.dart';
import 'package:matchme/services/onboarding_intro_service.dart';
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
            fontSize: 11,
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
                  fontSize: 11,
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
                fontSize: 11,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: Colors.grey.withAlpha((0.1 * 255).round()),
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(
          color: Colors.grey.withAlpha((0.2 * 255).round()),
          width: 1,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Text(
        l10n.getString('generalLoadingDots'),
        style: TextStyle(
          color: Colors.grey,
          fontSize: 11,
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
          fontSize: 11,
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
                  fontSize: 11,
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
                  fontSize: 11,
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
                inactiveTrackColor: Colors.grey.shade300,
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
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: l10n.getString('andInvisible').trimLeft(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 11,
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
                inactiveTrackColor: Colors.grey.shade300,
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
  bool _didAttemptPendingRouteRestore = false;
  bool _isLoggingOut = false;
  bool _didLaunchOnboardingIntro = false;

  /// Process-wide record of accounts the intro tour has already auto-launched
  /// for. [MainNavigationScreen] states can be recreated (ProfileCheckScreen
  /// emits this screen from two tree positions), so an instance flag alone
  /// cannot stop two racing states from pushing duplicate tours.
  static final Set<String> _onboardingAutoLaunchedUserIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateUserActivity();
        unawaited(_restoreNavigationContext());
        unawaited(_maybeLaunchOnboardingIntro());

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

  /// Runs the interactive introduction tour exactly once per user, right
  /// after their first profile completion: this State is created fresh on
  /// app startup AND right after the profile wizard flips
  /// [ProfileCheckScreen] over to main navigation, so both entry points are
  /// covered here. The launch is consumed the single time it fires (persisted
  /// immediately, not only when the tour is finished) so it can never
  /// auto-launch again — not on later cold starts, not after subsequent
  /// profile edits. It can always be replayed manually from Settings, which
  /// pushes [OnboardingIntroScreen] directly and bypasses this gate.
  Future<void> _maybeLaunchOnboardingIntro() async {
    if (_didLaunchOnboardingIntro) return;
    try {
      final userId = supabase.auth.currentUser?.id;
      final launchKey = (userId == null || userId.isEmpty) ? 'anon' : userId;
      if (_onboardingAutoLaunchedUserIds.contains(launchKey)) return;
      final seen = await OnboardingIntroService.instance.hasSeenIntro(
        userId: userId,
      );
      if (seen) return;
      // Auto-launch only after first profile completion. Main navigation is
      // normally reached only via a complete profile, but offline fallbacks
      // can land here early — never consume the one auto-launch then.
      // A negative result claims nothing, so a later State (after the real
      // completion) can still fire the single launch.
      final isComplete = await _isProfileCompleteForOnboardingIntro(userId);
      if (!isComplete) return;
      if (!mounted) return;
      // Give the startup transition (please-wait dialog hide, pending route
      // restore) a moment to settle so the tour opens on a calm screen.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      // Claim the single auto-launch synchronously: this section has no
      // awaits, so a racing State instance cannot slip past it.
      if (_didLaunchOnboardingIntro) return;
      if (_onboardingAutoLaunchedUserIds.contains(launchKey)) return;
      _didLaunchOnboardingIntro = true;
      _onboardingAutoLaunchedUserIds.add(launchKey);
      // Persist the consumption now — this auto-launch IS the one time. Even
      // if the tour is dismissed by a system pop or the app is killed
      // mid-tour, it must not auto-launch again. Storage failure must not
      // block the launch itself.
      try {
        await OnboardingIntroService.instance.markIntroSeen(userId: userId);
      } catch (_) {}
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const OnboardingIntroScreen(),
        ),
      );
    } catch (e) {
      debugPrint('[MainNavigation] Onboarding intro launch failed: $e');
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

  void _selectTab(int index) {
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
        await prefs.remove('manual_visibility');
        await prefs.remove('effective_visibility');
        await prefs.remove('user_visibility');
        await prefs.setBool('manual_visibility', true);
        await prefs.setBool('effective_visibility', false);
      } catch (_) {}
    }

    try {
      // Stop any active live location sharing immediately before logout.
      // This ensures the peer sees our share stop and our DB signal is cleaned up,
      // even before the Supabase session is invalidated below.
      final locationShare = ref.read(locationShareProvider);
      if (locationShare != null) {
        print('LocationShare: Stopping active share on logout');
        await ref.read(locationShareProvider.notifier).stopSharing();
      }

      final userId = supabase.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) {
        throw StateError('Cannot log out without identifying the active user.');
      }
      // Keep the session active if a privacy wipe fails. The shared-device
      // cleanup must complete before sign-out, not continue as a success.
      await OfflineCacheManager.instance.clearAllOfflineCache(userId: userId);
      clearUserScopedHomeMemoryCaches();
      ref.read(globalSyncManagerProvider).dispose();
      await clearLoginState();
      // Immediately mark the user offline on the server BEFORE the session is
      // invalidated, so the online count drops right away. This is a direct,
      // trigger-independent backup to revoke_all_user_sessions below (the
      // session-change trigger normally flips is_online via that RPC, but the
      // heartbeat in update_user_activity must never resurrect a logged-out
      // user — see migration 20260814000000_only_mark_online_with_active_session).
      try {
        final user = supabase.auth.currentUser;
        if (user != null) {
          await supabase.rpc(
            'set_user_offline',
            params: {'p_user_id': user.id},
          );
        }
      } catch (e) {
        print('set_user_offline on logout failed: $e');
      }
      try {
        final user = supabase.auth.currentUser;
        if (user != null) {
          await supabase.rpc(
            'revoke_all_user_sessions',
            params: {'p_user_id': user.id},
          );
        }
      } catch (e) {
        print('revoke_all_user_sessions failed: $e');
      }
      // Clear this device's FCM token mapping so the next account that logs
      // in here doesn't inherit pushes meant for the signed-out user.
      // upsert_user_session also steals tokens server-side, this is the
      // client half: rotate the token + drop the cached copy.
      try {
        await SessionService.deleteFcmToken();
      } catch (e) {
        print('deleteFcmToken on logout failed: $e');
      }
      try {
        await SessionService.clearLocalFcmToken();
      } catch (e) {
        print('clearLocalFcmToken on logout failed: $e');
      }
      final loggedOutUser = supabase.auth.currentUser;
      SessionService.markExplicitUserSignOut();
      // Invalidate the outgoing user's home-screen providers (and the shared
      // dashboard/unread/tab state) BEFORE the session is torn down, while
      // this widget's ref is still usable. Otherwise the next account on this
      // device can briefly reuse the previous account's already-resolved
      // providers and skip the home-screen loading gate.
      try {
        final outgoingUserId = loggedOutUser?.id;
        if (outgoingUserId != null && outgoingUserId.isNotEmpty && mounted) {
          ref.invalidate(recentMatchesProvider(outgoingUserId));
          ref.invalidate(recentChatsProvider(outgoingUserId));
          ref.invalidate(userChatIdsProvider(outgoingUserId));
          ref.invalidate(userProfileProvider(outgoingUserId));
          try {
            ref.read(profileSyncStateProvider(outgoingUserId).notifier).reset();
            ref.read(profileSyncProvider).invalidateUser(outgoingUserId);
          } catch (_) {}
          // Re-arm the initial-server-sync gate so the next login (even the
          // same account) waits for fresh server data instead of reusing a
          // completed gate with a now-wiped cache.
          ref.invalidate(initialHomeSyncProvider(outgoingUserId));
        }
        if (mounted) {
          ref.invalidate(dashboardStatsProvider);
          ref.invalidate(totalUnreadChatCountProvider);
          try {
            ref.read(navigationIndexProvider.notifier).setIndex(0);
          } catch (_) {}
        }
      } catch (_) {}
      await supabase.auth.signOut();
      // Awaited (the auth listener also fires this, unawaited): if the app is
      // killed right after logout, an unfinished wipe leaves recoverable
      // credentials on disk and the next launch re-authenticates the
      // signed-out user instead of showing the login screen.
      await SessionService.clearPersistedSupabaseSessionSnapshot();
      // Clear the shared (non-user-scoped) dashboard stats cache so the next
      // account that logs in on this device never sees this user's stale
      // online/nearby counts. Also reset the singleton heartbeat coalescer so
      // the next user starts with a clean ping window.
      try {
        final outgoingUserId = loggedOutUser?.id;
        if (outgoingUserId != null && outgoingUserId.isNotEmpty) {
          await ref
              .read(localDbProvider)
              .clearDashboardStatsCache(outgoingUserId);
        }
      } catch (_) {}
      UserActivityService.instance.reset();
      // Reset the chat key provider: it is a process-lifetime singleton, so
      // without this the next login (any user) would start from the previous
      // user's state. Also purge in-memory decryption/peer-key caches.
      // Note: signOut() above triggers the auth state change which can unmount
      // this widget before we get here, so the widget's `ref` may no longer be
      // usable. The invalidation is also performed on the root container by
      // the auth listener in main.dart, so this widget-level call is just a
      // best-effort early reset.
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
    } catch (e) {
      debugPrint('[AUTH] Logout aborted: $e');
      if (mounted) {
        setState(() => _isLoggingOut = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref
                  .read(localizationProvider)
                  .getString('authLogoutCleanupFailed'),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(navigationIndexProvider);
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
      const HomeScreen(),
      const MatchesScreen(),
      const ChatsScreen(),
      EventsTab(navigatorKey: _eventsNavigatorKey),
      const ProfileScreen(),
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
        body: mainContent,
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
        if (useRail)
          Row(
            children: [railPane(), Expanded(child: contentScaffold())],
          )
        else
          contentScaffold(),
        const MatchNotificationOverlay(),
        const _NotificationInboxWatcher(),
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
                        fontSize: 8.5,
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
          Navigator.of(context).pushNamed(
            ResumeRouteRestore.notificationInboxRoute,
          );
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
          icon = selected ? Icons.calendar_today : Icons.calendar_today_outlined;
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
                          fontSize: 10,
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
    final count = ref.watch(unreadMatchCountProvider);
    return _NavBadgeIcon(icon: icon, count: count);
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
                  fontSize: 10,
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
