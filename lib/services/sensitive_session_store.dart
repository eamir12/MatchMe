// lib/services/sensitive_session_store.dart
// Hardened store for session secrets that were previously in plaintext
// SharedPreferences:
//
// - `oauth_original_session_json` / `oauth_original_user_id`: NOT needed by
//   native background service -> moved to SecureStorage ONLY. Plain copies are
//   migrated once then deleted. Safe, non-breaking.
// - `flutter.user_token` / `flutter.refresh_token`: REQUIRED by native
//   MatchMeBackgroundService / LocationWorker / BootReceiver. We now write
//   them to BOTH Dart SecureStorage and the native EncryptedSharedPreferences
//   store via [NativeSecureStore] (matchme/background_service bridge), so no
//   plaintext copy exists at rest. Legacy plain copies from older installs are
//   still READ as a migration fallback and actively removed on write.
// - `flutter.location_share_session_key` (raw AES key): same encrypted
//   dual-store; primary is SecureStorage. Never log the value.
//
// All methods are best-effort and never throw (to avoid breaking bootstrap).

import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/native_secure_store.dart';
import 'package:matchme/services/secure_storage_service.dart';

class SensitiveSessionStore {
  SensitiveSessionStore._();
  static final SensitiveSessionStore instance = SensitiveSessionStore._();

  static const String _kOauthSessionJson = 'oauth_original_session_json';
  static const String _kOauthUserId = 'oauth_original_user_id';
  static const String _kUserToken = 'flutter.user_token';
  static const String _kRefreshToken = 'flutter.refresh_token';
  static const String _kUserId = 'flutter.user_id';
  static const String _kLocationShareKey = 'flutter.location_share_session_key';
  static const String _kLocationShareMatchId =
      'flutter.location_share_match_id';
  static const String _kLocationShareOtherId =
      'flutter.location_share_other_user_id';

  final SecureStorageService _secure = SecureStorageService.instance;

  // --- OAuth temp session (SecureStorage only) ---

  Future<void> writeOAuthSession({
    required String sessionJson,
    required String userId,
  }) async {
    await _secure.write(_kOauthSessionJson, sessionJson);
    await _secure.write(_kOauthUserId, userId);
    // One-time migration: delete legacy plain copies if present.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_kOauthSessionJson)) {
        await prefs.remove(_kOauthSessionJson);
      }
      if (prefs.containsKey(_kOauthUserId)) {
        await prefs.remove(_kOauthUserId);
      }
    } catch (_) {}
  }

  Future<String?> readOAuthSessionJson() async {
    // Prefer secure; fallback to legacy plain once for upgrades.
    try {
      final v = await _secure.read(_kOauthSessionJson);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_kOauthSessionJson);
      if (legacy != null && legacy.isNotEmpty) {
        // Migrate forward.
        try {
          await _secure.write(_kOauthSessionJson, legacy);
          await prefs.remove(_kOauthSessionJson);
        } catch (_) {}
        return legacy;
      }
    } catch (_) {}
    return null;
  }

  Future<String?> readOAuthUserId() async {
    try {
      final v = await _secure.read(_kOauthUserId);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_kOauthUserId);
      if (legacy != null && legacy.isNotEmpty) {
        try {
          await _secure.write(_kOauthUserId, legacy);
          await prefs.remove(_kOauthUserId);
        } catch (_) {}
        return legacy;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> hasOAuthSession() async {
    final j = await readOAuthSessionJson();
    final u = await readOAuthUserId();
    return j != null && j.isNotEmpty && u != null && u.isNotEmpty;
  }

  Future<void> clearOAuthSession() async {
    await _secure.delete(_kOauthSessionJson);
    await _secure.delete(_kOauthUserId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kOauthSessionJson);
      await prefs.remove(_kOauthUserId);
    } catch (_) {}
  }

  // --- Auth tokens (SecureStorage + native encrypted bridge) ---

  /// Persist tokens to SecureStorage (Dart) AND the native encrypted store
  /// (Android) so the background service never reads plaintext. Legacy plain
  /// copies are actively removed. Never logs values.
  Future<void> writeAuthTokens({
    required String userId,
    required String accessToken,
    String? refreshToken,
  }) async {
    if (userId.isNotEmpty) {
      await _secure.write(_kUserId, userId);
      await NativeSecureStore.setString(_kUserId, userId);
    }
    if (accessToken.isNotEmpty) {
      await _secure.write(_kUserToken, accessToken);
      await NativeSecureStore.setString(_kUserToken, accessToken);
    }
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _secure.write(_kRefreshToken, refreshToken);
      await NativeSecureStore.setString(_kRefreshToken, refreshToken);
    }
    // Migration cleanup: legacy plaintext copies of these secrets should not
    // linger (native putString also clears them, this covers non-Android).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUserId);
      await prefs.remove(_kUserToken);
      await prefs.remove(_kRefreshToken);
    } catch (_) {}
  }

  Future<String> readRefreshToken() async {
    try {
      final v = await _secure.read(_kRefreshToken);
      if (v != null && v.isNotEmpty) return v.trim();
    } catch (_) {}
    // Native encrypted store fallback (Android background-refresh rotation).
    try {
      final v = await NativeSecureStore.getString(_kRefreshToken);
      if (v != null && v.isNotEmpty) return v.trim();
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kRefreshToken)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clearAuthTokens() async {
    await _secure.delete(_kUserId);
    await _secure.delete(_kUserToken);
    await _secure.delete(_kRefreshToken);
    await NativeSecureStore.clearKeys(const [
      _kUserId,
      _kUserToken,
      _kRefreshToken,
    ]);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUserId);
      await prefs.remove(_kUserToken);
      await prefs.remove(_kRefreshToken);
    } catch (_) {}
  }

  // --- Location share session state (SecureStorage + native encrypted) ---

  Future<void> writeLocationShareKey(String base64Key) async {
    if (base64Key.isEmpty) return;
    await _secure.write(_kLocationShareKey, base64Key);
    // Native service resumes share from its encrypted store after reboot.
    await NativeSecureStore.setString(_kLocationShareKey, base64Key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLocationShareKey);
    } catch (_) {}
  }

  /// Persist location-share identifiers into the native encrypted store
  /// (the Dart SDK no longer writes these to plaintext prefs).
  Future<void> writeLocationShareIds({
    required String matchId,
    required String otherUserId,
  }) async {
    await NativeSecureStore.setString(_kLocationShareMatchId, matchId);
    await NativeSecureStore.setString(_kLocationShareOtherId, otherUserId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLocationShareMatchId);
      await prefs.remove(_kLocationShareOtherId);
    } catch (_) {}
  }

  Future<String?> readLocationShareKey() async {
    try {
      final v = await _secure.read(_kLocationShareKey);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    try {
      final v = await NativeSecureStore.getString(_kLocationShareKey);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kLocationShareKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearLocationShareKey() async {
    await _secure.delete(_kLocationShareKey);
    await NativeSecureStore.clearKeys(const [
      _kLocationShareKey,
      _kLocationShareMatchId,
      _kLocationShareOtherId,
    ]);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLocationShareKey);
      await prefs.remove(_kLocationShareMatchId);
      await prefs.remove(_kLocationShareOtherId);
      await prefs.remove('flutter.location_share_interval');
      await prefs.remove('flutter.location_share_expires_at');
    } catch (_) {}
  }
}
