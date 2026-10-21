// test/utils/localized_duration_test.dart
//
// A countdown names several units at once ("1 hour, 5 minutes and 3
// seconds"). Every unit carries its own quantity, so every unit is
// translated on its own and the parts are joined by a translated connector.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/localized_duration.dart';
import 'package:matchme/utils/time_format_utils.dart';

LocalizationState _state({
  required String languageCode,
  required Map<String, String> strings,
}) {
  return LocalizationState(
    currentLocale: Locale(languageCode),
    textDirection: languageCode == 'he' ? TextDirection.rtl : TextDirection.ltr,
    strings: strings,
    supportedLanguages: const [],
    contentLanguageCode: languageCode,
    dbKeys: strings.keys.toSet(),
  );
}

void main() {
  test('every unit takes the singular for one', () {
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    expect(
      formatDurationParts(l10n.getString, hours: 1, minutes: 1, seconds: 1),
      '1 hour, 1 minute and 1 second',
    );
    expect(
      formatDurationParts(l10n.getString, hours: 2, minutes: 5, seconds: 3),
      '2 hours, 5 minutes and 3 seconds',
    );
  });

  test('a unit left out is not rendered', () {
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    expect(
      formatDurationParts(l10n.getString, minutes: 5),
      '5 minutes',
    );
  });

  test('the parts are joined by a translated connector', () {
    final l10n = _state(
      languageCode: 'he',
      strings: const {
        'durationHours': '{count} שעות',
        'durationHours_one': '{count} שעה',
        'durationMinutes': '{count} דקות',
        'durationMinutes_one': '{count} דקה',
        'durationListAnd': '{first} ו-{second}',
        'durationListCommaAnd': '{first}, {second} ו-{third}',
      },
    );

    expect(
      formatDurationParts(l10n.getString, hours: 1, minutes: 5),
      '1 שעה ו-5 דקות',
    );
  });

  test('the word duration picks the singular for every unit', () {
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    expect(
      formatDurationWords(l10n, const Duration(hours: 1, minutes: 30)),
      '1 hour and 30 minutes',
    );
    expect(
      formatDurationWords(l10n, const Duration(days: 2, hours: 3)),
      '2 days and 3 hours',
    );
    expect(
      formatDurationWords(l10n, const Duration(minutes: 1)),
      '1 minute',
    );
  });
}
