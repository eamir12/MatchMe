import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/onboarding_intro_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The core onboarding tour is a ONE-TIME experience for the whole ACCOUNT.
///
/// The bug this pins: the auto-launch decision was "does this device have a
/// local flag, and if not, does the account record say the tour was seen?" —
/// and a device that could not reach the server could not tell "never seen"
/// from "seen on another device", so it launched the tour again. Switching
/// devices re-showed a tour the member had already watched.
///
/// The rule: the account decides, and an unknown account state never
/// launches the tour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 'member-1';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('hasSeenCoreTourLocally', () {
    test('is false for an account that never saw the tour', () async {
      expect(
        await OnboardingIntroService.instance.hasSeenCoreTourLocally(
          userId: userId,
        ),
        isFalse,
      );
    });

    test('is true once this device consumed the tour', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'onboarding_intro_seen_$userId': '2026-10-21T00:00:00.000Z',
      });
      expect(
        await OnboardingIntroService.instance.hasSeenCoreTourLocally(
          userId: userId,
        ),
        isTrue,
      );
    });

    test('the flag is per account, not per device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'onboarding_intro_seen_$userId': '2026-10-21T00:00:00.000Z',
      });
      expect(
        await OnboardingIntroService.instance.hasSeenCoreTourLocally(
          userId: 'other-member',
        ),
        isFalse,
      );
    });
  });

  group('decideCoreTourLaunch', () {
    test('a device that already consumed the tour never launches it again',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'onboarding_intro_seen_$userId': '2026-10-21T00:00:00.000Z',
      });
      expect(
        await OnboardingIntroService.instance.decideCoreTourLaunch(
          userId: userId,
        ),
        CoreTourLaunchDecision.alreadySeen,
      );
    });

    test('an unreachable account never launches the tour', () async {
      // No Supabase client in a unit test: the account state is unknown, and
      // a one-time tour must not be launched on a guess.
      expect(
        await OnboardingIntroService.instance.decideCoreTourLaunch(
          userId: userId,
        ),
        CoreTourLaunchDecision.unknown,
      );
    });

    test('an anonymous session never launches the tour', () async {
      expect(
        await OnboardingIntroService.instance.decideCoreTourLaunch(),
        CoreTourLaunchDecision.alreadySeen,
      );
    });
  });
}
