// test/providers/plural_translation_test.dart
//
// A countable string must read as a singular when the quantity is one, and
// as the language's plural (or Hebrew's dual) otherwise. These tests pin the
// lookup in LocalizationState.getString / getPluralString for the three
// shipped languages.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

LocalizationState _state({
  required String languageCode,
  required Map<String, String> strings,
  Set<String> dbKeys = const {},
}) {
  return LocalizationState(
    currentLocale: Locale(languageCode),
    textDirection: languageCode == 'he' ? TextDirection.rtl : TextDirection.ltr,
    strings: strings,
    supportedLanguages: const [],
    contentLanguageCode: languageCode,
    dbKeys: dbKeys,
  );
}

/// The English fallbacks only — what the app has before the database copy
/// arrives.
LocalizationState _englishDefaults() {
  return LocalizationState(
    currentLocale: const Locale('en'),
    textDirection: TextDirection.ltr,
    strings: const {},
    supportedLanguages: const [],
  );
}

void main() {
  group('English', () {
    test('the match expiry title is singular for one minute', () {
      final l10n = _englishDefaults();

      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '1'}),
        '1 minute left',
      );
      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '5'}),
        '5 minutes left',
      );
    });

    test('the match expiry body is singular for one minute', () {
      final l10n = _englishDefaults();

      expect(
        l10n.getString(
          'matchExpiryBody',
          params: {'count': '1', 'otherUserName': 'Dana'},
        ),
        'You have 1 minute left to start a chat with Dana.',
      );
    });

    test('a key without a plural variant keeps its base wording', () {
      final l10n = _englishDefaults();

      expect(
        l10n.getString('mapApproxUsersHere', params: {'count': '1'}),
        'Approx users here: 1',
      );
    });

    test('getPluralString writes the number into the template', () {
      final l10n = _englishDefaults();

      expect(l10n.getPluralString('durationMinutes', 1), '1 minute');
      expect(l10n.getPluralString('durationMinutes', 3), '3 minutes');
    });

    test('a compact display value keeps the real quantity for the form', () {
      final l10n = _englishDefaults();

      expect(
        l10n.getPluralString(
          'onlineProvidersEventCount',
          1,
          displayValue: '1',
        ),
        '1 event',
      );
      expect(
        l10n.getPluralString(
          'onlineProvidersEventCount',
          1500,
          displayValue: '1.5k',
        ),
        '1.5k events',
      );
    });

    test('the count parameter can be renamed', () {
      final l10n = _englishDefaults();

      expect(
        l10n.getPluralString(
          'generalAgeYearsOld',
          1,
          countParam: 'age',
        ),
        '1 year old',
      );
      expect(
        l10n.getPluralString(
          'generalAgeYearsOld',
          30,
          countParam: 'age',
        ),
        '30 years old',
      );
    });
  });

  group('Hebrew', () {
    final hebrewStrings = <String, String>{
      'matchExpiryTitle': '{count} דקות נותרו',
      'matchExpiryTitle_one': '{count} דקה נותרה',
      'matchExpiryTitle_two': 'שתי דקות נותרו',
      'durationMinutes': '{count} דקות',
      'durationMinutes_one': '{count} דקה',
      'durationMinutes_two': 'שתי דקות',
    };

    test('picks the singular for one and the dual for two', () {
      final l10n = _state(
        languageCode: 'he',
        strings: hebrewStrings,
        dbKeys: hebrewStrings.keys.toSet(),
      );

      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '1'}),
        '1 דקה נותרה',
      );
      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '2'}),
        'שתי דקות נותרו',
      );
      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '5'}),
        '5 דקות נותרו',
      );
    });

    test('a locale without the singular row falls back to the base key', () {
      final l10n = _state(
        languageCode: 'he',
        strings: const {'matchExpiryTitle': '{count} דקות נותרו'},
        dbKeys: const {'matchExpiryTitle'},
      );

      // The English fallback must not leak into the Hebrew UI.
      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '1'}),
        '1 דקות נותרו',
      );
    });
  });

  group('Spanish', () {
    final spanishStrings = <String, String>{
      'matchExpiryTitle': '{count} minutos restantes',
      'matchExpiryTitle_one': '{count} minuto restante',
    };

    test('picks the singular for one', () {
      final l10n = _state(
        languageCode: 'es',
        strings: spanishStrings,
        dbKeys: spanishStrings.keys.toSet(),
      );

      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '1'}),
        '1 minuto restante',
      );
      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '5'}),
        '5 minutos restantes',
      );
    });
  });

  group('gendered strings', () {
    test('still resolve their gendered variant', () {
      final l10n = _englishDefaults();

      expect(
        l10n.getString('youMatchedBecause', gender: 'female'),
        'You matched because',
      );
    });
  });

  group('shipped copy', () {
    /// The English rows of the plural migration.
    Map<String, String> shippedEnglish() {
      final file = File(
        'supabase/migrations/20262148000000_add_plural_translations.sql',
      );
      expect(file.existsSync(), isTrue, reason: 'the migration must ship');
      final rows = <String, String>{};
      final pattern = RegExp(
        r"\('en',\s*'([^']+)',\s*'((?:[^']|'')*)'\)",
      );
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        rows[match.group(1)!] = match.group(2)!.replaceAll("''", "'");
      }
      return rows;
    }

    test('the countdown notifications are singular for one', () {
      final l10n = _englishDefaults();

      // The notification a member actually reads: "1 minute left".
      expect(
        l10n.getString('matchExpiryTitle', params: {'count': '1'}),
        '1 minute left',
      );
      expect(
        l10n.getString('matchExpiryBody', params: {
          'count': '1',
          'otherUserName': 'Dana',
        }),
        'You have 1 minute left to start a chat with Dana.',
      );
    });

    test('the pinned-location warning ships a singular for one', () {
      final shipped = shippedEnglish();

      expect(
        shipped['pinnedExpiryBodyMinutes_one'],
        contains('expires in {count} minute.'),
      );
      expect(
        shipped['pinnedExpiryBodyHours_one'],
        contains('expires in {count} hour.'),
      );
      expect(shipped['pinnedExpiryTitle'], isNotNull);
    });

    test('every shipped singular has a bundled English fallback', () {
      final shipped = shippedEnglish();
      final variants = shipped.keys.where(
        (key) => key.endsWith('_one') || key.endsWith('_two'),
      );

      final missing = <String>[];
      for (final key in variants) {
        // The pinned-location rows belong to the Edge Function and the
        // admin* rows to the admin dashboard; both keep their own fallbacks.
        if (key.startsWith('pinnedExpiry')) continue;
        if (key.startsWith('admin') || key.startsWith('matchInspector')) {
          continue;
        }
        if (LocalizationState.defaultTranslation(key) == '[$key]') {
          missing.add(key);
        }
      }

      expect(
        missing,
        isEmpty,
        reason:
            'Plural variants without a built-in fallback. Add them to '
            'lib/providers/locale_provider.dart.',
      );
    });

    test('the shipped English singular matches the built-in fallback', () {
      final shipped = shippedEnglish();
      final drifted = <String>[];

      for (final entry in shipped.entries) {
        if (!entry.key.endsWith('_one')) continue;
        if (entry.key.startsWith('pinnedExpiry')) continue;
        if (entry.key.startsWith('admin') || entry.key.startsWith('matchInspector')) {
          continue;
        }
        final fallback = LocalizationState.defaultTranslation(entry.key);
        if (fallback == '[${entry.key}]') continue;
        if (fallback == entry.value) continue;
        drifted.add(
          '${entry.key}\n'
          '  shipped : ${entry.value}\n'
          '  fallback: $fallback',
        );
      }

      expect(
        drifted,
        isEmpty,
        reason:
            'The shipped English plural copy drifted from the built-in '
            'fallbacks in locale_provider.dart. Update the migration.',
      );
    });

    test('every shipped plural key ships in all three languages', () {
      final file = File(
        'supabase/migrations/20262148000000_add_plural_translations.sql',
      );
      final text = file.readAsStringSync();
      final pattern = RegExp(
        r"\('(en|es|he)',\s*'([^']+)',\s*'((?:[^']|'')*)'\)",
      );
      final byLocale = <String, Set<String>>{'en': {}, 'es': {}, 'he': {}};
      for (final match in pattern.allMatches(text)) {
        byLocale[match.group(1)!]!.add(match.group(2)!);
      }

      final missing = <String>[];
      for (final key in byLocale['en']!) {
        if (key.startsWith('pinnedExpiry')) continue;
        for (final locale in ['es', 'he']) {
          if (!byLocale[locale]!.contains(key)) {
            missing.add('$locale:$key');
          }
        }
      }

      expect(
        missing,
        isEmpty,
        reason: 'Plural keys that are not translated in every language.',
      );
    });
  });
}
