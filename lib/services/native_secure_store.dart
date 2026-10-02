// lib/services/native_secure_store.dart
// Dart bridge to the Android native EncryptedSharedPreferences store
// ("matchme_secure_prefs", Keystore-backed AES256) via the
// "matchme/background_service" method channel.
//
// Why it exists: the background service, LocationWorker and BootReceiver run
// in the native process and read credentials via SecurePrefsHelper. Tokens we
// write to Dart-side SecureStorage (flutter_secure_storage) live in a
// different store that native cannot read, and plain SharedPreferences is
// plaintext. This bridge lets Dart write/read the same encrypted store native
// uses, so credentials never have to touch plaintext disk.
//
// Security guard: the plugin only serves keys categorized as sensitive
// (see SecurePrefsHelper.isSensitiveKey), so this cannot be used to read or
// write arbitrary prefs. No-op on non-Android platforms.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeSecureStore {
  NativeSecureStore._();
  static const MethodChannel _channel = MethodChannel(
    'matchme/background_service',
  );

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Persist a sensitive string to the native encrypted store.
  /// A null value removes the key (and any legacy plaintext copy).
  static Future<void> setString(String key, String? value) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('setSecureString', {
        'key': key,
        'value': value,
      });
    } catch (_) {}
  }

  /// Read a sensitive string from the native encrypted store
  /// (encrypted-first, legacy plain fallback handled natively).
  static Future<String?> getString(String key) async {
    if (!isAndroid) return null;
    try {
      final v = await _channel.invokeMethod('getSecureString', {'key': key});
      return v?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Remove sensitive keys from the native encrypted store and any
  /// legacy plaintext copies.
  static Future<void> clearKeys(List<String> keys) async {
    if (!isAndroid || keys.isEmpty) return;
    try {
      await _channel.invokeMethod('clearSecureKeys', {'keys': keys});
    } catch (_) {}
  }
}
