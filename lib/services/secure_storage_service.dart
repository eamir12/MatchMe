// lib/services/secure_storage_service.dart
// Centralized hardened wrapper around flutter_secure_storage.
//
// Why this exists:
// - Previously the app used `const FlutterSecureStorage()` in 3+ places with
//   default options. Defaults are platform-dependent and unauditable.
// - This service pins explicit options:
//   Android: v11 Keystore ciphers (RSA-OAEP key wrap + AES-GCM), no options
//   needed; v9 -> v10 -> v11 migration history in _buildStorage.
//   iOS/macOS: Keychain first_unlock_this_device_only (no iCloud sync, no
//   backup to other devices).
// - Web/Linux/Windows fallback is NOT secure (localStorage / plain file).
//   Callers must treat it as obfuscation only; see `isSecurePlatform`.
//
// Non-breaking: same underlying storage as before on mobile, just explicit.

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  static FlutterSecureStorage _buildStorage() {
    // flutter_secure_storage v11 API. v9 stored Android data in
    // EncryptedSharedPreferences (Jetpack Security); v10 replaced that with
    // custom Keystore ciphers (RSA-OAEP key wrap + AES-GCM) and migrated all
    // v9 data (confirmed on device). v11 then removed the deprecated
    // `encryptedSharedPreferences` parameter and the migration path itself,
    // so no AndroidOptions are needed (defaults are the v10 ciphers).
    // iOS/macOS are pinned below.
    return const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      mOptions: MacOsOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
  }

  final FlutterSecureStorage _storage = _buildStorage();

  /// True on platforms where secure storage is hardware-backed.
  bool get isSecurePlatform {
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) return true;
    } catch (_) {
      return false;
    }
    // Windows/Linux: file-based, not hardware-backed.
    return false;
  }

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('[SecureStorage] read failed for $key: $e');
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('[SecureStorage] write failed for $key: $e');
    }
  }

  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }

  Future<void> deleteAll() async {
    try {
      await _storage.deleteAll();
    } catch (_) {}
  }

  /// Delete only keys with the given prefixes (safe partial wipe on logout).
  Future<void> deleteByPrefixes(List<String> prefixes) async {
    try {
      final all = await _storage.readAll();
      for (final entry in all.entries) {
        for (final prefix in prefixes) {
          if (entry.key.startsWith(prefix)) {
            try {
              await _storage.delete(key: entry.key);
            } catch (_) {}
            break;
          }
        }
      }
    } catch (_) {}
  }
}
