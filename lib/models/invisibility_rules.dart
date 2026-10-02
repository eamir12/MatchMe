import 'dart:math';
import 'package:flutter/material.dart';

enum InvisibilityRuleType {
  location,
  dateRange,
  timeRange,
  dayOfWeek,
  dateTimeRange,
  dayTimeRange,
}

class LocationRule {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double
  radiusMeters; // Default 50m, minimum enforced 5m. Web GPS accuracy is typically 50-100m.
  final bool enabled;

  LocationRule({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusMeters = 50.0,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'radiusMeters': radiusMeters,
    'enabled': enabled,
  };

  factory LocationRule.fromJson(Map<String, dynamic> json) => LocationRule(
    id: json['id'],
    name: json['name'],
    latitude: json['latitude'],
    longitude: json['longitude'],
    radiusMeters: json['radiusMeters'] ?? 10.0,
    enabled: json['enabled'] ?? true,
  );

  LocationRule copyWith({
    String? id,
    String? name,
    double? latitude,
    double? longitude,
    double? radiusMeters,
    bool? enabled,
  }) {
    return LocationRule(
      id: id ?? this.id,
      name: name ?? this.name,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      enabled: enabled ?? this.enabled,
    );
  }
}

class DateRangeRule {
  final String id;
  final DateTime startDate;
  final DateTime endDate;
  final bool enabled;

  DateRangeRule({
    required this.id,
    required this.startDate,
    required this.endDate,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'startDate': startDate.toIso8601String(),
    'endDate': endDate.toIso8601String(),
    'enabled': enabled,
  };

  factory DateRangeRule.fromJson(Map<String, dynamic> json) => DateRangeRule(
    id: json['id'],
    startDate: DateTime.parse(json['startDate']),
    endDate: DateTime.parse(json['endDate']),
    enabled: json['enabled'] ?? true,
  );

  DateRangeRule copyWith({
    String? id,
    DateTime? startDate,
    DateTime? endDate,
    bool? enabled,
  }) {
    return DateRangeRule(
      id: id ?? this.id,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      enabled: enabled ?? this.enabled,
    );
  }
}

class TimeRangeRule {
  final String id;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final bool enabled;

  TimeRangeRule({
    required this.id,
    required this.startTime,
    required this.endTime,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'startTime': '${startTime.hour}:${startTime.minute}',
    'endTime': '${endTime.hour}:${endTime.minute}',
    'enabled': enabled,
  };

  factory TimeRangeRule.fromJson(Map<String, dynamic> json) => TimeRangeRule(
    id: json['id'],
    startTime: _parseTimeOfDay(json['startTime']),
    endTime: _parseTimeOfDay(json['endTime']),
    enabled: json['enabled'] ?? true,
  );

  TimeRangeRule copyWith({
    String? id,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    bool? enabled,
  }) {
    return TimeRangeRule(
      id: id ?? this.id,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      enabled: enabled ?? this.enabled,
    );
  }

  static TimeOfDay _parseTimeOfDay(String timeString) {
    final parts = timeString.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }
}

class DayOfWeekRule {
  final String id;
  final List<int> daysOfWeek; // 1 = Monday, 7 = Sunday
  final bool enabled;

  DayOfWeekRule({
    required this.id,
    required this.daysOfWeek,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'daysOfWeek': daysOfWeek,
    'enabled': enabled,
  };

  factory DayOfWeekRule.fromJson(Map<String, dynamic> json) => DayOfWeekRule(
    id: json['id'],
    daysOfWeek: List<int>.from(json['daysOfWeek']),
    enabled: json['enabled'] ?? true,
  );

  DayOfWeekRule copyWith({String? id, List<int>? daysOfWeek, bool? enabled}) {
    return DayOfWeekRule(
      id: id ?? this.id,
      daysOfWeek: daysOfWeek ?? this.daysOfWeek,
      enabled: enabled ?? this.enabled,
    );
  }

  List<String> getDayNames() {
    const dayNames = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return daysOfWeek.map((day) => dayNames[day - 1]).toList();
  }
}

class DateTimeRangeRule {
  final String id;
  final DateTime startDateTime;
  final DateTime endDateTime;
  final bool enabled;

