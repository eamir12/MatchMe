import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows WNS push channel registration (MSIX).
///
/// Requests the channel URI from the native runner (`matchme/windows_push`)
/// and caches it so [SessionService] attaches `metadata.wns_channel_uri` on
/// every session upsert. WNS URIs expire ~every 30 days, so the server keeps
/// a freshness timestamp and prunes stale ones; the app re-requests a fresh
/// channel on each start (cheap call, no user prompt).
class WindowsPushChannelService {
  static const MethodChannel _channel = MethodChannel('matchme/windows_push');
  static const String _prefsKey = 'wns_channel_uri';

  static bool get _isWindowsTarget => !kIsWeb && Platform.isWindows;

  // Package identity is missing on unpackaged dev builds; after the first
  // NOT_AVAILABLE failure, short-circuit later calls in this process.
  static bool _skipNativeAfterFailure = false;

  /// Requests a fresh channel URI from WNS. Returns null when the platform
  /// is not Windows or package identity is missing (unpackaged dev build).
  static Future<String?> ensureChannel({int timeoutMs = 8000}) async {
    if (!_isWindowsTarget || _skipNativeAfterFailure) return null;
    try {
      final result = await _channel.invokeMethod<String>(
        'createPushChannel',
        {'timeoutMs': timeoutMs},
      );
      final uri = result?.trim() ?? '';
      if (uri.isEmpty || !uri.startsWith('https://')) return null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, uri);
      _skipNativeAfterFailure = false;
      return uri;
    } on PlatformException catch (e) {
      // NOT_AVAILABLE on unpackaged builds is expected; treat as terminal
      // for this process so later calls don't wait on the same failure.
      _skipNativeAfterFailure = e.code == 'NOT_AVAILABLE';
      debugPrint(
        '[WindowsPushChannel] ensureChannel failed (${e.code}): ${e.message}',
      );
      return null;
    } catch (e) {
      debugPrint('[WindowsPushChannel] ensureChannel error: $e');
      return null;
    }
  }

  /// Cached channel URI (may be stale; server prunes with its timestamp).
  static Future<String?> getCachedChannel() async {
    if (!_isWindowsTarget) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefsKey)?.trim();
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearLocalChannel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  /// The matchme:// URI the process was launched with (toast activation on a
  /// suspended app), or null when started normally.
  static Future<String?> getInitialLaunchPayload() async {
    if (!_isWindowsTarget) return null;
    try {
      final result =
          await _channel.invokeMethod<String>('getInitialLaunchPayload');
      final uri = result?.trim() ?? '';
      return uri.startsWith('matchme://') ? uri : null;
    } on PlatformException catch (_) {
      return null;
    } catch (_) {
      return null;
    }
  }
}
