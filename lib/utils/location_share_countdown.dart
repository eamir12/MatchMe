/// Builds the localized live-countdown suffix used by location-share
/// notifications (e.g. " - for another 1 hours, 23 minutes and 45 seconds").
///
/// Returns an empty string when [expiresAt] is null or already passed.
/// The result changes every second while time remains, so callers that want
/// a live counter should re-invoke this once per second.
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

  if (hours > 0) {
    return ' - ${getString('locationShareCountdownHoursSeconds', params: {'hours': hours.toString(), 'minutes': minutes.toString(), 'seconds': seconds.toString()})}';
  }
  return ' - ${getString('locationShareCountdownMinutes', params: {'minutes': minutes.toString(), 'seconds': seconds.toString()})}';
}
