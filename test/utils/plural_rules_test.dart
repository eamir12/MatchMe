// test/utils/plural_rules_test.dart
//
// The app picks the noun form from the CLDR cardinal rules of the content
// language. These tests pin the rules for the three shipped languages so a
// change to lib/utils/plural_rules.dart cannot silently change what the app
// shows for "1" and "2".
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/plural_rules.dart';

void main() {
  group('English', () {
    test('uses the singular only for exactly one', () {
      expect(
        pluralCategoryFor(languageCode: 'en', count: 1),
        PluralCategory.one,
      );
      for (final count in [0, 2, 3, 10, 21, 100]) {
        expect(
          pluralCategoryFor(languageCode: 'en', count: count),
          PluralCategory.other,
          reason: '$count must be plural in English',
        );
      }
    });

    test('treats a whole double like the integer', () {
      expect(
        pluralCategoryFor(languageCode: 'en', count: 1.0),
        PluralCategory.one,
      );
      expect(
        pluralCategoryFor(languageCode: 'en', count: 1.5),
        PluralCategory.other,
      );
    });
  });

  group('Spanish', () {
    test('uses the singular only for exactly one', () {
      expect(
        pluralCategoryFor(languageCode: 'es', count: 1),
        PluralCategory.one,
      );
      for (final count in [0, 2, 3, 10, 21]) {
        expect(
          pluralCategoryFor(languageCode: 'es', count: count),
          PluralCategory.other,
          reason: '$count must be plural in Spanish',
        );
      }
    });
  });

  group('Hebrew', () {
    test('has a dual for exactly two', () {
      expect(
        pluralCategoryFor(languageCode: 'he', count: 1),
        PluralCategory.one,
      );
      expect(
        pluralCategoryFor(languageCode: 'he', count: 2),
        PluralCategory.two,
      );
      for (final count in [0, 3, 10, 21, 100]) {
        expect(
          pluralCategoryFor(languageCode: 'he', count: count),
          PluralCategory.other,
          reason: '$count must be plural in Hebrew',
        );
      }
    });

    test('accepts the legacy language code and a region suffix', () {
      expect(
        pluralCategoryFor(languageCode: 'iw', count: 2),
        PluralCategory.two,
      );
      expect(
        pluralCategoryFor(languageCode: 'he-IL', count: 2),
        PluralCategory.two,
      );
    });
  });

  group('unknown languages', () {
    test('fall back to the English rules', () {
      expect(
        pluralCategoryFor(languageCode: 'fr', count: 1),
        PluralCategory.one,
      );
      expect(
        pluralCategoryFor(languageCode: 'fr', count: 2),
        PluralCategory.other,
      );
      expect(
        pluralCategoryFor(languageCode: '', count: 1),
        PluralCategory.one,
      );
    });
  });

  test('the category name doubles as the translation key suffix', () {
    expect(PluralCategory.one.keySuffix, 'one');
    expect(PluralCategory.two.keySuffix, 'two');
    expect(PluralCategory.other.keySuffix, 'other');
    expect(PluralCategory.tryParse('one'), PluralCategory.one);
    expect(PluralCategory.tryParse('nope'), isNull);
    expect(PluralCategory.tryParse(null), isNull);
  });
}
