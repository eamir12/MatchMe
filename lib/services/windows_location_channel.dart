import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

/// Routes one-shot location calls through a custom Windows platform channel
/// ([matchme/windows_location]) instead of the stock geolocator_windows plugin.
///
/// Why: the stock plugin holds a single WinRT `Geolocator` as a never-released
/// member. Every call — `checkPermission`, `requestPermission`,
/// `getLastKnownPosition`, `getCurrentPosition` — triggers
/// `RequestAccessAsync()` / `GetGeopositionAsync()` on that shared object.
/// `GetGeopositionAsync()` has no native timeout, so on a desktop without GPS
/// it hangs forever and the Windows location indicator latches on for the
/// entire process lifetime.
///
/// Our channel creates a **local** `Geolocator` per call and cancels the
/// WinRT operation via `ThreadPoolTimer` after a hard timeout, so the
/// indicator turns off as soon as the call completes or times out.
///
/// On non-Windows platforms (or if the channel is unavailable) every method
/// falls back to the corresponding `Geolocator` call.
class WindowsLocationChannel {
  static const MethodChannel _channel =
      MethodChannel('matchme/windows_location');

  static bool _available =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Whether the custom Windows channel is usable on this platform.
  static bool get isAvailable => _available;

  // ── internal helpers ────────────────────────────────────────────────

  static void _log(String msg) {
    debugPrint('[WindowsLocationChannel] $msg');
  }

