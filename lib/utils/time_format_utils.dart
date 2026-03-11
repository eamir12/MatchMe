// lib/utils/time_format_utils.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/time_of_day_ranges.dart';
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
    // Use shared day-period ranges
    final dt = DateTime.now();
    final period = TimeOfDayRanges.periodFromDateTime(DateTime(dt.year, dt.month, dt.day, time.hour, time.minute));
    final suffixKey = switch (period) {
      DayPeriodName.morning => 'timeMorning',
      DayPeriodName.afternoon => 'timeAfternoon',
      DayPeriodName.evening => 'timeEvening',
      DayPeriodName.night => 'timeNight',
    };
    final suffix = l10n.getString(suffixKey);
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

String formatDateAndTimeOfDateTimeWithPrefs(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  DateTime dateTime,
) {
  final timeStr = formatTimeOfDateTimeWithPrefs(context, ref, l10n, dateTime);
  final dateStr = DateFormat.yMMMMd(l10n.currentLocale.toLanguageTag()).format(dateTime);
  return '$dateStr · $timeStr';
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

String formatCountdownHms(Duration remaining) {
  var d = remaining;
  if (d.isNegative) d = Duration.zero;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  final hh = hours.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

String formatCountdownHmsWithPrefs(
  BuildContext context,
  WidgetRef ref,
  Duration remaining,
) {
  final pref = ref.watch(userPreferencesProvider).timeFormat;
  final use24 = effectiveUse24HourFormat(context, pref);

  var d = remaining;
  if (d.isNegative) d = Duration.zero;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);

  final hh = use24 ? hours.toString().padLeft(2, '0') : hours.toString();
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

String formatDurationCompact(Duration remaining) {
  var d = remaining;
  if (d.isNegative) d = Duration.zero;
  if (d.inDays > 0) {
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    return '${days}d ${hours}h';
  }
  if (d.inHours > 0) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    return '${hours}h ${minutes}m';
  }
  if (d.inMinutes > 0) {
    final minutes = d.inMinutes;
    return '${minutes}m';
  }
  return '<1m';
}

String formatDurationWords(LocalizationState l10n, Duration remaining) {
  var d = remaining;
  if (d.isNegative) d = Duration.zero;

  String formatCountUnit({
    required int count,
    required String singularKey,
    required String pluralKey,
  }) {
    final key = count == 1 ? singularKey : pluralKey;
    final template = l10n.getString(key);
    if (template.contains('{count}')) {
      return l10n.getString(key, params: {'count': count.toString()});
    }
    if (RegExp(r'\d').hasMatch(template)) return template;
    return '$count $template';
  }

  if (d.inDays > 0) {
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    final dayText = formatCountUnit(
      count: days,
      singularKey: 'durationDay',
      pluralKey: 'durationDays',
    );
    if (hours <= 0) return dayText;
    final hourText = formatCountUnit(
      count: hours,
      singularKey: 'durationHour',
      pluralKey: 'durationHours',
    );
    return '$dayText $hourText';
  }

  if (d.inHours > 0) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final hourText = formatCountUnit(
      count: hours,
      singularKey: 'durationHour',
      pluralKey: 'durationHours',
    );
    if (minutes <= 0) return hourText;
    final minuteText = formatCountUnit(
      count: minutes,
      singularKey: 'durationMinute',
      pluralKey: 'durationMinutes',
    );
    return '$hourText $minuteText';
  }

  if (d.inMinutes > 0) {
    final minutes = d.inMinutes;
    return formatCountUnit(
      count: minutes,
      singularKey: 'durationMinute',
      pluralKey: 'durationMinutes',
    );
  }

  return l10n.getString('durationLessThanOneMinute');
}


