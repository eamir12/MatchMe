// Non-web stub for the Badging API implementation.
//
// Compiled everywhere except web, where app_badge_web.dart takes over. The
// native platforms publish the badge through the `matchme/badge` channel
// instead, so these must never be reached — AppBadgeService only calls them
// from its `kIsWeb` branch.
Future<void> setWebAppBadge(int count) async {}

Future<void> clearWebAppBadge() async {}
