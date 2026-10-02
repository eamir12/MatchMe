// Onboarding introduction tour persistence.
//
// Tracks whether the interactive app-introduction wizard has been shown to a
// user (device-local). The tour auto-runs once after the profile is complete
// (MainNavigationScreen checks this on startup and right after the profile
// wizard finishes) and can be replayed any time from Settings. Finishing or
// skipping the tour both mark it as seen — neither should repeat on its own.
//
// The flag is per account: two members sharing a device each get the tour on
// their first login. A null user id falls back to a shared device-level key
// (the tour is still only ever shown, never blocked, on lookup failure).

import 'package:shared_preferences/shared_preferences.dart';

class OnboardingIntroService {
  OnboardingIntroService._internal();
  static final OnboardingIntroService instance =
      OnboardingIntroService._internal();

  static const String _prefsKeyPrefix = 'onboarding_intro_seen_';
  static const String _prefsKeyNoUser = 'onboarding_intro_seen';

  String _keyFor(String? userId) {
    final id = userId?.trim() ?? '';
    return id.isEmpty ? _prefsKeyNoUser : '$_prefsKeyPrefix$id';
  }

  /// True when the introduction tour was already completed or skipped by
  /// this user. Storage failures resolve to `false` — the tour will simply
  /// be offered again rather than never.
  Future<bool> hasSeenIntro({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyFor(userId)) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Persists that the tour was seen (completed or skipped).
  Future<void> markIntroSeen({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyFor(userId), true);
    } catch (_) {
      // Non-fatal: the tour may repeat on the next launch.
    }
  }
}