  DateTimeRangeRule({
    required this.id,
    required this.startDateTime,
    required this.endDateTime,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'startDateTime': startDateTime.toIso8601String(),
    'endDateTime': endDateTime.toIso8601String(),
    'enabled': enabled,
  };

  factory DateTimeRangeRule.fromJson(Map<String, dynamic> json) =>
      DateTimeRangeRule(
        id: json['id'],
        startDateTime: DateTime.parse(json['startDateTime']),
        endDateTime: DateTime.parse(json['endDateTime']),
        enabled: json['enabled'] ?? true,
      );

  DateTimeRangeRule copyWith({
    String? id,
    DateTime? startDateTime,
    DateTime? endDateTime,
    bool? enabled,
  }) {
    return DateTimeRangeRule(
      id: id ?? this.id,
      startDateTime: startDateTime ?? this.startDateTime,
      endDateTime: endDateTime ?? this.endDateTime,
      enabled: enabled ?? this.enabled,
    );
  }

  bool isInPast(DateTime now) => endDateTime.isBefore(now);
}

class DayTimeRangeRule {
  final String id;
  final List<int> daysOfWeek; // 1 = Monday, 7 = Sunday
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final bool enabled;

  DayTimeRangeRule({
    required this.id,
    required this.daysOfWeek,
    required this.startTime,
    required this.endTime,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'daysOfWeek': daysOfWeek,
    'startTime': '${startTime.hour}:${startTime.minute}',
    'endTime': '${endTime.hour}:${endTime.minute}',
    'enabled': enabled,
  };

  factory DayTimeRangeRule.fromJson(Map<String, dynamic> json) =>
      DayTimeRangeRule(
        id: json['id'],
        daysOfWeek: List<int>.from(json['daysOfWeek']),
        startTime: _parseTimeOfDay(json['startTime']),
        endTime: _parseTimeOfDay(json['endTime']),
        enabled: json['enabled'] ?? true,
      );

  DayTimeRangeRule copyWith({
    String? id,
    List<int>? daysOfWeek,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    bool? enabled,
  }) {
    return DayTimeRangeRule(
      id: id ?? this.id,
      daysOfWeek: daysOfWeek ?? this.daysOfWeek,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      enabled: enabled ?? this.enabled,
    );
  }

  static TimeOfDay _parseTimeOfDay(String timeString) {
    final parts = timeString.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  List<String> getDayNames() {
    const dayNames = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return daysOfWeek.map((day) => dayNames[day - 1]).toList();
  }
}

class InvisibilityRules {
  final List<LocationRule> locationRules;
  final List<DateRangeRule> dateRangeRules;
  final List<TimeRangeRule> timeRangeRules;
  final List<DayOfWeekRule> dayOfWeekRules;
  final List<DateTimeRangeRule> dateTimeRangeRules;
  final List<DayTimeRangeRule> dayTimeRangeRules;
  final bool isLoaded;

  InvisibilityRules({
    this.locationRules = const [],
    this.dateRangeRules = const [],
    this.timeRangeRules = const [],
    this.dayOfWeekRules = const [],
    this.dateTimeRangeRules = const [],
    this.dayTimeRangeRules = const [],
    this.isLoaded = false,
  });

  Map<String, dynamic> toJson() => {
    'locationRules': locationRules.map((r) => r.toJson()).toList(),
    'dateRangeRules': dateRangeRules.map((r) => r.toJson()).toList(),
    'timeRangeRules': timeRangeRules.map((r) => r.toJson()).toList(),
    'dayOfWeekRules': dayOfWeekRules.map((r) => r.toJson()).toList(),
    'dateTimeRangeRules': dateTimeRangeRules.map((r) => r.toJson()).toList(),
    'dayTimeRangeRules': dayTimeRangeRules.map((r) => r.toJson()).toList(),
    'isLoaded': isLoaded,
  };

  factory InvisibilityRules.fromJson(Map<String, dynamic> json) =>
      InvisibilityRules(
        locationRules:
            (json['locationRules'] as List<dynamic>?)
                ?.map((r) => LocationRule.fromJson(r))
                .toList() ??
            [],
        dateRangeRules:
            (json['dateRangeRules'] as List<dynamic>?)
                ?.map((r) => DateRangeRule.fromJson(r))
                .toList() ??
            [],
        timeRangeRules:
            (json['timeRangeRules'] as List<dynamic>?)
                ?.map((r) => TimeRangeRule.fromJson(r))
                .toList() ??
            [],
        dayOfWeekRules:
            (json['dayOfWeekRules'] as List<dynamic>?)
                ?.map((r) => DayOfWeekRule.fromJson(r))
                .toList() ??
            [],
        dateTimeRangeRules:
            (json['dateTimeRangeRules'] as List<dynamic>?)
                ?.map((r) => DateTimeRangeRule.fromJson(r))
                .toList() ??
            [],
        dayTimeRangeRules:
            (json['dayTimeRangeRules'] as List<dynamic>?)
                ?.map((r) => DayTimeRangeRule.fromJson(r))
                .toList() ??
            [],
        isLoaded: json['isLoaded'] ?? false,
      );

  InvisibilityRules copyWith({
    List<LocationRule>? locationRules,
    List<DateRangeRule>? dateRangeRules,
    List<TimeRangeRule>? timeRangeRules,
    List<DayOfWeekRule>? dayOfWeekRules,
    List<DateTimeRangeRule>? dateTimeRangeRules,
    List<DayTimeRangeRule>? dayTimeRangeRules,
    bool? isLoaded,
  }) {
    return InvisibilityRules(
      locationRules: locationRules ?? this.locationRules,
      dateRangeRules: dateRangeRules ?? this.dateRangeRules,
      timeRangeRules: timeRangeRules ?? this.timeRangeRules,
      dayOfWeekRules: dayOfWeekRules ?? this.dayOfWeekRules,
      dateTimeRangeRules: dateTimeRangeRules ?? this.dateTimeRangeRules,
      dayTimeRangeRules: dayTimeRangeRules ?? this.dayTimeRangeRules,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }

  bool shouldBeInvisible({
    required double? currentLatitude,
    required double? currentLongitude,
    required DateTime currentDateTime,
  }) {
    // Check location rules
    if (currentLatitude != null && currentLongitude != null) {
      for (final rule in locationRules) {
        if (!rule.enabled) continue;
        final distance = _calculateDistance(
          currentLatitude,
          currentLongitude,
          rule.latitude,
          rule.longitude,
        );
        final effectiveRadius = rule.radiusMeters < 5.0
            ? 5.0
            : rule.radiusMeters; // Minimum 5m radius to account for minor location changes
        if (distance <= effectiveRadius) {
          return true;
        }
      }
    }

    // Check date range rules
    for (final rule in dateRangeRules) {
      if (!rule.enabled) continue;
      final currentDate = DateTime(
        currentDateTime.year,
        currentDateTime.month,
        currentDateTime.day,
      );
      final startDate = DateTime(
        rule.startDate.year,
        rule.startDate.month,
        rule.startDate.day,
      );
      final endDate = DateTime(
        rule.endDate.year,
        rule.endDate.month,
        rule.endDate.day,
      );

      if (currentDate.isAfter(startDate.subtract(const Duration(days: 1))) &&
          currentDate.isBefore(endDate.add(const Duration(days: 1)))) {
        return true;
      }
    }

    // Check time range rules
    for (final rule in timeRangeRules) {
      if (!rule.enabled) continue;
      final currentTime = TimeOfDay.fromDateTime(currentDateTime);
      if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
        return true;
      }
    }

    // Check day of week rules
    for (final rule in dayOfWeekRules) {
      if (!rule.enabled) continue;
      if (rule.daysOfWeek.contains(currentDateTime.weekday)) {
        return true;
      }
    }

    // Check date time range rules
    for (final rule in dateTimeRangeRules) {
      if (!rule.enabled) continue;
      if (currentDateTime.isAfter(rule.startDateTime) &&
          currentDateTime.isBefore(rule.endDateTime)) {
        return true;
      }
    }

    // Check day time range rules
    for (final rule in dayTimeRangeRules) {
      if (!rule.enabled) continue;
      if (rule.daysOfWeek.contains(currentDateTime.weekday)) {
        final currentTime = TimeOfDay.fromDateTime(currentDateTime);
        if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
          return true;
        }
      }
    }

    return false;
  }

  double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371000; // meters
    final double dLat = _degreesToRadians(lat2 - lat1);
    final double dLon = _degreesToRadians(lon2 - lon1);

    final double a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    return calculateDistance(lat1, lon1, lat2, lon2);
  }

  double _degreesToRadians(double degrees) =>
      degrees * (3.141592653589793 / 180);

  bool _isTimeInRange(TimeOfDay current, TimeOfDay start, TimeOfDay end) {
    final currentMinutes = current.hour * 60 + current.minute;
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;

    if (startMinutes <= endMinutes) {
      // Same day range
      return currentMinutes >= startMinutes && currentMinutes <= endMinutes;
    } else {
      // Overnight range
      return currentMinutes >= startMinutes || currentMinutes <= endMinutes;
    }
  }
}
