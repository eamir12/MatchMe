import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/gender_utils.dart';

void main() {
  group('normalizeGenderKey', () {
    test('lowercases, trims and strips the gender_ prefix', () {
      expect(normalizeGenderKey(' Gender_Female '), 'female');
      expect(normalizeGenderKey('male'), 'male');
    });

    test('collapses the non-binary spellings into one key', () {
      expect(normalizeGenderKey('non-binary'), 'non_binary');
      expect(normalizeGenderKey('nonbinary'), 'non_binary');
      expect(normalizeGenderKey('Non Binary'), 'non_binary');
    });

    test('returns an empty key for missing values', () {
      expect(normalizeGenderKey(null), '');
      expect(normalizeGenderKey('  '), '');
    });
  });

  group('genderOptionLabel', () {
    final l10n = LocalizationState.loading();

    test('translates the display key when one exists', () {
      expect(
        genderOptionLabel(l10n, {
          'key': 'female',
          'displayKey': 'gender_female',
        }),
        'Female',
      );
    });

    test('falls back to a pretty-printed key without a translation', () {
      expect(
        genderOptionLabel(l10n, {'key': 'custom_gender', 'displayKey': ''}),
        'Custom Gender',
      );
    });
  });
}
