// lib/screens/auth/profile_check_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/screens/main_navigation_screen.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/services/background_service.dart';
import 'package:matchme/utils/permission_coordinator.dart';
import 'package:matchme/utils/app_shortcuts.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart'
    show ProfileWizardSection, profileCriticalGapSection;
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/utils/profile_sync_result.dart';
import 'package:matchme/widgets/startup_loader.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';

class ProfileCheckScreen extends ConsumerStatefulWidget {
  final User user;
  const ProfileCheckScreen({super.key, required this.user});

  @override
  ConsumerState<ProfileCheckScreen> createState() => _ProfileCheckScreenState();
}

enum _PcsScreen { loading, mainNavigation, wizard }

class _ProfileCheckScreenState extends ConsumerState<ProfileCheckScreen> {
  bool _notificationChecked = false;
  bool _didRunPermissionGate = false;
  Future<UserProfile?>? _cachedProfileFuture;
  bool _userDeletedCheckPerformed = false;
  bool _startupSyncScheduled = false;
  Widget? _mainScreen;
  _PcsScreen _screen = _PcsScreen.loading;

  /// True when the app was entered via the no-cached-profile escape hatch
  /// (offline / sync failed / 8s watchdog). The cold-cache home-sync hold
  /// below must not re-trap a user who was deliberately let through.
  bool _enteredViaNoProfileEscape = false;

  /// True once the app shell has been shown.
  ///
  /// The cold-cache hold below (the pulsing startup logo) is an *entry* gate:
  /// it may only run while the member is being let into the app for the
  /// first time. Once the shell is on screen the member is inside the app,
  /// and returning from a screen that was pushed on top of it - a chat
  /// opened from a notification, for example - must never drop them back
  /// onto the splash. The hold is also driven by an `autoDispose` provider
  /// that is watched only while the hold applies, so it can re-arm itself
  /// (and restart the whole home sync) the moment the provider is disposed
  /// and recreated.
  bool _hasEnteredAppShell = false;

  /// Set when the wizard is opened because a *completed* profile has a
  /// critical gap (missing field/photo) so the wizard jumps straight to
  /// the gap's page. Null when the wizard is opened the ordinary way
  /// (profile not yet complete — the draft restore picks the page).
  ProfileWizardSection? _gapSection;
  bool _pendingMainNavigation = false;
  DateTime? _loadingGateStartedAt;
  Timer? _loadingGateWatchdog;

