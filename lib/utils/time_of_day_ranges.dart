// lib/utils/time_of_day_ranges.dart

/// Defines named day periods and helpers to compute them.
/// Ranges are inclusive of start and end minutes as documented below.
library;

import 'package:matchme/services/app_config_service.dart';

enum DayPeriodName { morning, afternoon, evening, night }

class TimeOfDayRanges {
  // Hour ranges use 24-hour clock (0-23)
  static int morningStartHour = 4; // 04:00
  static int morningEndHour = 11; // 11:59

  static int afternoonStartHour = 12; // 12:00
  static int afternoonEndHour = 17; // 17:59

  static int eveningStartHour = 18; // 18:00
  static int eveningEndHour = 21; // 21:59

  // Night is the remainder (22:00 - 03:59)

  static Future<void> loadFromConfig() async {
    try {
      morningStartHour = await appConfigService.getInt(
        'time_ranges.morning_start_hour',
        defaultValue: 4,
      );
      morningEndHour = await appConfigService.getInt(
        'time_ranges.morning_end_hour',
        defaultValue: 11,
      );
      afternoonStartHour = await appConfigService.getInt(
        'time_ranges.afternoon_start_hour',
        defaultValue: 12,
      );
      afternoonEndHour = await appConfigService.getInt(
        'time_ranges.afternoon_end_hour',
        defaultValue: 17,
      );
      eveningStartHour = await appConfigService.getInt(
        'time_ranges.evening_start_hour',
        defaultValue: 18,
      );
      eveningEndHour = await appConfigService.getInt(
        'time_ranges.evening_end_hour',
        defaultValue: 21,
      );
    } catch (e) {
      // Keep defaults
    }
  }

  /// Return the [DayPeriod] for the given [hour] (0-23).
  static DayPeriodName periodFromHour(int hour) {
    final h = hour % 24;
    if (h >= morningStartHour && h <= morningEndHour) {
      return DayPeriodName.morning;
    }
    if (h >= afternoonStartHour && h <= afternoonEndHour) {
      return DayPeriodName.afternoon;
    }
    if (h >= eveningStartHour && h <= eveningEndHour) {
      return DayPeriodName.evening;
    }
    return DayPeriodName.night;
  }

  /// Convenience: get period from a [DateTime]. Uses its local wall-clock hour.
  static DayPeriodName periodFromDateTime(DateTime dt) =>
      periodFromHour(dt.toLocal().hour);
}
