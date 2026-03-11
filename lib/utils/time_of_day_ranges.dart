// lib/utils/time_of_day_ranges.dart

/// Defines named day periods and helpers to compute them.
/// Ranges are inclusive of start and end minutes as documented below.
library;

enum DayPeriodName { morning, afternoon, evening, night }

class TimeOfDayRanges {
  // Hour ranges use 24-hour clock (0-23)
  static const int morningStartHour = 4; // 04:00
  static const int morningEndHour = 11; // 11:59

  static const int afternoonStartHour = 12; // 12:00
  static const int afternoonEndHour = 17; // 17:59

  static const int eveningStartHour = 18; // 18:00
  static const int eveningEndHour = 21; // 21:59

  // Night is the remainder (22:00 - 03:59)

  /// Return the [DayPeriod] for the given [hour] (0-23).
  static DayPeriodName periodFromHour(int hour) {
    final h = hour % 24;
    if (h >= morningStartHour && h <= morningEndHour) return DayPeriodName.morning;
    if (h >= afternoonStartHour && h <= afternoonEndHour) return DayPeriodName.afternoon;
    if (h >= eveningStartHour && h <= eveningEndHour) return DayPeriodName.evening;
    return DayPeriodName.night;
  }

  /// Convenience: get period from a [DateTime]. Uses its local wall-clock hour.
  static DayPeriodName periodFromDateTime(DateTime dt) => periodFromHour(dt.toLocal().hour);
}
