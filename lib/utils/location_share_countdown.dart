// lib/utils/location_share_countdown.dart
import 'package:matchme/utils/localized_duration.dart';

/// Builds the localized live-countdown suffix used by location-share
/// notifications (e.g. " - for another 1 hour, 23 minutes and 45 seconds").
/// Returns an empty string when [expiresAt] is null or already passed.
/// The result changes every second while time remains, so callers that want
/// a live counter should re-invoke this once per second.
///
/// Every unit is translated on its own so it can pick the right plural
/// form: "1 hour" must not read as "1 hours".
String buildLocationShareCountdownSuffix({
  required DateTime? expiresAt,
  required DateTime now,
  required String Function(String key, {Map<String, String>? params}) getString,
}) {
  if (expiresAt == null) return '';

  final expires = expiresAt.toUtc();
  final remaining = expires.difference(now.toUtc());
  if (remaining.isNegative || remaining.inSeconds <= 0) return '';

  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;
  final seconds = remaining.inSeconds % 60;

  final duration = formatDurationParts(
    getString,
    hours: hours > 0 ? hours : null,
    minutes: minutes,
    seconds: seconds,
  );
  if (duration.isEmpty) return '';

  return ' - ${getString('locationShareCountdownRemaining', params: {'duration': duration})}';
}
