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
  test('religiosity filter matches only the selected degree', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'religiosity': ['moderately religious'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'religiosity': 'Moderately religious'}),
        'romantic',
      ),
      isTrue,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'religiosity': 'Very religious'}),
        'romantic',
      ),
      isFalse,
    );
    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'religiosity': 'Prefer not to say'}),
        'romantic',
      ),
      isFalse,
    );
  });

  test('religiosity filter rejects candidates without the field', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'religiosity': ['not religious'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(religion: const {'religion': 'Christianity'}),
        'romantic',
      ),
      isFalse,
    );
  });

  test('any or empty religiosity filter accepts missing the field', () {
    final anyViewer = _profile(
      religionFilters: const {
        'romantic': {
          'religiosity': ['any'],
        },
      },
    );
    final emptyViewer = _profile(
      religionFilters: const {
        'romantic': {'religiosity': <String>[]},
      },
    );
    final candidate = _profile(religion: const {'religion': 'Christianity'});

    expect(anyViewer.isCompatibleWithFilters(candidate, 'romantic'), isTrue);
    expect(emptyViewer.isCompatibleWithFilters(candidate, 'romantic'), isTrue);
  });

  test('religion and religiosity filters must both match', () {
    final viewer = _profile(
      religionFilters: const {
        'romantic': {
          'religions': ['christianity'],
          'religiosity': ['very religious'],
        },
      },
    );

    expect(
      viewer.isCompatibleWithFilters(
        _profile(
          religion: const {
            'religion': 'Christianity',
            'religiosity': 'Very religious',
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
            'religiosity': 'Not religious',
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
            'religiosity': 'Very religious',
          },
        ),
        'romantic',
      ),
      isFalse,
    );
  });
}
