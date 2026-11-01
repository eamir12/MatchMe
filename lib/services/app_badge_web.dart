// Web app-icon badge via the Badging API.
//
// Only compiled on web (conditional import from app_badge_service.dart), which
// is why `package:web` is not touched from the shared service file.
//
// `setAppBadge` is the web equivalent of the iOS icon badge: the number shows
// on the installed PWA's icon (taskbar/dock/home screen) and, unlike the
// mobile surfaces, it is a real numeric count.
//
// Both calls reject with a `NotSupportedError` outside an installed context
// (a plain browser tab) — that is the normal case, not a failure worth
// surfacing, so errors are swallowed here rather than at every call site.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Sets the badge to [count]; a count of 0 clears it.
Future<void> setWebAppBadge(int count) async {
  try {
    if (count <= 0) {
      await web.window.navigator.clearAppBadge().toDart;
      return;
    }
    await web.window.navigator.setAppBadge(count).toDart;
  } catch (_) {}
}

/// Removes the badge.
Future<void> clearWebAppBadge() async {
  try {
    await web.window.navigator.clearAppBadge().toDart;
  } catch (_) {}
}
