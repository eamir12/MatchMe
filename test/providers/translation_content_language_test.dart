import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

/// The UI must lay out in the language of the CONTENT it shows.
///
/// The bug this pins: the app derived the text direction from the language
/// the member PICKED, while the strings on screen could be the bundled
/// English fallback (server copy unavailable, fetch timed out, cache poisoned
/// by an earlier offline session). The result was English narration laid out
/// right-to-left — a state that should be impossible.
///
/// The rule: the direction follows the language of the strings that are
/// actually loaded, never the choice.
void main() {
  group('resolveContentLanguageCode', () {
    test('falls back to English when the server rows are missing', () {
      // A Hebrew member whose Hebrew strings could not be loaded sees the
      // English defaults — so the content is English and must lay out LTR.
      expect(
        resolveContentLanguageCode(localeCode: 'he', hasLocalizedRows: false),
        'en',
      );
      expect(
        resolveContentLanguageCode(localeCode: 'es', hasLocalizedRows: false),
        'en',
      );
    });

    test('keeps the locale when the server rows are there', () {
      expect(
        resolveContentLanguageCode(localeCode: 'he', hasLocalizedRows: true),
        'he',
      );
      expect(
        resolveContentLanguageCode(localeCode: 'es', hasLocalizedRows: true),
        'es',
      );
    });
  });

  group('cachedStringsHoldLocalizedRows', () {
    test('an English fallback cache holds no translated rows', () {
      final defaults = LocalizationState.defaultTranslation('appName');
      expect(
        cachedStringsHoldLocalizedRows(<String, String>{'appName': defaults}),
        isFalse,
      );
    });

    test('a translated cache holds translated rows', () {
      expect(
        cachedStringsHoldLocalizedRows(<String, String>{
          'appName': 'MatchMe',
          'onboardingTourTitle': 'גלו את MatchMe',
        }),
        isTrue,
      );
    });

    test('an empty cache holds no translated rows', () {
      expect(cachedStringsHoldLocalizedRows(const <String, String>{}), isFalse);
    });
  });

  group('resolveCachedContentLanguage', () {
    test('an explicit marker wins over the heuristic', () {
      expect(
        resolveCachedContentLanguage(
          langCode: 'he',
          strings: const <String, String>{'appName': 'MatchMe'},
          marker: 'he',
        ),
        'he',
      );
    });

    test('a legacy cache without a marker is classified by its values', () {
      // A cache written while the server was unreachable holds only the
      // English defaults: the content is English, so it must not be laid out
      // right-to-left just because the member picked Hebrew.
      expect(
        resolveCachedContentLanguage(
          langCode: 'he',
          strings: const <String, String>{
            'appName': 'MatchMe',
            'onboardingTourTitle': 'Discover MatchMe',
          },
        ),
        'en',
      );

      // A genuinely translated cache keeps the locale.
      expect(
        resolveCachedContentLanguage(
          langCode: 'he',
          strings: const <String, String>{
            'appName': 'MatchMe',
            'onboardingTourTitle': 'גלו את MatchMe',
          },
        ),
        'he',
      );
    });

    test('a blank marker falls back to the heuristic', () {
      expect(
        resolveCachedContentLanguage(
          langCode: 'he',
          strings: const <String, String>{'appName': 'MatchMe'},
          marker: '   ',
        ),
        'en',
      );
    });
  });

  group('normalizeContentLanguageCode', () {
    test('lower-cases, trims and drops the region suffix', () {
      expect(normalizeContentLanguageCode('HE'), 'he');
      expect(normalizeContentLanguageCode(' he '), 'he');
      expect(normalizeContentLanguageCode('he-IL'), 'he');
      expect(normalizeContentLanguageCode('he_IL'), 'he');
    });

    test('an empty code is English', () {
      expect(normalizeContentLanguageCode(''), 'en');
      expect(normalizeContentLanguageCode(null), 'en');
    });
  });

  group('LocalizationState direction', () {
    LocalizationState build({
      required Locale locale,
      required String contentLanguageCode,
      TextDirection declared = TextDirection.ltr,
    }) {
      return LocalizationState(
        currentLocale: locale,
        textDirection: declared,
        contentLanguageCode: contentLanguageCode,
        strings: const {},
        supportedLanguages: const [],
      );
    }

    test('English content under a Hebrew locale lays out left-to-right', () {
      // The impossible state from the bug report: English text, RTL layout.
      final state = build(
        locale: const Locale('he'),
        contentLanguageCode: 'en',
        declared: TextDirection.rtl,
      );
      expect(state.contentLanguageCode, 'en');
      expect(state.textDirection, TextDirection.ltr);
    });

    test('Hebrew content always lays out right-to-left', () {
      final state = build(
        locale: const Locale('he'),
        contentLanguageCode: 'he',
        declared: TextDirection.ltr,
      );
      expect(state.textDirection, TextDirection.rtl);
    });

    test('copyWith follows the content language, not the old direction', () {
      final he = build(
        locale: const Locale('he'),
        contentLanguageCode: 'he',
        declared: TextDirection.rtl,
      );
      // The Hebrew copy disappeared (offline) — the UI is English now and
      // must lay out left-to-right.
      expect(
        he.copyWith(contentLanguageCode: 'en').textDirection,
        TextDirection.ltr,
      );
      // And back again.
      expect(
        he.copyWith(contentLanguageCode: 'en').copyWith(
              contentLanguageCode: 'he',
            ).textDirection,
        TextDirection.rtl,
      );
    });

    test('the content language defaults to the current locale', () {
      final state = LocalizationState(
        currentLocale: const Locale('he'),
        textDirection: TextDirection.rtl,
        strings: const {},
        supportedLanguages: const [],
      );
      expect(state.contentLanguageCode, 'he');
      expect(state.textDirection, TextDirection.rtl);
    });
  });
}
