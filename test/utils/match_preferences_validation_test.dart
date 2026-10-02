import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/match_preferences_validation.dart';

void main() {
  test('marks missing and empty active intent preferences as invalid', () {
    final invalid = invalidGenderPreferenceKeys(
      activeIntentKeys: const ['romantic', 'business_networking'],
      genderPreferences: const {
        'romantic': [],
        'business_networking': ['female'],
      },
    );

    expect(invalid, ['romantic']);
  });

  test('treats blank gender values as missing', () {
    final invalid = invalidGenderPreferenceKeys(
      activeIntentKeys: const ['romantic'],
      genderPreferences: const {
        'romantic': ['', ' '],
      },
    );

    expect(invalid, ['romantic']);
  });

  test('ignores empty preferences for inactive intents', () {
    final invalid = invalidGenderPreferenceKeys(
      activeIntentKeys: const ['romantic'],
      genderPreferences: const {
        'romantic': ['female'],
        'friendship': [],
      },
    );

    expect(invalid, isEmpty);
  });

  test('preserves active intent order for focus recovery', () {
    final invalid = invalidGenderPreferenceKeys(
      activeIntentKeys: const ['romantic', 'friendship', 'business_networking'],
      genderPreferences: const {
        'romantic': [],
        'friendship': [],
        'business_networking': ['female'],
      },
    );

    expect(invalid, ['romantic', 'friendship']);
  });
}
