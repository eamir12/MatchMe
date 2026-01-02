// lib/utils/time_format_utils.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';

bool effectiveUse24HourFormat(
  BuildContext context,
  TimeFormatPreference pref,
) {
  switch (pref) {
    case TimeFormatPreference.h24:
      return true;
    case TimeFormatPreference.h12:
      return false;
    case TimeFormatPreference.system:
      return MediaQuery.alwaysUse24HourFormatOf(context);
  }
}

String formatTimeOfDayWithPrefs(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  TimeOfDay time,
) {
  final pref = ref.watch(userPreferencesProvider).timeFormat;
  final use24 = effectiveUse24HourFormat(context, pref);
  return formatTimeOfDay(l10n, time, use24: use24);
}

String formatTimeOfDay(
  LocalizationState l10n,
  TimeOfDay time, {
  required bool use24,
}) {
  if (use24) {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
  final mm = time.minute.toString().padLeft(2, '0');

  // Special handling for Hebrew when using 12-hour format
  if (l10n.currentLocale.languageCode == 'he') {
    final fullHour = time.hour; // 0-23
    String suffix;

    if (fullHour >= 4 && fullHour < 12) {
      suffix = l10n.getString('timeMorning'); // בוקר
    } else if (fullHour >= 12 && fullHour < 18) {
      suffix = l10n.getString('timeAfternoon'); // אחר הצהריים
    } else if (fullHour >= 18 && fullHour < 22) {
      suffix = l10n.getString('timeEvening'); // ערב
    } else {
      suffix = l10n.getString('timeNight'); // לילה
    }

    return '$hour:$mm $suffix';
  }

  final suffix = time.period == DayPeriod.am
      ? l10n.getString('timeAM')
      : l10n.getString('timePM');
  return '$hour:$mm $suffix';
}

String formatTimeOfDateTimeWithPrefs(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  DateTime dateTime,
) {
  final pref = ref.watch(userPreferencesProvider).timeFormat;
  final use24 = effectiveUse24HourFormat(context, pref);
  final t = TimeOfDay.fromDateTime(dateTime);
  return formatTimeOfDay(l10n, t, use24: use24);
}

/// Compute age in years from a birth date, considering month/day so it is accurate
/// around birthdays. An optional [now] parameter can be supplied for testing.
int calculateAgeFromDate(DateTime birthDate, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  int age = reference.year - birthDate.year;
  if (reference.month < birthDate.month || (reference.month == birthDate.month && reference.day < birthDate.day)) {
    age -= 1;
  }
  return age;
}



