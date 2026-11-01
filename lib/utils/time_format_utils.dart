// lib/utils/time_format_utils.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/localized_duration.dart';
import 'package:matchme/utils/time_of_day_ranges.dart';
import 'package:matchme/providers/user_preferences_provider.dart';

bool effectiveUse24HourFormat(BuildContext context, TimeFormatPreference pref) {
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
    final period = TimeOfDayRanges.periodFromDateTime(
      DateTime(dt.year, dt.month, dt.day, time.hour, time.minute),
    );
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
  final dateStr = DateFormat.yMMMMd(
    l10n.currentLocale.toLanguageTag(),
  ).format(dateTime);
  return '$dateStr · $timeStr';
}

/// Compact timestamp for chat-list rows.
///
/// The full stamp used elsewhere ("21 באוקטובר 2026 · 3:27 אחר הצהריים")
/// is ~200px wide in Hebrew, which starves whatever sits next to it inside
/// a narrow list row. Lists show the time for today and the date for
/// anything older - the convention every chat app follows - so the row
/// keeps one short token that can never crowd out the name.
///
/// The month is always spelled out in full ("21 באוקטובר" / "October 21"):
/// nothing here is abbreviated, an abbreviated month is a different word in
/// every language and reads like a code.
String formatCompactListTimestamp(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  DateTime dateTime,
) {
  final local = dateTime.toLocal();
  final now = DateTime.now();
  final isToday =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (isToday) {
    return formatTimeOfDateTimeWithPrefs(context, ref, l10n, local);
  }
  final locale = l10n.currentLocale.toLanguageTag();
  // Same year -> "21 באוקטובר" / "October 21"; older -> "21 באוקטובר 2026" /
  // "October 21, 2026".
  return local.year == now.year
      ? DateFormat.MMMMd(locale).format(local)
      : DateFormat.yMMMMd(locale).format(local);
}

/// Compute age in years from a birth date, considering month/day so it is accurate
/// around birthdays. An optional [now] parameter can be supplied for testing.
int calculateAgeFromDate(DateTime birthDate, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  int age = reference.year - birthDate.year;
  if (reference.month < birthDate.month ||
      (reference.month == birthDate.month && reference.day < birthDate.day)) {
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
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours <= 0) return '$mm:$ss';
  final hh = hours.toString().padLeft(2, '0');
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

  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours <= 0) return '$mm:$ss';
  final hh = use24 ? hours.toString().padLeft(2, '0') : hours.toString();
  return '$hh:$mm:$ss';
}

String formatDurationWords(LocalizationState l10n, Duration remaining) {
  var d = remaining;
  if (d.isNegative) d = Duration.zero;

  if (d.inDays > 0) {
    final hours = d.inHours.remainder(24);
    return formatDurationParts(
      l10n.getString,
      days: d.inDays,
      hours: hours > 0 ? hours : null,
    );
  }

  if (d.inHours > 0) {
    final minutes = d.inMinutes.remainder(60);
    return formatDurationParts(
      l10n.getString,
      hours: d.inHours,
      minutes: minutes > 0 ? minutes : null,
    );
  }

  if (d.inMinutes > 0) {
    return formatDurationParts(l10n.getString, minutes: d.inMinutes);
  }

  return l10n.getString('durationLessThanOneMinute');
}

