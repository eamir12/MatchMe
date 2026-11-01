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

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/native_secure_store.dart';
import 'package:matchme/services/runtime_supabase_config.dart';
import 'package:matchme/services/secure_local_storage.dart';
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

  /// Every refresh-token copy this device knows about, freshest first.
  ///
  /// GoTrue refresh tokens are single-use and rotate on every refresh, so
  /// only one copy is current at any moment. Order matters when these are
  /// used as fallbacks:
  ///
  /// 1. Native encrypted store — on Android the background service refreshes
  ///    out of process and rotates the token here only. On other platforms
  ///    this is empty.
  /// 2. The Supabase SDK's own persisted session (`sb-<ref>-auth-token`) on
  ///    platforms without the native bridge. supabase_flutter rewrites it on
  ///    every successful refresh, including its own auto-refresh ticks, so it
  ///    tracks rotations nobody told MatchMe about.
  /// 3. `flutter.refresh_token` (Dart SecureStorage). Kept in sync by the
  ///    auth listener; before that it was written only by a few explicit
  ///    paths, which is how a STALE copy ended up being spent on desktop.
  /// 4. Legacy plaintext SharedPreferences (upgrade fallback).
  Future<List<String>> readRefreshTokenCandidates() async {
    final out = <String>[];
    void add(String? v) {
      final t = v?.trim() ?? '';
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    // Native encrypted store first: the Android background service rotates here.
    try {
      add(await NativeSecureStore.getString(_kRefreshToken));
    } catch (_) {}
    // Android keeps its authoritative copy in the native store above; skip the
    // extra Keystore read. Elsewhere the SDK's copy tracks rotations nothing
    // else records.
    if (!NativeSecureStore.isAndroid) {
      try {
        add(await readSdkPersistedRefreshToken());
      } catch (_) {}
    }
    try {
      add(await _secure.read(_kRefreshToken));
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      add(prefs.getString(_kRefreshToken));
    } catch (_) {}
    return out;
  }

  /// The Supabase SDK's own persisted session JSON (`sb-<ref>-auth-token`).
  ///
  /// The SDK rewrites this entry after every successful refresh; it is the
  /// SDK's last known-good rotation and the freshest durable copy on
  /// platforms without an out-of-process refresher. Never throws.
  Future<String> readSdkPersistedSessionJson() async {
    try {
      final url = (runtimeSupabaseUrl ?? '').trim();
      if (url.isEmpty) return '';
      final raw = await _secure.read(SecureLocalStorage.buildSessionKey(url));
      return raw?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Refresh token inside the Supabase SDK's own persisted session.
  ///
  /// Never throws — returns '' when the key is absent (explicit sign-out,
  /// first run) or the payload is unreadable.
  Future<String> readSdkPersistedRefreshToken() async {
    try {
      final raw = await readSdkPersistedSessionJson();
      if (raw.isEmpty) return '';
      final session = bareSessionJson(raw);
      if (session == null) return '';
      final decoded = jsonDecode(session);
      if (decoded is! Map) return '';
      final rt = decoded['refresh_token'];
      return rt is String ? rt.trim() : '';
    } catch (_) {
      return '';
    }
  }

  /// The freshest refresh token this device knows about (see
  /// [readRefreshTokenCandidates] for why the native copy comes first).
  Future<String> readRefreshToken() async {
    final candidates = await readRefreshTokenCandidates();
    return candidates.isEmpty ? '' : candidates.first;
  }

  /// The freshest access token this device knows about (native store first —
  /// the Android background service refreshes it on its own schedule and
  /// never updates the Dart-side copies; see [readRefreshTokenCandidates]).
  Future<String> readAccessToken() async {
    final out = <String>[];
    void add(String? v) {
      final t = v?.trim() ?? '';
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    try {
      add(await NativeSecureStore.getString(_kUserToken));
    } catch (_) {}
    try {
      add(await _secure.read(_kUserToken));
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      add(prefs.getString(_kUserToken));
    } catch (_) {}
    return out.isEmpty ? '' : out.first;
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
