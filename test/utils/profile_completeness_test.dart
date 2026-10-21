import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/utils/profile_completeness.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';

UserProfile _profile({
  List<String> activeModes = const ['romantic', 'business_networking'],
  Map<String, dynamic>? religion,
}) {
  return UserProfile(
    id: 'test-user',
    name: 'Test User',
    preferredLanguage: 'en',
    activeModes: activeModes,
    subIntents: const {},
    personalInterests: const {
      'fitness': ['hiking'],
    },
    businessInterests: const {
      'technology': ['software'],
    },
    languagesKnown: const {
      'languages': ['en'],
      'other': ['es'],
    },
    subscriptionTier: 'free',
    isProfileComplete: true,
    matchRadiusDefault: 10,
    gpsIntervalDefault: 60,
    smartGpsThrottlingEnabled: false,
    sharedEventMatchingEnabled: false,
    sharedMovementMatchingEnabled: false,
    editableProfileFields: const [],
    genderPreferences: const {},
    agePreferences: const {},
    lifestyle: const {'smoking': 'never'},
    family: const {'has_children': false},
    religion: religion,
    lifestyleFilters: const {},
    familyFilters: const {},
    religionFilters: const {},
    heightPreferences: const {},
    photos: const ['a', 'b', 'c'],
    bio: 'Hello',
    occupation: 'Engineer',
    education: 'BSc',
    height: 180,
    instagramUrl: 'https://instagram.com/test',
  );
}

void main() {
  test('religion is worth exactly 10 points for social intents', () {
    final withoutReligion = _profile();
    final withReligion = _profile(
      religion: const {
        'religion': 'Christianity',
        'denomination': 'christianity__catholic',
        'practice': 'weekly',
      },
    );

    expect(ProfileCompleteness.score(withoutReligion), 90);
    expect(ProfileCompleteness.score(withReligion), 100);
    expect(
      ProfileCompleteness.remainingItems(withoutReligion).single.labelKey,
      'profileCompletionItemReligion',
    );
  });

  test('religion is not scored for business-only profiles', () {
    final profile = _profile(activeModes: const ['business_networking']);

    expect(ProfileCompleteness.score(profile), 100);
    expect(
      ProfileCompleteness.items(
        profile,
      ).where((i) => i.section == ProfileWizardSection.religion),
      isEmpty,
    );
  });

  test('an empty religion map is incomplete', () {
    expect(ProfileCompleteness.score(_profile(religion: const {})), 90);
  });

  test('copyWith can clear religion and keeps it when omitted', () {
    final profile = _profile(religion: const {'religion': 'Christianity'});

    expect(profile.copyWith().religion, isNotNull);
    expect(profile.copyWith(religion: null).religion, isNull);
    expect(
      profile.copyWith(religion: const {'religion': 'Islam'}).religion,
      const {'religion': 'Islam'},
    );
  });

  test('clearing religion drops the score from 100 to 90', () {
    final full = _profile(religion: const {'religion': 'Christianity'});

    expect(ProfileCompleteness.score(full), 100);
    expect(ProfileCompleteness.score(full.copyWith(religion: null)), 90);
  });
}
