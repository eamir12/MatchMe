import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// The Badging API needs `package:web`, which cannot compile on the other
// targets; see app_badge_web.dart / app_badge_web_stub.dart.
import 'app_badge_web_stub.dart'
    if (dart.library.js_interop) 'app_badge_web.dart';

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
///    silent notification that is the *summary* of the conversation group
///    (the launcher reads `Notification.setNumber` off it) *and*, best
///    effort, through the launcher's own badge API for the launchers that
///    ignore the notification number (Samsung, Huawei, Sony, OPPO, Vivo,
///    HTC, ...). See MatchMeBadgeController and MatchMeOemBadge. The summary
///    only exists while a conversation card is in the tray - posting it
///    without children would show it as a standalone "MatchMe / N unread"
///    card - and it is removed again once the last card is gone. Stock
///    Pixel/AOSP renders a dot, never a number - that is a launcher
///    limitation, not something the app can change.
///
/// The carrier is the only notification in the app allowed to carry a number:
/// numeric launchers sum `setNumber` across every active notification, so a
/// message card that repeated the count would show twice the unread total.
///
/// Web uses the Badging API (`navigator.setAppBadge`) through a conditional
/// import, so this shared file never touches `package:web` directly.
class AppBadgeService {
  static const MethodChannel _channel = MethodChannel('matchme/badge');
  static bool _nativeAvailable = true;

  /// Last count handed to the platform.
  static int _currentCount = 0;

  /// The count most recently published to the platform.
  static int get currentCount => _currentCount;

  /// [body] is optional localized text shown with the badge carrier
  /// (Android only). It never affects the number itself.
  static Future<void> setCount(int n, {String? body}) async {
    final count = n < 0 ? 0 : n;
    _currentCount = count;
    if (kIsWeb) {
      await setWebAppBadge(count);
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
      await clearWebAppBadge();
      return;
    }
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod('clearBadge');
    } on MissingPluginException {
      _nativeAvailable = false;
    } catch (_) {}
  }
}
