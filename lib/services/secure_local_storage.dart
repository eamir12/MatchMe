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

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:matchme/services/native_secure_store.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// MatchMe's own session snapshot. Dual-stored (Dart SecureStorage + native
/// EncryptedSharedPreferences on Android) and rewritten by the background
/// service after every out-of-process rotation.
const String nativeSessionSnapshotKey = 'persisted_supabase_session';

/// The bare session object `Session.fromJson` expects.
///
/// The SDK persists `session.toJson()`; MatchMe's snapshot wraps it as
/// `{"currentSession": …}`. Returns null when [raw] is empty, unparsable or
/// carries no access token.
String? bareSessionJson(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final current = decoded['currentSession'];
    final session = current is Map ? current : decoded;
    if (session['access_token'] is! String) return null;
    return jsonEncode(Map<String, dynamic>.from(session));
  } catch (_) {
    return null;
  }
}

/// Access-token `exp` (Unix seconds) inside a bare or wrapped session payload.
/// Falls back to the stored `expires_at` when the JWT cannot be decoded.
int? sessionAccessExpiry(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final current = decoded['currentSession'];
    final session = current is Map ? current : decoded;
    final accessToken = session['access_token'];
    if (accessToken is String && accessToken.isNotEmpty) {
      final parts = accessToken.split('.');
      if (parts.length >= 2) {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (payload is Map && payload['exp'] is num) {
          return (payload['exp'] as num).toInt();
        }
      }
    }
    final expiresAt = session['expires_at'];
    return expiresAt is num ? expiresAt.toInt() : null;
  } catch (_) {
    return null;
  }
}

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

  /// The session the SDK should restore/recover from.
  ///
  /// The SDK's own entry only tracks rotations it performed itself. On
  /// Android the background service rotates the single-use refresh token out
  /// of process and rewrites only the native snapshot, so the SDK's copy can
  /// be many generations behind. Recovery would then spend that stale token,
  /// and an off-window replay revokes the whole family (2026-10-30
  /// incident). Freshness is compared by access-token `exp` — refresh tokens
  /// are opaque — and the newer copy wins.
  @override
  Future<String?> accessToken() async {
    final sdkPayload = await SecureStorageService.instance.read(
      _persistSessionKey,
    );
    final sdkSession = bareSessionJson(sdkPayload);
    final nativeSession = await _fresherNativeSession(sdkSession);
    return nativeSession ?? sdkSession ?? sdkPayload;
  }

  /// The background service's snapshot when it is strictly newer than the
  /// SDK's copy. Android only — the native store is empty elsewhere.
  Future<String?> _fresherNativeSession(String? sdkSession) async {
    if (!NativeSecureStore.isAndroid) return null;
    try {
      final nativeSession = bareSessionJson(
        await NativeSecureStore.getString(nativeSessionSnapshotKey),
      );
      if (nativeSession == null) return null;
      final nativeExp = sessionAccessExpiry(nativeSession);
      if (nativeExp == null) return null;
      final sdkExp = sessionAccessExpiry(sdkSession);
      if (sdkExp != null && sdkExp >= nativeExp) return null;
      return nativeSession;
    } catch (_) {
      return null;
    }
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
