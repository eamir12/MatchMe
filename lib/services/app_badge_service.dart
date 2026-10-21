import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-icon badge writer.
///
/// `iconBadgeCountProvider` owns the foreground count (it mirrors the
/// notification inbox) and the server's APNs `badge` owns the
/// killed/background count. Locally shown notification cards must not bump
/// this: they represent the same event that already added an inbox row, so a
/// local increment would double count it.
///
/// No third-party dependency. The `matchme/badge` channel is implemented
/// natively on both platforms:
///  - iOS sets `UIApplication.applicationIconBadgeNumber` directly.
///  - Android has no global badge API. The count is published through a
///    silent badge-carrying notification (the launcher reads
///    `Notification.setNumber`) *and*, best effort, through the launcher's
///    own badge API for the launchers that ignore the notification number
///    (Samsung, Huawei, Sony, OPPO, Vivo, HTC, ...). Both always carry the
///    same value, so they cannot disagree; see MatchMeBadgeController and
///    MatchMeOemBadge. Stock Pixel/AOSP renders a dot, never a number - that
///    is a launcher limitation, not something the app can change.
///
/// Web is intentionally a no-op: the tray plus the service worker's badge
/// icon is the reliable surface, and touching `package:web` from this shared
/// file would break non-web compiles.
class AppBadgeService {
  static const MethodChannel _channel = MethodChannel('matchme/badge');
  static bool _nativeAvailable = true;

  /// Last count handed to the platform.
  ///
  /// Local notification cards publish the same number on their own
  /// notification (`AndroidNotificationDetails.number`) so a launcher that
  /// reads the number off the newest notification sees the same value the
  /// badge carrier carries.
  static int _currentCount = 0;

  /// The count most recently published to the platform.
  static int get currentCount => _currentCount;

  /// [body] is optional localized text shown with the badge carrier
  /// (Android only). It never affects the number itself.
  static Future<void> setCount(int n, {String? body}) async {
    final count = n < 0 ? 0 : n;
    _currentCount = count;
    if (kIsWeb) {
      await _setWebBadge(count);
      return;
    }
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod('setBadgeCount', {
        'count': count,
        if (body != null && body.isNotEmpty) 'body': body,
      });
    } on MissingPluginException {
      _nativeAvailable = false;
    } catch (_) {}
  }

  static Future<void> clear() async {
    _currentCount = 0;
    if (kIsWeb) {
      await _clearWebBadge();
      return;
    }
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod('clearBadge');
    } on MissingPluginException {
      _nativeAvailable = false;
    } catch (_) {}
  }

  // Web Badging API (navigator.setAppBadge) is intentionally a no-op here:
  // the tray + SW `badge` icon is the reliable surface and touching
  // package:web from this shared file would break non-web compiles.
  // Revisit with a web-only extension if launcher badges are required.
  static Future<void> _setWebBadge(int n) async {}
  static Future<void> _clearWebBadge() async {}
}