  static const Duration _loadingGateTimeout = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _loadingGateStartedAt = DateTime.now();
    _armLoadingGateWatchdog();
    _cachedProfileFuture = _loadCachedProfile();
    _checkPendingNotification();
    Future.delayed(Duration.zero, () {
      if (!mounted) return;
      _scheduleDeferredStartupSync(widget.user.id);
      PermissionCoordinator.syncNativePermissionStrings(ref);
      PermissionCoordinator.handleOnResume(context, ref);
    });
  }

  @override
  void didUpdateWidget(covariant ProfileCheckScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id == widget.user.id) return;
    // A different account signed in on the same device while this State was
    // alive (account switch without a full sign-out interlude). Reset the
    // gate so the new account waits for its own profile/data exactly like a
    // cold start, instead of instantly reusing the previous user's home.
    // NOTE: the launch-intent check (_checkPendingNotification) is
    // deliberately NOT re-run here — it belongs to the cold-start launch.
    _screen = _PcsScreen.loading;
    _pendingMainNavigation = false;
    _mainScreen = null;
    _gapSection = null;
    _enteredViaNoProfileEscape = false;
    // A different account gets the same entry sequence, including the
    // cold-cache hold.
    _hasEnteredAppShell = false;
    _loadingGateStartedAt = DateTime.now();
    _armLoadingGateWatchdog();
    _cachedProfileFuture = _loadCachedProfile();
    _userDeletedCheckPerformed = false;
    _startupSyncScheduled = false;
    _didRunPermissionGate = false;
    Future.delayed(Duration.zero, () {
      if (!mounted) return;
      _scheduleDeferredStartupSync(widget.user.id);
    });
  }

  @override
  void dispose() {
    _loadingGateWatchdog?.cancel();
    _loadingGateWatchdog = null;
    super.dispose();
  }

  void _armLoadingGateWatchdog() {
    _loadingGateWatchdog?.cancel();
    _loadingGateWatchdog = Timer(_loadingGateTimeout, () {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    // Project the AsyncValue to the small slice this screen actually
    // depends on so background re-emits from userProfileProvider (e.g. tier
    // updates from a background sync) do not rebuild this widget. The
    // ref.listen below is what reacts to *real* profile data changes.
    final profileSlice = ref.watch(
      userProfileProvider(widget.user.id).select(
        (async) => (
          async.asData?.value?.isProfileComplete,
          async.asData?.value != null,
        ),
      ),
    );
    final isComplete = profileSlice.$1;
    final hasData = profileSlice.$2;
    final lastSyncResult = ref.watch(
      profileSyncStateProvider(widget.user.id).select((state) => state.result),
    );
    if (kDebugMode) {
      debugPrint(
        '👤👤👤 ProfileCheckScreen build for user: ${widget.user.id} (isComplete=$isComplete, hasData=$hasData)',
      );
    }

    ref.listen<AsyncValue<UserProfile?>>(
      userProfileProvider(widget.user.id),
      (prev, next) => _onProfileChanged(next),
    );

    if (_screen == _PcsScreen.loading) {
      final current = ref.read(userProfileProvider(widget.user.id));
      current.whenData((profile) {
        if (profile != null) {
          _gapSection = null;
          if (!profile.isProfileComplete) {
            _screen = _PcsScreen.wizard;
          } else {
            final gap = profileCriticalGapSection(profile);
            if (gap != null) {
              _screen = _PcsScreen.wizard;
              _gapSection = gap;
            } else {
              _screen = _PcsScreen.mainNavigation;
            }
          }
        }
      });
    }

    switch (_screen) {
      case _PcsScreen.mainNavigation:
        if (_pendingMainNavigation) {
          return const StartupLoaderScaffold();
        }
        // Cold cache (first login or cache wiped): hold the pulsing startup
        // logo until the first full home sync (profile + matches + chats)
        // has landed in the local DB, so Home is never shown partially
        // populated. `initialHomeSyncProvider` always settles — its cold
        // path has a 30s timeout and resolves immediately when offline —
        // so this can never trap the user on the logo; on failure/timeout
        // the app enters with whatever exists (empty sections + offline
        // banner) and the background sync keeps retrying. A warm relaunch
        // (complete local snapshot) passes within a frame or two.
        // The no-cached-profile escape hatch bypasses this hold.
        if (!_enteredViaNoProfileEscape && !_hasEnteredAppShell) {
          final hasCompleteCache = ref
              .watch(homeHasCompleteCacheProvider(widget.user.id))
              .asData
              ?.value ??
              false;
          if (!hasCompleteCache &&
              ref.watch(initialHomeSyncProvider(widget.user.id)).isLoading) {
            return const StartupLoaderScaffold();
          }
        }
        // The member is inside the app: the entry hold must never run again.
        _hasEnteredAppShell = true;
        if (!_didRunPermissionGate) {
          _didRunPermissionGate = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            PermissionCoordinator.handleOnResume(context, ref);
          });
        }
        // Key the navigation shell per user so a reused ProfileCheckScreen
        // state can never resurface the previous account's HomeScreen state.
        _mainScreen ??= MainNavigationScreen(
          key: ValueKey('main-nav-${widget.user.id}'),
        );
        return _mainScreen!;
      case _PcsScreen.wizard:
        return ProfileWizardScreen(
          user: widget.user,
          isEditing: false,
          initialSection: _gapSection,
        );
      case _PcsScreen.loading:
        return _buildCachedProfileFallback(lastSyncResult);
    }
  }

  _PcsScreen? _resolveNoCachedProfileTarget(ProfileSyncResult? result) {
    final startedAt = _loadingGateStartedAt;
    final decision = resolveNoProfileStartupDecision(
      isSupabaseAvailable: offlineCacheManager.isSupabaseAvailable,
      lastResult: result,
      elapsed: startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt),
      timeout: _loadingGateTimeout,
    );
    switch (decision) {
      case NoProfileStartupDecision.enterApp:
        return _PcsScreen.mainNavigation;
      case NoProfileStartupDecision.keepLoading:
        return null;
    }
  }

  _PcsScreen _evaluateScreen(UserProfile? profile) {
    if (profile == null) return _PcsScreen.loading;
    if (!profile.isProfileComplete) return _PcsScreen.wizard;
    // Completeness is more than the flag: a completed profile that lost a
    // critical field or its photos (server-side change, admin action, sync
    // anomaly) must go back to the wizard too.
    return profileCriticalGapSection(profile) == null
        ? _PcsScreen.mainNavigation
        : _PcsScreen.wizard;
  }

  // Hysteresis for the mainNavigation → wizard flip. userProfileProvider can
  // emit a transient isProfileComplete=false (e.g. a syncProfile fetch that
  // raced a wizard save and read pre-commit server state). Flipping on the
  // first such emit remounts the wizard on the review step with an empty
  // diff ("Not set"). Require a second consecutive incomplete emit before
  // bouncing a completed user back to the wizard; a genuine incomplete state
  // (e.g. an admin reset) re-emits on the next sync and still routes there.
  int _incompleteEmitsSinceComplete = 0;

  void _onProfileChanged(AsyncValue<UserProfile?> profileAsync) {
    profileAsync.whenData((profile) {
      if (profile == null) {
        if (!_userDeletedCheckPerformed) {
          _userDeletedCheckPerformed = true;
          _verifyUserStillExists();
        }
        return;
      }
      final newScreen = _evaluateScreen(profile);
      if (newScreen == _PcsScreen.wizard && _screen == _PcsScreen.mainNavigation) {
        _incompleteEmitsSinceComplete += 1;
        if (_incompleteEmitsSinceComplete < 2) {
          debugPrint(
            '👤 ProfileCheckScreen: ignoring transient isProfileComplete=false emit '
            '($_incompleteEmitsSinceComplete/2) while on main navigation',          );
          return;
        }
      } else {
        _incompleteEmitsSinceComplete = 0;
      }
      if (_screen != newScreen) {
        final completingWizard =
            _screen == _PcsScreen.wizard &&
            newScreen == _PcsScreen.mainNavigation;
        setState(() {
          if (completingWizard) {
            _pendingMainNavigation = true;
          }
          // Record which gap sent a *completed* profile back to the wizard
          // so it opens on the offending page; an ordinary incomplete
          // profile keeps the draft-restore behavior (no gap override).
          _gapSection = (newScreen == _PcsScreen.wizard &&
                  profile.isProfileComplete)
              ? profileCriticalGapSection(profile)
              : null;
          _screen = newScreen;
        });
        if (completingWizard) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _pendingMainNavigation = false);
            PleaseWaitDialog.hide();
            // New user just completed their profile: default them to
            // Background Matching ON and proactively ask for the required
            // permissions (location always, notifications, battery). The
            // users-table row already defaults to true (Fix 2a); this ensures
            // local prefs + native service agree and permissions are prompted
            // with a surviving context (the wizard itself is unmounted here).
            unawaited(_enableBackgroundMatchingAndPromptPermissions());
          });
        }
      }
    });
  }

  /// Enables Background Matching Mode for freshly completed profiles and
  /// prompts for location/notification/battery permissions. If the user
  /// denies, the existing validate logic will turn the mode back off on the
  /// next resume; the user can re-enable it from Settings → Matching.
  Future<void> _enableBackgroundMatchingAndPromptPermissions() async {
    if (!mounted) return;
    try {
      await ref
          .read(userPreferencesProvider.notifier)
          .setBackgroundMatchingMode(true);
    } catch (_) {}
    if (!mounted) return;
    try {
      await PermissionCoordinator.checkAndPromptIfNeeded(context, ref);
    } catch (_) {}
  }

  Widget _buildCachedProfileFallback(ProfileSyncResult? lastSyncResult) {
    return FutureBuilder<UserProfile?>(
      future: _cachedProfileFuture,
      builder: (context, snapshot) {
        final cachedProfile = snapshot.data;
        if (cachedProfile != null) {
          if (cachedProfile.isProfileComplete) {
            final gap = profileCriticalGapSection(cachedProfile);
            if (gap != null) {
              _gapSection = gap;
              return ProfileWizardScreen(
                user: widget.user,
                isEditing: false,
                initialSection: gap,
              );
            }
            // Same per-user key as the main branch below so a reused state
            // can never resurface the previous account's navigation shell.
            // The shell is on screen: the cold-cache entry hold must not
            // replace it with the startup logo when the live profile
            // arrives a moment later.
            _hasEnteredAppShell = true;
            return MainNavigationScreen(
              key: ValueKey('main-nav-${widget.user.id}'),
            );
          }
          return ProfileWizardScreen(
            user: widget.user,
            isEditing: false,
            initialSection: _gapSection,
          );
        }

        // If the future is still loading, show the loader
        if (snapshot.connectionState != ConnectionState.done) {
          return const StartupLoaderScaffold();
        }

        // Future completed with no cached profile. When the profile cannot be
        // fetched (offline, rate limited, backend error, or a sync that never
        // settles) let the user into the app instead of pulsing the logo
        // forever: the Profile tab surfaces the failure with a retry action,
        // and a late-arriving profile still routes through _onProfileChanged.
        final noProfileTarget = _resolveNoCachedProfileTarget(lastSyncResult);
        if (noProfileTarget != null) {
          _screen = noProfileTarget;
          _enteredViaNoProfileEscape = true;
          _loadingGateWatchdog?.cancel();
          _loadingGateWatchdog = null;
          if (noProfileTarget == _PcsScreen.wizard) {
            return ProfileWizardScreen(user: widget.user, isEditing: false);
          }
          if (!_didRunPermissionGate) {
            _didRunPermissionGate = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              PermissionCoordinator.handleOnResume(context, ref);
            });
          }
          _mainScreen ??= MainNavigationScreen(
            key: ValueKey('main-nav-${widget.user.id}'),
          );
          _hasEnteredAppShell = true;
          return _mainScreen!;
        }

        return const StartupLoaderScaffold();
      },
    );
  }

  Future<UserProfile?> _loadCachedProfile() async {
    try {
      final localDb = ref.read(localDbProvider);
      final raw = await localDb.getLocalProfile(widget.user.id);
      if (raw == null) return null;
      return UserProfile.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkPendingNotification() async {
    if (_notificationChecked) return;
    _notificationChecked = true;

    final initialRoute = await BackgroundService.getInitialRoute();
    if (initialRoute != null && initialRoute['route'] != null) {
      final route = initialRoute['route'] as String;
      if (route.startsWith('/chat/')) {
        final matchId = (initialRoute['matchId'] as String?)?.trim();
        if (matchId != null && matchId.isNotEmpty && mounted) {
          // Use deep-link route so we don't depend on argument maps.
          Navigator.of(context).pushNamed('/chat/$matchId');
        }
      }
    }

    // Static shortcuts may deliver a requested tab index.
    final rawTabIndex = initialRoute?['tabIndex'];
    final parsedTabIndex = rawTabIndex is int
        ? rawTabIndex
        : rawTabIndex is String
        ? int.tryParse(rawTabIndex.trim())
        : null;
    if (parsedTabIndex != null && parsedTabIndex >= 0 && parsedTabIndex <= 4) {
      AppShortcuts.setPendingTabIndex(parsedTabIndex);
      // Also set the provider immediately so if MainNavigationScreen has already been built,
      // it will still land on the right tab.
      try {
        ref.read(navigationIndexProvider.notifier).setIndex(parsedTabIndex);
      } catch (_) {}
    }

    final sharedText = (initialRoute?['sharedText'] as String?)?.trim();
    final sharedFilePath = (initialRoute?['sharedFilePath'] as String?)?.trim();
    if ((sharedText != null && sharedText.isNotEmpty) ||
        (sharedFilePath != null && sharedFilePath.isNotEmpty)) {
      final payload = <String, dynamic>{
        if (sharedText != null && sharedText.isNotEmpty)
          'sharedText': sharedText,
        if (sharedFilePath != null && sharedFilePath.isNotEmpty)
          'sharedFilePath': sharedFilePath,
      };
      try {
        ref.read(pendingAddEventShareProvider.notifier).setPayload(payload);
      } catch (_) {}
      AppShortcuts.setPendingTabIndex(3);
      try {
        ref.read(navigationIndexProvider.notifier).setIndex(3);
      } catch (_) {}
    }
  }

  void _startBackgroundSync(String userId) {
    // Start sync in background without waiting for it
    ref
        .read(profileSyncProvider)
        .syncProfile(userId, source: 'profile-check-startup')
        .then((_) {
          if (kDebugMode) {
            debugPrint('[ProfileCheckScreen] Background sync completed');
          }
        })
        .catchError((e) {
          if (kDebugMode) {
            debugPrint('Background profile sync failed: $e');
          }
        });
  }

  void _scheduleDeferredStartupSync(String userId) {
    if (_startupSyncScheduled) return;
    _startupSyncScheduled = true;
    if (kDebugMode) {
      debugPrint('[ProfileCheckScreen] Scheduling deferred startup sync');
    }
    // Defer past the first Davey frame (cold start ~3.6 s) and the
    // post-frame "Skipped 88 frames" window. The sync is 1-1.2 s of
    // RPC + provider invalidation on the main isolate; running it at
    // 1.8 s meant it overlapped the second-frame jank. 4 s keeps the
    // UI jank-free for the first ~5 s after the screen is shown, and
    // the cached profile from the local DB is shown in the meantime.
    Future.delayed(const Duration(milliseconds: 4000), () {
      if (!mounted) return;
      _startBackgroundSync(userId);
    });
  }

  Future<void> _verifyUserStillExists() async {
    if (!mounted) return;

    // POLICY: never auto-sign-out here. A null profile / missing `users`
    // row is a normal transient state (offline, RLS denial, replication
    // lag, profile not yet created) — not proof of account deletion.
    // Only auth.forced_sign_out_days or an explicit UI logout may sign out.
    try {
      if (!offlineCacheManager.isSupabaseAvailable) {
        if (kDebugMode) {
          debugPrint(
            '[ProfileCheckScreen] Skipping user-exists check (offline)',
          );
        }
        return;
      }
      final supabase = Supabase.instance.client;
      final userId = widget.user.id;

      // Check if user still exists in the database
      final userExists = await supabase
          .from('users')
          .select('id')
          .eq('id', userId)
          .maybeSingle();

      if (!mounted) return;

      if (userExists == null) {
        // Do NOT sign out or redirect: stay logged in and let the profile
        // provider / wizard handle the missing profile (it will show the
        // onboarding wizard to recreate it).
        if (kDebugMode) {
          debugPrint(
            '[ProfileCheckScreen] users row missing — keeping session, NOT signing out',
          );
        }
      }
    } catch (e) {
      debugPrint('[ProfileCheckScreen] Error verifying user existence: $e');
      // Don't redirect on error, just log it and let the profile provider handle it
    }
  }
}
