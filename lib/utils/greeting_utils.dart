// lib/utils/greeting_utils.dart

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/time_of_day_ranges.dart';
import 'package:timezone/timezone.dart' as tz;

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
String localizedGreeting(
  LocalizationState l10n,
  DateTime dateTime, {
  String? gender,
}) {
  final period = TimeOfDayRanges.periodFromDateTime(dateTime);
  final key = _greetingKeyForPeriod(period);
  return l10n.getString(key, gender: gender);
}

/// Returns `true` if [dateOfBirth] falls on the current calendar day in the
/// user's local timezone.  When no timezone is provided the device clock is used.
bool isUsersBirthdayToday({
  required DateTime? dateOfBirth,
  required String? userTimezone,
}) {
  if (dateOfBirth == null) return false;

  DateTime localNow;
  final timezoneName = (userTimezone ?? '').trim();
  if (timezoneName.isNotEmpty) {
    try {
      final location = tz.getLocation(timezoneName);
      localNow = tz.TZDateTime.from(DateTime.now().toUtc(), location);
    } catch (_) {
      localNow = DateTime.now();
    }
  } else {
    localNow = DateTime.now();
  }

  return localNow.month == dateOfBirth.month && localNow.day == dateOfBirth.day;
}
