import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';
import 'package:matchme/utils/string_extensions.dart';

UserProfile _profile({String name = 'Test User'}) {
  return UserProfile(
    id: 'test-user',
    name: name,
    dateOfBirth: DateTime(1990, 1, 1),
    preferredLanguage: 'en',
    activeModes: const ['romantic', 'business_networking'],
    subIntents: const {
      'romantic': ['dating'],
      'business_networking': ['networking'],
    },
    personalInterests: const {
      'fitness': ['hiking'],
    },
    businessInterests: const {
      'technology': ['software'],
    },
    languagesKnown: const {
      'languages': ['en'],
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
    lifestyleFilters: const {},
    familyFilters: const {},
    religionFilters: const {},
    heightPreferences: const {},
    photos: const ['a', 'b', 'c'],
    occupation: 'Engineer',
    education: 'BSc',
  );
}

void main() {
  group('hasFirstAndLastName', () {
    test('accepts a first and a last name', () {
      expect('Test User'.hasFirstAndLastName, isTrue);
      expect('  Test   User  '.hasFirstAndLastName, isTrue);
      expect('דוד לוי'.hasFirstAndLastName, isTrue);
      expect('John van der Berg'.hasFirstAndLastName, isTrue);
    });

    test('strips the bidi marks the app adds around names', () {
      expect('\u200ETest User\u200E'.hasFirstAndLastName, isTrue);
      expect('\u200FTest User\u200F'.hasFirstAndLastName, isTrue);
    });

    test('rejects a single word, whitespace-only and empty values', () {
      expect('Test'.hasFirstAndLastName, isFalse);
      expect('Test\u200E'.hasFirstAndLastName, isFalse);
      expect(''.hasFirstAndLastName, isFalse);
      expect('   '.hasFirstAndLastName, isFalse);
      expect('\u200E\u200F'.hasFirstAndLastName, isFalse);
    });

    test('agrees with the display formatter', () {
      expect('Test'.formatAsFirstNameLastInitial(fallback: 'Someone'), 'Someone');
      expect('Test User'.formatAsFirstNameLastInitial(), '\u200ETest U.\u200E');
    });
  });

  group('profileCriticalGapSection name rule', () {
    test('a complete profile with a full name has no gap', () {
      expect(profileCriticalGapSection(_profile()), isNull);
    });

    test('a single-word name is a Basics gap', () {
      expect(
        profileCriticalGapSection(_profile(name: 'Test')),
        ProfileWizardSection.basics,
      );
      expect(
        profileCriticalGapSection(_profile(name: '\u200ETest\u200E')),
        ProfileWizardSection.basics,
      );
    });

    test('an empty name is a Basics gap', () {
      expect(
        profileCriticalGapSection(_profile(name: '')),
        ProfileWizardSection.basics,
      );
      expect(
        profileCriticalGapSection(_profile(name: '   ')),
        ProfileWizardSection.basics,
      );
    });
  });
}
