import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-icon badge counter.
///
/// Server is the source of truth for killed/background (APNs `badge` in every
/// push overwrites the icon). This service keeps the foreground best-effort
/// count in sync: increment on each locally shown notification, clear when
/// the user opens the conversation or taps the tray entry.
///
/// No third-party dependency: iOS goes through a `matchme/badge` channel
/// implemented in AppDelegate; Android launchers derive badges from the tray
/// (handler no-ops); Web uses `navigator.setAppBadge` when available.
class AppBadgeService {
  static const MethodChannel _channel = MethodChannel('matchme/badge');
  static int _count = 0;
  static bool _nativeAvailable = true;

  static int get count => _count;

  static Future<void> increment() async {
    _count++;
    await setCount(_count);
  }

  static Future<void> setCount(int n) async {
    _count = n < 0 ? 0 : n;
    if (kIsWeb) {
      await _setWebBadge(_count);
      return;
    }
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod('setBadgeCount', {'count': _count});
    } on MissingPluginException {
      _nativeAvailable = false;
    } catch (_) {}
  }

  static Future<void> clear() async {
    _count = 0;
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
