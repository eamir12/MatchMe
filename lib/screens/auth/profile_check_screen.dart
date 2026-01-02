// lib/screens/auth/profile_check_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/main_navigation_screen.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileCheckScreen extends ConsumerWidget {
  final User user;
  const ProfileCheckScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    // Watch the StreamProvider for local profile data
    final profileAsync = ref.watch(userProfileProvider(user.id));

    // Start background sync when the screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startBackgroundSync(ref, user.id);
    });

    return profileAsync.when(
      data: (profile) {
        // We have data from the local DB
        if (profile != null) {
          if (profile.isProfileComplete) {
            // Profile is complete, go to the main app
            return MainNavigationScreen();
          } else {
            // Profile is not complete, go to the wizard
            return ProfileWizardScreen(user: user, isEditing: false);
          }
        }
        // If profile is null, show loading while sync happens in background
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, s) => Scaffold(
        body: Center(
          child: Text('${l10n.getString('generalErrorLoadingProfile')}: $e'),
        ),
      ),
    );
  }

  void _startBackgroundSync(WidgetRef ref, String userId) {
    // Start sync in background without waiting for it
    ref.read(profileSyncProvider).syncProfile(userId).catchError((e) {
      // Log error but don't crash the app
      debugPrint('Background profile sync failed: $e');
    });
  }
}
