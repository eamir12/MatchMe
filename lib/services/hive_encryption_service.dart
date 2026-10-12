// lib/services/hive_encryption_service.dart
// Provides AES-256 Hive encryption cipher with key stored in SecureStorage.
//
// Design (non-breaking migration):
// - Key: 32 random bytes (Random.secure via CryptoService), base64 in
//   SecureStorage under `hive_encryption_key_v1`, dual-stored (write-through)
//   in the native EncryptedSharedPreferences bridge on Android so bootstrap
//   box opens don't contend on the flutter_secure_storage platform channel.
// - On first run after update: no key exists -> generate + store. Existing
//   unencrypted boxes are migrated: open unencrypted, copy entries to memory,
//   delete from disk, reopen encrypted, restore.
// - If key is lost (secure storage wiped): encrypted boxes cannot open.
//   We detect this, wipe corrupted boxes, and re-create empty encrypted boxes
//   so the app keeps working (data re-syncs from Supabase). No crash.
// - Web: SecureStorage == localStorage, so encryption is obfuscation only.
//   Still applied for defense-in-depth; documented.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/native_secure_store.dart';
import 'package:matchme/services/secure_storage_service.dart';

class HiveEncryptionService {
  HiveEncryptionService._();
  static final HiveEncryptionService instance = HiveEncryptionService._();

  static const String _keyStorageKey = 'hive_encryption_key_v1';

  Uint8List? _cachedKeyBytes;
  HiveAesCipher? _cachedCipher;

  /// Returns the Hive cipher, generating + persisting the key on first use.
  Future<HiveAesCipher> getCipher() async {
    if (_cachedCipher != null) return _cachedCipher!;
    final keyBytes = await _loadOrCreateKey();
    _cachedCipher = HiveAesCipher(keyBytes);
    return _cachedCipher!;
  }

  Future<Uint8List> _loadOrCreateKey() async {
    if (_cachedKeyBytes != null) return _cachedKeyBytes!;

    // Native bridge first: a MethodChannel read that does NOT queue behind
    // flutter_secure_storage. At bootstrap the secure-storage channel is the
    // long pole (cold Android Keystore ~0.9-1.4s) and every other consumer —
    // the session seed's persists, Supabase's own recovery — serializes
    // behind whoever reads it first. Reading the key natively keeps the
    // encrypted boxes (and therefore Home avatars) off that queue entirely.
    // No-op on non-Android (returns null -> secure-storage fallback below).
    try {
      final native = await NativeSecureStore.getString(_keyStorageKey);
      final decoded = _decodeKeyOrNull(native);
      if (decoded != null) {
        _cachedKeyBytes = decoded;
        return decoded;
      }
    } catch (_) {}

    final secure = SecureStorageService.instance;
    try {
      final existing = await secure.read(_keyStorageKey);
      final decoded = _decodeKeyOrNull(existing);
      if (decoded != null) {
        _cachedKeyBytes = decoded;
        // Write through so the next launch reads natively and never touches
        // flutter_secure_storage at all.
        if (existing != null) {
          try {
            await NativeSecureStore.setString(_keyStorageKey, existing);
          } catch (_) {}
        }
        return decoded;
      }
    } catch (_) {}

    final fresh = await CryptoService.instance.generateRandomBytes(32);
    final encoded = base64Encode(fresh);
    try {
      await secure.write(_keyStorageKey, encoded);
    } catch (_) {}
    try {
      await NativeSecureStore.setString(_keyStorageKey, encoded);
    } catch (_) {}
    _cachedKeyBytes = fresh;
    return fresh;
  }

  static Uint8List? _decodeKeyOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = base64Decode(raw);
      if (decoded.length == 32) return Uint8List.fromList(decoded);
    } catch (_) {
      // Corrupt entry -> treated as absent.
    }
    return null;
  }

  /// Open a Hive box with encryption, migrating legacy unencrypted data.
  ///
  /// - Tries encrypted open first.
  /// - On failure (likely legacy plaintext box or lost key), tries plaintext
  ///   open to salvage entries, deletes box from disk, reopens encrypted,
  ///   restores salvaged entries.
  /// - If salvage also fails, deletes from disk and opens fresh encrypted box.
  Future<Box<T>> openEncryptedBox<T>(String name) async {
    final cipher = await getCipher();

    // Fast path: encrypted open works.
    try {
      if (Hive.isBoxOpen(name)) {
        final existing = Hive.box<T>(name);
        return existing;
      }
      return await Hive.openBox<T>(name, encryptionCipher: cipher);
    } catch (e) {
      debugPrint(
        '[HiveCrypto] Encrypted open failed for $name, '
        'attempting migration: $e',
      );
    }

    // Salvage path: try plaintext open.
    Map<dynamic, T> salvaged = {};
    try {
      // Ensure closed before reopening with different cipher.
      try {
        if (Hive.isBoxOpen(name)) await Hive.box(name).close();
      } catch (_) {}
      final plain = await Hive.openBox<T>(name);
      try {
        salvaged = Map<dynamic, T>.from(plain.toMap());
      } catch (_) {}
      try {
        await plain.close();
      } catch (_) {}
    } catch (e) {
      debugPrint('[HiveCrypto] Plain open failed for $name: $e');
    }

    // Delete old files (works for both encrypted/partial/corrupt states).
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {}

    // Reopen encrypted fresh and restore.
    final fresh = await Hive.openBox<T>(name, encryptionCipher: cipher);
    if (salvaged.isNotEmpty) {
      try {
        await fresh.putAll(salvaged);
        debugPrint(
          '[HiveCrypto] Migrated ${salvaged.length} entries for $name',
        );
      } catch (e) {
        debugPrint('[HiveCrypto] Restore failed for $name: $e');
      }
    }
    return fresh;
  }

  /// Open untyped box variant (for profile/options boxes stored as dynamic).
  Future<Box> openEncryptedBoxDynamic(String name) async {
    final cipher = await getCipher();
    try {
      if (Hive.isBoxOpen(name)) {
        return Hive.box(name);
      }
      return await Hive.openBox(name, encryptionCipher: cipher);
    } catch (e) {
      debugPrint(
        '[HiveCrypto] Encrypted open failed for $name, '
        'attempting migration: $e',
      );
    }
    Map<dynamic, dynamic> salvaged = {};
    try {
      try {
        if (Hive.isBoxOpen(name)) await Hive.box(name).close();
      } catch (_) {}
      final plain = await Hive.openBox(name);
      try {
        salvaged = Map<dynamic, dynamic>.from(plain.toMap());
      } catch (_) {}
      try {
        await plain.close();
      } catch (_) {}
    } catch (e) {
      debugPrint('[HiveCrypto] Plain open failed for $name: $e');
    }
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {}
    final fresh = await Hive.openBox(name, encryptionCipher: cipher);
    if (salvaged.isNotEmpty) {
      try {
        await fresh.putAll(salvaged);
      } catch (_) {}
    }
    return fresh;
  }

  /// Wipe cached cipher (call on explicit logout if rotating keys).
  void clearCache() {
    _cachedCipher = null;
    _cachedKeyBytes = null;
  }
}
