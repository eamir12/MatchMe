import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';

UserProfile _profile({
  Map<String, dynamic>? religion,
  Map<String, Map<String, dynamic>> religionFilters = const {},
}) {
  return UserProfile(
    id: 'test-user',
    name: 'Test User',
    preferredLanguage: 'en',
    activeModes: const ['romantic'],
    subIntents: const {},
    personalInterests: const {},
    businessInterests: const {},
    languagesKnown: const {},
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
    religionFilters: religionFilters,
    heightPreferences: const {},
    photos: const [],
    religion: religion,
  );
}

void main() {
  test('denomination filter matches only the selected branch', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'denominations': ['christianity__catholic'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Christianity',
            'denomination': 'christianity__catholic',
          },
        ),
        'romantic',
      ),
      isTrue,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Christianity',
            'denomination': 'christianity__protestant',
          },
        ),
        'romantic',
      ),
      isFalse,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'religion': 'Christianity'}),
        'romantic',
      ),
      isFalse,
    );
  });

  test('practice filter matches only the selected frequency', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'practices': ['weekly'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'practice': 'weekly'}),
        'romantic',
      ),
      isTrue,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'practice': 'daily'}),
        'romantic',
      ),
      isFalse,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'religion': 'Christianity'}),
        'romantic',
      ),
      isFalse,
    );
  });

  test('any or empty belief filters accept missing fields', () {
    final anyViewer = _profile(
      religionFilters: const {
        'romantic': {
          'religions': ['any'],
          'denominations': ['any'],
          'practices': ['any'],
        },
      },
    );
    final emptyViewer = _profile(
      religionFilters: const {
        'romantic': {
          'religions': <String>[],
          'denominations': <String>[],
          'practices': <String>[],
        },
      },
    );
    final candidate = _profile(religion: const {'religion': 'Christianity'});

    expect(anyViewer.isCompatibleWithFilters(candidate, 'romantic'), isTrue);
    expect(emptyViewer.isCompatibleWithFilters(candidate, 'romantic'), isTrue);
  });

  test('religion, denomination, and practice filters must all match', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'religions': ['christianity'],
          'denominations': ['christianity__catholic'],
          'practices': ['weekly'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Christianity',
            'denomination': 'christianity__catholic',
            'practice': 'weekly',
          },
        ),
        'romantic',
      ),
      isTrue,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Christianity',
            'denomination': 'christianity__catholic',
            'practice': 'daily',
          },
        ),
        'romantic',
      ),
      isFalse,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Christianity',
            'denomination': 'christianity__protestant',
            'practice': 'weekly',
          },
        ),
        'romantic',
      ),
      isFalse,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Islam',
            'denomination': 'christianity__catholic',
            'practice': 'weekly',
          },
        ),
        'romantic',
      ),
      isFalse,
    );
  });

  test('denomination filter accepts multiple selected branches', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'denominations': ['christianity__catholic', 'islam__sunni'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'denomination': 'islam__sunni'}),
        'romantic',
      ),
      isTrue,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'denomination': 'islam__shia'}),
        'romantic',
      ),
      isFalse,
    );
  });
}
