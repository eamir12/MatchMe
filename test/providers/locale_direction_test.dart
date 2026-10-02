import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Direction is derived from the language code, never from data.
///
/// The bug this pins: the app read `text_direction` from `app_languages`,
/// which is seeded outside the migration history, and `AppLanguage.direction`
/// defaulted to LTR. A null or 'LTR' row for Hebrew rendered the whole UI —
/// every chevron, every row — left to right, with no way for the code to notice.
void main() {
  group('isRtlLanguageCode', () {
    test('recognises the shipped Hebrew locale', () {
      expect(isRtlLanguageCode('he'), isTrue);
      expect(isRtlLanguageCode('HE'), isTrue);
      expect(isRtlLanguageCode('  he  '), isTrue);
    });

    test('recognises other RTL languages and legacy codes', () {
      for (final code in [
        'ar', 'fa', 'ur', 'ps', 'sd', 'yi', 'dv', 'ku', 'ckb', 'iw',
      ]) {
        expect(isRtlLanguageCode(code), isTrue, reason: code);
      }
    });

    test('strips region and script suffixes', () {
      expect(isRtlLanguageCode('he-IL'), isTrue);
      expect(isRtlLanguageCode('ar-EG'), isTrue);
      expect(isRtlLanguageCode('he_IL'), isTrue);
    });

    test('the other shipped locales are LTR', () {
      expect(isRtlLanguageCode('en'), isFalse);
      expect(isRtlLanguageCode('es'), isFalse);
    });

    test('Serbian in Latin script stays LTR', () {
      // The one script-tagged exception: sr-Latn must not inherit sr-Cyrl's
      // direction.
      expect(isRtlLanguageCode('sr-Latn'), isFalse);
      expect(isRtlLanguageCode('sr'), isFalse);
    });

    test('empty and null are not RTL', () {
      expect(isRtlLanguageCode(null), isFalse);
      expect(isRtlLanguageCode(''), isFalse);
      expect(isRtlLanguageCode('   '), isFalse);
    });
  });

  group('AppLanguage', () {
    test('derives RTL from the code with no direction supplied', () {
      // This is the case that was broken: the default was LTR regardless.
      expect(
        AppLanguage(code: 'he', displayName: 'עברית').direction,
        TextDirection.rtl,
      );
      expect(
        AppLanguage(code: 'en', displayName: 'English').direction,
        TextDirection.ltr,
      );
      expect(
        AppLanguage(code: 'es', displayName: 'Español').direction,
        TextDirection.ltr,
      );
    });

    test('an explicit direction is honoured when it agrees with the code', () {
      expect(
        AppLanguage(
          code: 'he',
          displayName: 'עברית',
          direction: TextDirection.rtl,
        ).direction,
        TextDirection.rtl,
      );
    });
  });

  group('LocalizationState', () {
    LocalizationState build(Locale locale, TextDirection declared) {
      return LocalizationState(
        currentLocale: locale,
        textDirection: declared,
        strings: const {},
        supportedLanguages: const [],
      );
    }

    test('a Hebrew locale can never be LTR, whatever the caller declares', () {
      expect(
        build(const Locale('he'), TextDirection.ltr).textDirection,
        TextDirection.rtl,
        reason: 'a declared LTR must be overridden for an RTL locale',
      );
    });

    test('an English locale can never be RTL', () {
      expect(
        build(const Locale('en'), TextDirection.rtl).textDirection,
        TextDirection.ltr,
      );
    });

    test('a correct declaration is left alone', () {
      expect(
        build(const Locale('he'), TextDirection.rtl).textDirection,
        TextDirection.rtl,
      );
      expect(
        build(const Locale('en'), TextDirection.ltr).textDirection,
        TextDirection.ltr,
      );
    });

    test('copyWith cannot smuggle a wrong direction back in', () {
      final he = build(const Locale('he'), TextDirection.rtl);
      final stillHe = he.copyWith(textDirection: TextDirection.ltr);
      expect(stillHe.textDirection, TextDirection.rtl);

      final en = build(const Locale('en'), TextDirection.ltr);
      expect(
        en.copyWith(textDirection: TextDirection.rtl).textDirection,
        TextDirection.ltr,
      );
    });

    test('the loading state is LTR for English', () {
      expect(
        LocalizationState.loading().textDirection,
        TextDirection.ltr,
      );
    });
  });
}
