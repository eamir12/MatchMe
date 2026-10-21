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
/// No third-party dependency: iOS goes through a `matchme/badge` channel
/// implemented in AppDelegate; Android launchers derive badges from the tray
/// (handler no-ops); Web uses `navigator.setAppBadge` when available.
class AppBadgeService {
  static const MethodChannel _channel = MethodChannel('matchme/badge');
  static bool _nativeAvailable = true;

  static Future<void> setCount(int n) async {
    final count = n < 0 ? 0 : n;
    if (kIsWeb) {
      await _setWebBadge(count);
      return;
    }
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod('setBadgeCount', {'count': count});
    } on MissingPluginException {
      _nativeAvailable = false;
    } catch (_) {}
  }

  static Future<void> clear() async {
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
