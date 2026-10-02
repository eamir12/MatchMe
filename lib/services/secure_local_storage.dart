// lib/services/secure_local_storage.dart
// [LocalStorage] implementation for supabase_flutter that persists the
// session (access + refresh tokens) through [SecureStorageService]
// (Keychain / EncryptedSharedPreferences) instead of plaintext
// SharedPreferences / browser localStorage.
//
// This replaces the SDK's default `SharedPreferencesLocalStorage`, which
// wrote the full session JSON (including tokens) to plaintext on disk.
//
// Platform note: on web/Windows/Linux secure storage degrades to localStorage
// / plain files (documented in secure_storage_service.dart) — identical to
// the SDK default there, so this is a strict improvement with no regression.

import 'package:flutter/widgets.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persists the Supabase session through the app's hardened secure store.
class SecureLocalStorage extends LocalStorage {
  SecureLocalStorage({required String persistSessionKey})
    : _persistSessionKey = persistSessionKey;

  /// Matches the SDK's own key derivation (`sb-<host>-auth-token`) so an
  /// upgrade from the plaintext store transparently recovers the session.
  static String buildSessionKey(String supabaseUrl) {
    final host = Uri.parse(supabaseUrl).host.split('.').first;
    return 'sb-$host-auth-token';
  }

  final String _persistSessionKey;

  @override
  Future<void> initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
  }

  @override
  Future<bool> hasAccessToken() async {
    final token = await SecureStorageService.instance.read(_persistSessionKey);
    return token != null && token.isNotEmpty;
  }

  @override
  Future<String?> accessToken() async {
    return SecureStorageService.instance.read(_persistSessionKey);
  }

  @override
  Future<void> removePersistedSession() async {
    await SecureStorageService.instance.delete(_persistSessionKey);
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    await SecureStorageService.instance.write(
      _persistSessionKey,
      persistSessionString,
    );
  }
}
