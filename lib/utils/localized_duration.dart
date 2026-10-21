// lib/utils/localized_duration.dart
//
// Building a duration string that names several units ("1 hour, 5 minutes
// and 3 seconds") cannot be done with a single translation template: every
// unit carries its own quantity and therefore its own plural form. The parts
// are translated one by one and joined with localized connectors, so
// "1 hour" never reads as "1 hours" and every language keeps its own word
// order (Hebrew's "ו-" prefix, for instance).

/// The translation lookup the duration helpers need.
///
/// `LocalizationState.getString` satisfies it, and so does the plain callback
/// the notification builders take.
typedef DurationTranslationLookup =
    String Function(String key, {Map<String, String>? params});

/// Joins already translated duration parts with the localized connectors.
///
/// The connectors are translations too, so the word order of every language
/// is kept.
String joinDurationParts(
  DurationTranslationLookup getString,
  List<String> parts,
) {
  if (parts.isEmpty) return '';
  if (parts.length == 1) return parts.first;
  if (parts.length == 2) {
    return getString(
      'durationListAnd',
      params: {'first': parts[0], 'second': parts[1]},
    );
  }
  return getString(
    'durationListCommaAnd',
    params: {
      'first': parts[0],
      'second': parts[1],
      'third': parts[2],
    },
  );
}

/// Translates the given units and joins them into one duration string.
///
/// A unit left out (`null`) is not rendered. Each unit picks its own plural
/// form, so "1 hour, 5 minutes and 3 seconds" never reads as
/// "1 hours, 5 minutes and 3 seconds".
String formatDurationParts(
  DurationTranslationLookup getString, {
  int? days,
  int? hours,
  int? minutes,
  int? seconds,
}) {
  final parts = <String>[];
  if (days != null) {
    parts.add(getString('durationDays', params: {'count': '$days'}));
  }
  if (hours != null) {
    parts.add(getString('durationHours', params: {'count': '$hours'}));
  }
  if (minutes != null) {
    parts.add(getString('durationMinutes', params: {'count': '$minutes'}));
  }
  if (seconds != null) {
    parts.add(getString('durationSeconds', params: {'count': '$seconds'}));
  }
  return joinDurationParts(getString, parts);
}