  static Future<Map<String, dynamic>?> _invokePosition(
    String method, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_available) return null;
    _log('$method → native (timeout=${timeout.inMilliseconds}ms)');
    try {
      final result = await _channel.invokeMethod(method, {
        'timeoutMs': timeout.inMilliseconds,
      });
      _log('$method ← native result=${result != null ? 'position' : 'null'}');
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      _log('$method ← PlatformException(${e.code}): ${e.message}');
      return null;
    } on MissingPluginException {
      _log('$method ← MissingPluginException, disabling channel');
      _available = false;
      return null;
    }
  }

  static Future<int?> _invokeInt(String method) async {
    if (!_available) return null;
    _log('$method → native');
    try {
      final value = await _channel.invokeMethod<int>(method);
      _log('$method ← native value=$value');
      return value;
    } on PlatformException catch (e) {
      _log('$method ← PlatformException(${e.code}): ${e.message}');
      return null;
    } on MissingPluginException {
      _log('$method ← MissingPluginException, disabling channel');
      _available = false;
      return null;
    }
  }

  static Future<bool?> _invokeBool(String method) async {
    if (!_available) return null;
    _log('$method → native');
    try {
      final value = await _channel.invokeMethod<bool>(method);
      _log('$method ← native value=$value');
      return value;
    } on PlatformException catch (e) {
      _log('$method ← PlatformException(${e.code}): ${e.message}');
      return null;
    } on MissingPluginException {
      _log('$method ← MissingPluginException, disabling channel');
      _available = false;
      return null;
    }
  }

  static Position? _toPosition(Map<String, dynamic>? map) {
    if (map == null) return null;
    final timestampMs = ((map['timestamp'] as num?) ?? 0).toInt() * 1000;
    return Position(
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      accuracy: (map['accuracy'] as num?)?.toDouble() ?? double.infinity,
      altitude: (map['altitude'] as num?)?.toDouble() ?? 0.0,
      altitudeAccuracy:
          (map['altitude_accuracy'] as num?)?.toDouble() ?? 0.0,
      heading: (map['heading'] as num?)?.toDouble() ?? 0.0,
      headingAccuracy: 0.0,
      speed: (map['speed'] as num?)?.toDouble() ?? 0.0,
      speedAccuracy: 0.0,
    );
  }

  static LocationPermission _toPermission(int value) {
    switch (value) {
      case 2:
        return LocationPermission.whileInUse;
      case 3:
        return LocationPermission.always;
      case 1:
        return LocationPermission.deniedForever;
      default:
        return LocationPermission.denied;
    }
  }

  // ── public API (drop-in Geolocator replacements) ────────────────────

  // On Windows the custom channel is the ONLY location implementation —
  // geolocator_windows is no longer registered (its long-lived Geolocator
  // member latched the indicator).  If the channel is unavailable we
  // return safe defaults instead of falling back to Geolocator, which
  // would throw MissingPluginException on Windows.
  //
  // On non-Windows platforms every method falls back to the
  // corresponding Geolocator call as before.

  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Drop-in replacement for `Geolocator.checkPermission()`.
  /// On Windows the native call uses a registry read — it never calls
  /// RequestAccessAsync, so the indicator cannot turn on from a
  /// permission check.
  static Future<LocationPermission> checkPermission() async {
    if (_available) {
      final value = await _invokeInt('checkPermission');
      if (value != null) return _toPermission(value);
      if (!_available) {
        _log('checkPermission: channel unavailable');
      }
    }
    if (_isWindows) {
      _log('checkPermission: Windows, channel unavailable → denied');
      return LocationPermission.denied;
    }
    _log('checkPermission: using geolocator fallback');
    return Geolocator.checkPermission();
  }

  /// Drop-in replacement for `Geolocator.requestPermission()`.
  static Future<LocationPermission> requestPermission() async {
    if (_available) {
      final value = await _invokeInt('requestPermission');
      if (value != null) return _toPermission(value);
      if (!_available) {
        _log('requestPermission: channel unavailable');
      }
    }
    if (_isWindows) {
      _log('requestPermission: Windows, channel unavailable → denied');
      return LocationPermission.denied;
    }
    _log('requestPermission: using geolocator fallback');
    return Geolocator.requestPermission();
  }

  /// Drop-in replacement for `Geolocator.isLocationServiceEnabled()`.
  static Future<bool> isLocationServiceEnabled() async {
    if (_available) {
      final value = await _invokeBool('isLocationServiceEnabled');
      if (value != null) return value;
      if (!_available) {
        _log('isLocationServiceEnabled: channel unavailable');
      }
    }
    if (_isWindows) {
      _log('isLocationServiceEnabled: Windows, channel unavailable → true');
      return true;
    }
    _log('isLocationServiceEnabled: using geolocator fallback');
    return Geolocator.isLocationServiceEnabled();
  }

  /// Drop-in replacement for `Geolocator.getLastKnownPosition()`.
  /// Uses a registry permission check + native timeout so the indicator
  /// cannot latch on.
  static Future<Position?> getLastKnownPosition({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_available) {
      final map = await _invokePosition('getLastKnownPosition',
          timeout: timeout);
      final pos = _toPosition(map);
      if (pos != null) return pos;
      if (!_available) {
        _log('getLastKnownPosition: channel unavailable');
      }
    }
    if (_isWindows) {
      _log('getLastKnownPosition: Windows, channel unavailable → null');
      return null;
    }
    try {
      _log('getLastKnownPosition: using geolocator fallback');
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// Drop-in replacement for `Geolocator.getCurrentPosition()`.
  /// Uses a registry permission check + native timeout so the indicator
  /// cannot latch on.
  static Future<Position?> getPosition({
    LocationAccuracy accuracy = LocationAccuracy.best,
    Duration? timeLimit,
  }) async {
    final nativeTimeout = timeLimit ?? const Duration(seconds: 5);

    if (_available) {
      final map =
          await _invokePosition('getCurrentPosition', timeout: nativeTimeout);
      final pos = _toPosition(map);
      if (pos != null) return pos;
      if (!_available) {
        _log('getPosition: channel unavailable');
      }
    }

    if (_isWindows) {
      _log('getPosition: Windows, channel unavailable → null');
      return null;
    }

    try {
      _log('getPosition: using geolocator fallback');
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: timeLimit,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
