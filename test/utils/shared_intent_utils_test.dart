import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/utils/shared_intent_utils.dart';

void main() {
  group('shared intent helpers', () {
    UserProfile buildProfile({
      List<String>? activeModes,
      Map<String, List<String>>? subIntents,
    }) {
      return UserProfile(
        id: 'user-1',
        name: 'Test User',
        preferredLanguage: 'en',
        activeModes: activeModes ?? const <String>[],
        subIntents: subIntents ?? const <String, List<String>>{},
        personalInterests: const <String, List<String>>{},
        businessInterests: const <String, List<String>>{},
        languagesKnown: const <String, List<String>>{},
        subscriptionTier: 'free',
        isProfileComplete: true,
        matchRadiusDefault: 10,
        gpsIntervalDefault: 60,
        smartGpsThrottlingEnabled: false,
        sharedEventMatchingEnabled: false,
        sharedMovementMatchingEnabled: false,
        editableProfileFields: const <String>[],
        genderPreferences: const <String, List<String>>{},
        agePreferences: const <String, List<double>>{},
        lifestyleFilters: const <String, Map<String, dynamic>>{},
        familyFilters: const <String, Map<String, dynamic>>{},
        religionFilters: const <String, Map<String, dynamic>>{},
        heightPreferences: const <String, Map<String, dynamic>>{},
        photos: const <String>[],
      );
    }

    test('finds shared intent keys from overlapping active modes', () {
      final current = buildProfile(activeModes: ['romantic', 'friendship']);
      final other = buildProfile(
        activeModes: ['romantic', 'business_networking'],
      );

      final shared = getSharedIntentKeys(
        currentProfile: current,
        otherProfile: other,
      );

      expect(shared, ['romantic']);
    });

    test(
      'keeps a shared main intent available even without matching sub-intents',
      () {
        final current = buildProfile(
          activeModes: ['romantic'],
          subIntents: {
            'romantic': ['casual'],
          },
        );
        final other = buildProfile(
          activeModes: ['romantic'],
          subIntents: {
            'romantic': ['long_term'],
          },
        );

        final shared = getSharedIntentKeys(
          currentProfile: current,
          otherProfile: other,
        );

        expect(shared, ['romantic']);
      },
    );
  });
}
