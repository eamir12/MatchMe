// lib/utils/greeting_utils.dart

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/time_of_day_ranges.dart';

/// Mapping from DayPeriod to the translation key base.
String _greetingKeyForPeriod(DayPeriodName p) {
  switch (p) {
    case DayPeriodName.morning:
      return 'goodMorning';
    case DayPeriodName.afternoon:
      return 'goodAfternoon';
    case DayPeriodName.evening:
      return 'goodEvening';
    case DayPeriodName.night:
      return 'goodNight';
  }
}

/// Return a localized, gender-aware greeting for the given [dateTime].
/// If [gender] is provided it will be passed to localization to pick the proper variant.
/// The returned string does NOT include the user's name; caller may append ", {name}!".
String localizedGreeting(LocalizationState l10n, DateTime dateTime, {String? gender}) {
  final period = TimeOfDayRanges.periodFromDateTime(dateTime);
  final key = _greetingKeyForPeriod(period);
  return l10n.getString(key, gender: gender);
}
