// lib/screens/auth/profile_check_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/screens/main_navigation_screen.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/services/background_service.dart';
import 'package:matchme/utils/permission_coordinator.dart';
import 'package:matchme/utils/app_shortcuts.dart';
import 'package:matchme/providers/home_providers.dart';

class ProfileCheckScreen extends ConsumerStatefulWidget {
  final User user;
  const ProfileCheckScreen({super.key, required this.user});

  @override
  ConsumerState<ProfileCheckScreen> createState() => _ProfileCheckScreenState();
}

class _ProfileCheckScreenState extends ConsumerState<ProfileCheckScreen> {
  bool _notificationChecked = false;
  bool _didRunPermissionGate = false;

  @override
  void initState() {
    super.initState();

    // Kick this off immediately so shortcut intents can influence the initial tab
    // before MainNavigationScreen is constructed.
    _checkPendingNotification();

    // Run sync immediately (async) to avoid blocking startup in background tabs.
    // We use Future.delayed instead of addPostFrameCallback because background tabs
    // might stop rendering frames, preventing the sync from starting.
    Future.delayed(Duration.zero, () {
      if (!mounted) return;
      debugPrint('[ProfileCheckScreen] Starting background sync for user ${widget.user.id}');
      _startBackgroundSync(widget.user.id);

      // Keep native-side permission notifications localized.
      PermissionCoordinator.syncNativePermissionStrings(ref);

      // Failure-driven: if native recorded a real issue (e.g. service restart/permission failure), prompt once.
      PermissionCoordinator.handleOnResume(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    // Watch the StreamProvider for local profile data
    final profileAsync = ref.watch(userProfileProvider(widget.user.id));

    return profileAsync.when(
      data: (profile) {
        // We have data from the local DB
        if (profile != null) {
          if (profile.isProfileComplete) {
            debugPrint('[ProfileCheckScreen] Profile complete, navigating to MainNavigationScreen');
            // Failure-driven: do not proactively prompt. Only surface issues recorded by native failures.
            if (!_didRunPermissionGate) {
              _didRunPermissionGate = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                PermissionCoordinator.handleOnResume(context, ref);
              });
            }
            // Profile is complete, go to the main app
            return MainNavigationScreen();
          } else {
            debugPrint('[ProfileCheckScreen] Profile incomplete, navigating to ProfileWizardScreen');
            // Profile is not complete, go to the wizard
            return ProfileWizardScreen(user: widget.user, isEditing: false);
          }
        }
        // If profile is null, show loading while sync happens in background
        debugPrint('[ProfileCheckScreen] Profile is null, showing spinner');
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
      loading: () {
        debugPrint('[ProfileCheckScreen] Profile loading...');
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
      error: (e, s) {
        debugPrint('[ProfileCheckScreen] Profile error: $e');
        return Scaffold(
          body: Center(
            child: Text('${l10n.getString('generalErrorLoadingProfile')}: $e'),
          ),
        );
      },
    );
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
        if (sharedText != null && sharedText.isNotEmpty) 'sharedText': sharedText,
        if (sharedFilePath != null && sharedFilePath.isNotEmpty) 'sharedFilePath': sharedFilePath,
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
    ref.read(profileSyncProvider).syncProfile(userId).then((_) {
      debugPrint('[ProfileCheckScreen] Background sync completed for user $userId');
    }).catchError((e) {
      // Log error but don't crash the app
      debugPrint('Background profile sync failed: $e');
    });
  }
}
