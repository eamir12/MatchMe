// lib/services/session_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/services/app_info_service.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/native_secure_store.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/network_availability.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/services/sensitive_session_store.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:matchme/utils/offline_utils.dart';

class SessionService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static const String _prefsFcmTokenKey = 'fcm_token';
  static const String _prefsPendingAuthMethodKey = 'pending_auth_method';
  static const String _prefsCurrentAuthMethodPrefix = 'current_auth_method:';
  static const String _prefsPersistedSupabaseSessionKey =
      'persisted_supabase_session';
  static const String _prefsSupabaseAuthTokenKey = 'supabase.auth.token';
  static const String _prefsSessionIdPrefix = 'user_session_id:';
  static const String _prefsSessionMfaOverridePrefix = 'session_mfa_override:';
  static const String _prefsWebDeviceIdKey = 'web_device_id';
  static const Uuid _uuid = Uuid();
  static bool _recoveredPersistedSessionThisLaunch = false;

  // Cached public IP to avoid blocking the main thread on every registration.
  // Pre-warmed during bootstrap via warmUpPublicIp().
  static String? _cachedPublicIp;
  static DateTime? _publicIpFetchedAt;
  static Future<void>? _publicIpFetchFuture;

  // Debouncing for registerSession to prevent multiple rapid calls.
  // Bootstrap + auth listener + web tab visibility + nearby map all schedule
  // registerSession, so we keep the cooldown long enough to absorb those
  // bursts (each call does a public-IP fetch + RPC upsert, ~1.5s of work).
  static bool _registerSessionInProgress = false;
  static DateTime? _lastRegisterSessionCall;
  static String? _lastRegisterSessionUserId;
  static const Duration _registerSessionCooldown = Duration(seconds: 60);

  static bool get recoveredPersistedSessionThisLaunch =>
      _recoveredPersistedSessionThisLaunch;

  /// Fired after a successful session registration (upsert RPC or direct
  /// upsert fallback). The dashboard home provider binds this to refresh the
  /// online count: on a fresh login the initial fetchStats runs BEFORE the
  /// debounced registerSession completes, so without this the count stays 0
  /// until the 30-minute periodic timer (realtime on user_activity is not
  /// reliable enough to depend on).
  static Future<void> Function()? onSessionRegistered;

  /// Once set, [recoverPersistedSupabaseSession] always returns the current
  /// session status without attempting any recovery — used to permanently
  /// give up on a persisted session that was proven dead (e.g. a refresh
  /// token that was already consumed server-side).
  static bool _recoveryDisabled = false;

  static void disableRecovery() {
    _recoveryDisabled = true;
    _recoveredPersistedSessionThisLaunch = false;
  }

  static Map<String, dynamic> _readAccessTokenPayload() {
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) return const {};
      final parts = token.split('.');
      if (parts.length != 3) return const {};
      final normalized = base64Url.normalize(parts[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (payload is! Map<String, dynamic>) return const {};
      return payload;
    } catch (_) {
      return const {};
    }
  }

  static String _readAccessTokenClaim(String claim) {
    try {
      final payload = _readAccessTokenPayload();
      final value = payload[claim];
      return value?.toString().trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static bool isCurrentSessionMfaVerified() {
    return _readAccessTokenClaim('aal') == 'aal2';
  }

  static String? _currentSessionMfaOverrideKey() {
    final session = Supabase.instance.client.auth.currentSession;
    final tokenSource = session?.refreshToken?.trim().isNotEmpty == true
        ? session!.refreshToken!.trim()
        : session?.accessToken.trim();
    if (tokenSource == null || tokenSource.isEmpty) return null;
    final fingerdebugPrint = sha256
        .convert(utf8.encode(tokenSource))
        .toString();
    return '$_prefsSessionMfaOverridePrefix$fingerdebugPrint';
  }

  static Future<bool> hasCurrentSessionMfaOverride() async {
    try {
      final key = _currentSessionMfaOverrideKey();
      if (key == null || key.isEmpty) return false;
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static bool _isTransientSupabaseNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    return error is http.ClientException ||
        text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('no address associated with hostname') ||
        text.contains('network is unreachable') ||
        text.contains('connection refused') ||
        text.contains('connection reset by peer') ||
        text.contains('connection closed') ||
        text.contains('software caused connection abort') ||
        text.contains('timed out') ||
        text.contains('timeoutexception');
  }

  static Future<void> setCurrentSessionMfaOverride(bool value) async {
    try {
      final key = _currentSessionMfaOverrideKey();
      if (key == null || key.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      if (value) {
        await prefs.setBool(key, true);
      } else {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  static Future<void> clearPendingAuthMethod() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsPendingAuthMethodKey);
    } catch (_) {}
  }

  static String? _currentAuthMethodKey() {
    final userId = Supabase.instance.client.auth.currentUser?.id.trim();
    if (userId == null || userId.isEmpty) return null;
    return '$_prefsCurrentAuthMethodPrefix$userId';
  }

  static Future<void> setCurrentSessionAuthMethod(String? authMethod) async {
    try {
      final key = _currentAuthMethodKey();
      if (key == null || key.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final normalized = _normalizeAuthMethod(authMethod);
      if (normalized == null) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(key, normalized);
    } catch (_) {}
  }

  static Future<String?> _getStoredCurrentSessionAuthMethod() async {
    try {
      final key = _currentAuthMethodKey();
      if (key == null || key.isEmpty) return null;
      final prefs = await SharedPreferences.getInstance();
      return _normalizeAuthMethod(prefs.getString(key));
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCurrentSessionAuthArtifacts() async {
    await setCurrentSessionMfaOverride(false);
    await clearPendingAuthMethod();
    await setCurrentSessionAuthMethod(null);
  }

  static Future<void> persistCurrentSupabaseSessionSnapshot() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        await clearPersistedSupabaseSessionSnapshot();
        return;
      }

      // The snapshot embeds access + refresh tokens, so it must only live in
      // encrypted stores: Dart SecureStorage + native EncryptedSharedPreferences
      // (Android). Legacy plaintext copies are removed on write.
      final payload = jsonEncode({
        'currentSession': session.toJson(),
        'expiresAt': session.expiresAt,
      });
      final secure = SecureStorageService.instance;
      await secure.write(_prefsPersistedSupabaseSessionKey, payload);
      await secure.delete(_prefsSupabaseAuthTokenKey);
      await NativeSecureStore.setString(
        _prefsPersistedSupabaseSessionKey,
        payload,
      );
      await NativeSecureStore.setString(_prefsSupabaseAuthTokenKey, null);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_prefsPersistedSupabaseSessionKey);
        await prefs.remove(_prefsSupabaseAuthTokenKey);
      } catch (_) {}
    } catch (_) {}
  }

  static bool _explicitUserSignOut = false;

  static void markExplicitUserSignOut() {
    _explicitUserSignOut = true;
    // A fresh sign-in after this must always register a session, even when it
    // is the same account inside the 60s per-user cooldown window. The
    // cooldown only exists to coalesce duplicate registrations for the same
    // ongoing session (bootstrap + auth listener + FCM racing); an explicit
    // logout ends that session, so the next login is a genuinely new one that
    // must not be skipped — otherwise the server-side "online only with an
    // active session" gate (migration 20260814000000) keeps the re-logged-in
    // user offline because only revoked session rows remain.
    _lastRegisterSessionCall = null;
    _lastRegisterSessionUserId = null;
    // No longer signed in — stop the visibility-independent heartbeat so it
    // cannot ping a stale userId.
    UserActivityService.instance.stopHeartbeat();
  }

  static bool consumeExplicitUserSignOutFlag() {
    final val = _explicitUserSignOut;
    _explicitUserSignOut = false;
    return val;
  }

  static const String _prefsSignOutReasonKey = 'last_sign_out_reason';

  static Future<void> persistSignOutReason({
    required String reason,
    String? source,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsSignOutReasonKey,
        jsonEncode({
          'reason': reason,
          'source': source,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> getLastSignOutReason() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsSignOutReasonKey);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static const String _prefsSessionCreatedAtKey = 'session_created_at';

  static Future<void> setSessionCreatedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _prefsSessionCreatedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static Future<DateTime?> getSessionCreatedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_prefsSessionCreatedAtKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPersistedSupabaseSessionSnapshot() async {
    try {
      _recoveredPersistedSessionThisLaunch = false;
      final prefs = await SharedPreferences.getInstance();

      // Clear all auth-related stored data to ensure clean state for next login
      // This is especially important after offline→online→logout cycle
      final secure = SecureStorageService.instance;
      await secure.delete(_prefsPersistedSupabaseSessionKey);
      await secure.delete(_prefsSupabaseAuthTokenKey);
      await NativeSecureStore.clearKeys(const [
        _prefsPersistedSupabaseSessionKey,
        _prefsSupabaseAuthTokenKey,
      ]);
      // Remove SDK session keys (sb-*-auth-token) from every store.
      try {
        await secure.deleteByPrefixes(const ['sb-']);
      } catch (_) {}
      await prefs.remove(_prefsPersistedSupabaseSessionKey);
      await prefs.remove(_prefsSupabaseAuthTokenKey);
      await prefs.remove(_prefsSignOutReasonKey);
      await prefs.remove(_prefsSessionCreatedAtKey);

      // Native auth-token copies (flutter.user_id / user_token / refresh_token).
      // recoverPersistedSupabaseSession falls back to `flutter.refresh_token`
      // when no snapshot exists, so leaving these behind silently
      // re-authenticates an explicitly signed-out user on the next launch
      // (app opens on Home instead of the login screen).
      await SensitiveSessionStore.instance.clearAuthTokens();

      // Also clear any session-specific MFA overrides that might linger
      final allKeys = prefs.getKeys();
      for (final key in allKeys) {
        if (key.startsWith(_prefsSessionMfaOverridePrefix) ||
            key.startsWith(_prefsSessionIdPrefix) ||
            key.startsWith(_prefsCurrentAuthMethodPrefix) ||
            (key.startsWith('sb-') && key.endsWith('-auth-token'))) {
          await prefs.remove(key);
        }
      }

      debugPrint(
        '🔐 [SESSION] Cleared all persisted auth data (session, tokens, MFA overrides)',
      );
    } catch (e) {
      debugPrint('❌ [SESSION] Error clearing persisted auth data: $e');
    }
  }

  /// Mutex to serialize concurrent refreshSession calls (Dart-side).
  /// GoTrue rotating refresh tokens are single-use: concurrent refreshes with
  /// the same old token cause `refresh_token_already_used` and server-side
  /// revocation of the entire session family.
  static Completer<void>? _refreshCompleter;
  static final Stopwatch _lastRefreshStopwatch = Stopwatch();
  static int _alreadyUsedRetryCount = 0;
  static const int _maxAlreadyUsedRetries = 3;

  /// Serialize refreshSession calls and handle `refresh_token_already_used`
  /// races where the native background service (Android/iOS) may have already
  /// rotated the token in `flutter.refresh_token`. On `already_used` we retry
  /// with the latest native token with exponential backoff.
  static Future<bool> safeRefreshSession({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    // If another refresh is already in flight, wait for it (with timeout)
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      try {
        await _refreshCompleter!.future.timeout(timeout);
      } catch (_) {}
      return Supabase.instance.client.auth.currentSession != null;
    }

    _refreshCompleter = Completer<void>();
    try {
      try {
        _lastRefreshStopwatch.start();
        await Supabase.instance.client.auth.refreshSession().timeout(timeout);
        _lastRefreshStopwatch.stop();
        _alreadyUsedRetryCount = 0; // Reset on success
      } on TimeoutException {
        _lastRefreshStopwatch.stop();
        rethrow;
      } catch (e) {
        _lastRefreshStopwatch.stop();
        final msg = e.toString().toLowerCase();
        final isAlreadyUsed =
            msg.contains('refresh_token_already_used') ||
            msg.contains('refresh_token_not_found') ||
            msg.contains('invalid_grant') ||
            msg.contains('already used');

        if (isAlreadyUsed) {
          // Native may have rotated the token - try its latest with backoff
          _alreadyUsedRetryCount++;

          if (_alreadyUsedRetryCount > _maxAlreadyUsedRetries) {
            debugPrint(
              '❌ [SESSION] safeRefresh: Already-used retry count exhausted ($_maxAlreadyUsedRetries attempts). Token may be permanently invalid.',
            );
            // Mark auth as permanently failed to prevent infinite recovery loops
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('flutter.auth_permanently_failed', true);
            } catch (_) {}
            rethrow;
          }

          try {
            // Exponential backoff: 50ms * 2^(attempt-1)
            final backoffMs = 50 * (1 << (_alreadyUsedRetryCount - 1));
            await Future.delayed(Duration(milliseconds: backoffMs));

            final flutterRt = await SensitiveSessionStore.instance
                .readRefreshToken();
            final currentRt =
                Supabase.instance.client.auth.currentSession?.refreshToken
                    ?.trim() ??
                '';

            if (flutterRt.isNotEmpty && flutterRt != currentRt) {
              debugPrint(
                '🔐 [SESSION] safeRefresh: retrying with native flutter.refresh_token (attempt $_alreadyUsedRetryCount/$_maxAlreadyUsedRetries) after already_used',
              );
              try {
                await Supabase.instance.client.auth
                    .refreshSession(flutterRt)
                    .timeout(timeout);
                await persistCurrentSupabaseSessionSnapshot();

                // Sync back to secure store + native shim via prefs
                try {
                  final s = Supabase.instance.client.auth.currentSession;
                  if (s != null) {
                    final prefs = await SharedPreferences.getInstance();
                    await SensitiveSessionStore.instance.writeAuthTokens(
                      userId: s.user.id,
                      accessToken: s.accessToken,
                      refreshToken: s.refreshToken,
                    );
                    await prefs.setBool(
                      'flutter.auth_permanently_failed',
                      false,
                    );
                  }
                } catch (_) {}
                _alreadyUsedRetryCount = 0; // Reset on success
                return Supabase.instance.client.auth.currentSession != null;
              } catch (_) {
                // Fall through to rethrow original
              }
            }
          } catch (_) {}
        }
        rethrow;
      }

      await persistCurrentSupabaseSessionSnapshot();
      // Ensure secure store + flutter.* shim stay in sync for native recovery
      try {
        final s = Supabase.instance.client.auth.currentSession;
        if (s != null) {
          await SensitiveSessionStore.instance.writeAuthTokens(
            userId: s.user.id,
            accessToken: s.accessToken,
            refreshToken: s.refreshToken,
          );
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('flutter.auth_permanently_failed', false);
        }
      } catch (_) {}
      return true;
    } catch (e) {
      if (e is TimeoutException || _isTransientSupabaseNetworkFailure(e)) {
        rethrow;
      }
      // Non-network refresh failures (e.g. expired) are handled by caller
      rethrow;
    } finally {
      if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
        _refreshCompleter!.complete();
      }
      _refreshCompleter = null;
    }
  }

  /// Cooldown guard: prevents re-entry when [setInitialSession] triggers SDK
  /// token refresh which fails and fires a follow-up [signedOut] event,
  /// creating an infinite recovery loop.
  static DateTime? _lastRecoveryAttempt;

  /// Gather persisted session snapshots, encrypted stores first (this
  /// release), then legacy plaintext keys for upgrade migration.
  static Future<List<String>> _gatherPersistedSessionCandidates() async {
    final candidates = <String>[];
    void add(String? v) {
      final t = v?.trim() ?? '';
      if (t.isNotEmpty && !candidates.contains(t)) candidates.add(t);
    }

    final secure = SecureStorageService.instance;
    add(await secure.read(_prefsPersistedSupabaseSessionKey));
    add(await NativeSecureStore.getString(_prefsPersistedSupabaseSessionKey));
    try {
      final prefs = await SharedPreferences.getInstance();
      add(prefs.getString(_prefsPersistedSupabaseSessionKey));
      add(prefs.getString(_prefsSupabaseAuthTokenKey));
      // Legacy sb-*-auth-token keys used by older supabase_flutter.
      for (final k in prefs.getKeys()) {
        if (k.startsWith('sb-') && k.endsWith('-auth-token')) {
          add(prefs.getString(k));
        }
      }
    } catch (_) {}
    return candidates;
  }

  static Future<bool> recoverPersistedSupabaseSession({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    // If recovery has been permanently disabled (session proven dead), do
    // not retry — just report the current in-memory session status.
    if (_recoveryDisabled) {
      return Supabase.instance.client.auth.currentSession != null;
    }

    // If recovery was attempted within the last 10 seconds, suppress it to
    // break the setInitialSession → SDK refresh-fail → signedOut → recurse loop.
    if (_lastRecoveryAttempt != null &&
        DateTime.now().difference(_lastRecoveryAttempt!) <
            const Duration(seconds: 10)) {
      return Supabase.instance.client.auth.currentSession != null;
    }
    _lastRecoveryAttempt = DateTime.now();

    try {
      final existingSession = Supabase.instance.client.auth.currentSession;
      if (existingSession != null) return true;

      final candidates = await _gatherPersistedSessionCandidates();

      for (final raw in candidates) {
        if (raw.isEmpty) continue;

        final normalizedPayload = _normalizePersistedSupabaseSessionPayload(
          raw,
        );
        final sessionJson = _extractSupabaseSessionJson(raw);
        if (normalizedPayload == null || sessionJson == null) {
          continue;
        }

        try {
          await Supabase.instance.client.auth
              .recoverSession(normalizedPayload)
              .timeout(timeout);
        } catch (_) {
          // When offline and the access token is expired, recoverSession may try
          // to refresh and fail. Seed the local session anyway so the app can
          // enter its offline-authenticated flow.
          try {
            await Supabase.instance.client.auth
                .setInitialSession(sessionJson)
                .timeout(const Duration(seconds: 1));
          } catch (_) {}
        }

        final recoveredSession = Supabase.instance.client.auth.currentSession;
        if (recoveredSession == null) {
          continue;
        }

        _recoveredPersistedSessionThisLaunch = true;
        await persistCurrentSupabaseSessionSnapshot();

        // DEBUG: Log session recovery for auth token debugging
        if (kDebugMode) {
          debugPrint('🔐 [SESSION] Session recovered successfully');
          debugPrint(
            '🔐 [SESSION] Access token present: ${recoveredSession.accessToken.isNotEmpty}',
          );
        }

        return true;
      }

      // Fallback: native background service may have refreshed in background and
      // written `flutter.refresh_token` / `persisted_supabase_session`. Try it
      // (secure store first, plain shim fallback for upgrades).
      try {
        final flutterRt = await SensitiveSessionStore.instance
            .readRefreshToken();
        if (flutterRt.isNotEmpty) {
          try {
            await Supabase.instance.client.auth
                .refreshSession(flutterRt)
                .timeout(timeout);
            final recovered = Supabase.instance.client.auth.currentSession;
            if (recovered != null) {
              _recoveredPersistedSessionThisLaunch = true;
              await persistCurrentSupabaseSessionSnapshot();
              if (kDebugMode) {
                debugPrint(
                  '🔐 [SESSION] Recovered via native flutter.refresh_token',
                );
              }
              return true;
            }
          } catch (_) {
            // Refresh with native token failed - may be already_used too, fall through
          }
        }
      } catch (_) {}

      return false;
    } catch (_) {
      return Supabase.instance.client.auth.currentSession != null;
    }
  }

  static String? _normalizePersistedSupabaseSessionPayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final currentSession = decoded['currentSession'];
      final expiresAt = decoded['expiresAt'];
      if (currentSession is Map<String, dynamic>) {
        final normalizedExpiresAt = expiresAt is int
            ? expiresAt
            : int.tryParse(expiresAt?.toString() ?? '');
        return jsonEncode({
          'currentSession': currentSession,
          'expiresAt':
              normalizedExpiresAt ??
              Session.fromJson(currentSession)?.expiresAt,
        });
      }

      final session = Session.fromJson(decoded);
      if (session == null) return null;
      return jsonEncode({
        'currentSession': session.toJson(),
        'expiresAt': session.expiresAt,
      });
    } catch (_) {
      return null;
    }
  }

  static String? _extractSupabaseSessionJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final currentSession = decoded['currentSession'];
      if (currentSession is Map<String, dynamic>) {
        return jsonEncode(currentSession);
      }

      final session = Session.fromJson(decoded);
      if (session == null) return null;
      return jsonEncode(session.toJson());
    } catch (_) {
      return null;
    }
  }

  /// Restores the persisted session into memory WITHOUT any network call.
  ///
  /// Used as a last resort when the Supabase SDK emits a non-explicit
  /// `signedOut` (e.g. its background refresh failed with
  /// `refresh_token_already_used` and it cleared the in-memory session).
  /// Per session policy the user must stay logged in, so we re-seed the
  /// last known session via `setInitialSession` (which bypasses validation)
  /// and stop auto-refresh to break the refresh-fail → signedOut loop.
  /// Returns true when an in-memory session exists afterwards.
  ///
  /// This intentionally bypasses [_recoveryDisabled] and the recovery
  /// cooldown: it performs no network IO and therefore cannot recurse.
  static Future<bool> restorePersistedSessionOfflineOnly() async {
    try {
      if (Supabase.instance.client.auth.currentSession != null) return true;
      final candidates = await _gatherPersistedSessionCandidates();
      for (final raw in candidates) {
        if (raw.isEmpty) continue;
        final sessionJson = _extractSupabaseSessionJson(raw);
        if (sessionJson == null) continue;
        try {
          await Supabase.instance.client.auth
              .setInitialSession(sessionJson)
              .timeout(const Duration(seconds: 1));
        } catch (_) {}
        if (Supabase.instance.client.auth.currentSession != null) {
          _recoveredPersistedSessionThisLaunch = true;
          try {
            Supabase.instance.client.auth.stopAutoRefresh();
          } catch (_) {}
          return true;
        }
      }
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      return Supabase.instance.client.auth.currentSession != null;
    }
  }

  /// Whether any persisted session snapshot exists on disk (ours or the
  /// SDK's own `sb-*-auth-token` entry). Used to distinguish "genuinely
  /// logged out" (nothing stored → forwarding null is correct) from
  /// "SDK cleared a live session" (snapshot exists → must stay logged in).
  static Future<bool> hasAnyPersistedSession() async {
    try {
      final candidates = await _gatherPersistedSessionCandidates();
      return candidates.isNotEmpty;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_prefsSupabaseAuthTokenKey)?.trim() ?? '';
      return legacy.isNotEmpty;
    }
  }

  static Future<void> setPendingAuthMethod(String? authMethod) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalized = _normalizeAuthMethod(authMethod);
      if (normalized == null) {
        await clearPendingAuthMethod();
        return;
      }
      await prefs.setString(
        _prefsPendingAuthMethodKey,
        jsonEncode({
          'method': normalized,
          'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  static Future<String?> _consumePendingAuthMethod() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsPendingAuthMethodKey)?.trim();
      if (raw == null || raw.isEmpty) return null;
      await prefs.remove(_prefsPendingAuthMethodKey);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final createdAtMs = decoded['created_at_ms'];
      final createdAt = createdAtMs is int
          ? createdAtMs
          : int.tryParse(createdAtMs?.toString() ?? '');
      if (createdAt == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - createdAt;
      if (age < 0 || age > const Duration(minutes: 15).inMilliseconds) {
        return null;
      }
      return _normalizeAuthMethod(decoded['method']?.toString());
    } catch (_) {
      return null;
    }
  }

  static String? _normalizeAuthMethod(String? authMethod) {
    final normalized = authMethod?.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]+'),
      '_',
    );
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }

  static String? _mapProviderToAuthMethod(String? provider) {
    final normalized = provider?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    if (normalized == 'email') return 'password';
    if (normalized == 'webauthn' || normalized == 'passkey') return 'passkey';
    if (normalized == 'phone') return 'sms_otp';
    if (normalized == 'otp') return 'email_otp';
    if (normalized == 'azure' || normalized == 'azuread') return 'oauth_azure';
    return 'oauth_$normalized';
  }

  static bool _platformSupportsPasskeys(String platform) {
    switch (platform.trim().toLowerCase()) {
      case 'web':
      case 'android':
      case 'ios':
      case 'macos':
      case 'windows':
        return true;
      default:
        return false;
    }
  }

  static Future<String?> _inferCurrentAuthMethod({
    String? explicitAuthMethod,
  }) async {
    final explicit = _normalizeAuthMethod(explicitAuthMethod);
    if (explicit != null) {
      await setCurrentSessionAuthMethod(explicit);
      return explicit;
    }

    final pending = await _consumePendingAuthMethod();
    if (pending != null) {
      await setCurrentSessionAuthMethod(pending);
      return pending;
    }

    final stored = await _getStoredCurrentSessionAuthMethod();
    if (stored != null) return stored;

    final payload = _readAccessTokenPayload();
    final amr = payload['amr'];
    if (amr is List) {
      final values = <String>{};
      for (final entry in amr) {
        values.add(entry.toString().trim().toLowerCase());
      }
      if (values.contains('webauthn') || values.contains('passkey')) {
        await setCurrentSessionAuthMethod('passkey');
        return 'passkey';
      }
      if (values.contains('pwd') || values.contains('password')) {
        await setCurrentSessionAuthMethod('password');
        return 'password';
      }
      if (values.contains('otp') || values.contains('email')) {
        await setCurrentSessionAuthMethod('email_otp');
        return 'email_otp';
      }
    }

    final user = Supabase.instance.client.auth.currentUser;
    final appMetadata = user?.appMetadata;
    final appProvider = appMetadata?['provider']?.toString();
    final appMethod = _mapProviderToAuthMethod(appProvider);
    if (appMethod != null) return appMethod;

    final providers = <String>{};
    final rawProviders = appMetadata?['providers'];
    if (rawProviders is List) {
      for (final provider in rawProviders) {
        final normalized = provider?.toString().trim().toLowerCase();
        if (normalized != null && normalized.isNotEmpty) {
          providers.add(normalized);
        }
      }
    }
    final identities = user?.identities;
    if (identities != null) {
      for (final identity in identities) {
        final normalized = identity.provider.trim().toLowerCase();
        if (normalized.isNotEmpty) {
          providers.add(normalized);
        }
      }
    }

    if (providers.contains('webauthn') || providers.contains('passkey')) {
      return 'passkey';
    }
    for (final provider in const [
      'google',
      'azure',
      'azuread',
      'apple',
      'facebook',
    ]) {
      if (providers.contains(provider)) {
        return _mapProviderToAuthMethod(provider);
      }
    }
    if (providers.contains('email')) return 'password';
    if (providers.contains('phone')) return 'sms_otp';
    return null;
  }

  static Future<String?> getCurrentSessionAuthMethod() async {
    return _inferCurrentAuthMethod();
  }

  static String _sessionIdPrefsKey(
    String userId,
    String platform, {
    String? deviceId,
  }) {
    final uid = userId.trim();
    final p = platform.trim();
    final did = deviceId?.trim();
    if (did != null && did.isNotEmpty) {
      return '$_prefsSessionIdPrefix$uid:$p:$did';
    }
    return '$_prefsSessionIdPrefix$uid:$p';
  }

  static Future<String?> _getStoredSessionId(
    String userId,
    String platform, {
    String? deviceId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionIdPrefsKey(userId, platform, deviceId: deviceId);
      final v = prefs.getString(key);
      final trimmed = v?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearStoredSessionId(
    String userId,
    String platform, {
    String? deviceId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionIdPrefsKey(userId, platform, deviceId: deviceId);
      await prefs.remove(key);
    } catch (_) {}
  }

  static Future<void> _storeSessionId(
    String userId,
    String platform,
    String sessionId, {
    String? deviceId,
  }) async {
    final uid = userId.trim();
    final p = platform.trim();
    final sid = sessionId.trim();
    if (uid.isEmpty || p.isEmpty || sid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionIdPrefsKey(uid, p, deviceId: deviceId);
      await prefs.setString(key, sid);
    } catch (_) {}
  }

  static Future<String?> _getStoredFcmToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefsFcmTokenKey);
      final trimmed = v?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _storeFcmToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsFcmTokenKey, trimmed);
    } catch (_) {}
  }

  static Future<void> clearLocalFcmToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsFcmTokenKey);
    } catch (_) {}
  }

  static Future<void> deleteFcmToken() async {
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  static Future<void> revokeCurrentSession({
    required String userId,
    required String platform,
    String? deviceId,
  }) async {
    final uid = userId.trim();
    final p = platform.trim();
    if (uid.isEmpty || p.isEmpty) return;

    final sessionId = await _getStoredSessionId(uid, p, deviceId: deviceId);
    if (sessionId == null || sessionId.isEmpty) return;

    try {
      await Supabase.instance.client
          .from('user_session')
          .update({'revoked': true})
          .eq('id', sessionId)
          .eq('user_id', uid);
    } catch (_) {}
  }

  static Future<String?> _getDeviceIdFast() async {
    if (kIsWeb) return _getOrCreateWebDeviceId();
    try {
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        final v = info.id.trim();
        return v.isEmpty ? null : v;
      }
      if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        final v = (info.identifierForVendor ?? '').trim();
        return v.isEmpty ? null : v;
      }
    } catch (_) {}
    return null;
  }

  /// Returns a stable per-browser identifier used as the web platform's
  /// device_id in user_session rows. Generated on first call and stored in
  /// SharedPreferences so it persists across reloads and tab sessions, which
  /// lets the backend group sessions for the same browser the way Android's
  /// SSAID and iOS's identifierForVendor already do.
  static Future<String?> _getOrCreateWebDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_prefsWebDeviceIdKey)?.trim();
      if (existing != null && existing.isNotEmpty) return existing;
      final generated = _uuid.v4();
      await prefs.setString(_prefsWebDeviceIdKey, generated);
      return generated;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearFcmStateOnLogout({
    String? userId,
    String? platform,
  }) async {
    final uid = userId?.trim();
    final p = platform?.trim();
    if (uid != null && uid.isNotEmpty && p != null && p.isNotEmpty) {
      final deviceId = await _getDeviceIdFast();
      await revokeCurrentSession(userId: uid, platform: p, deviceId: deviceId);
      await _clearStoredSessionId(uid, p, deviceId: deviceId);
    }
    await deleteFcmToken();
    await clearLocalFcmToken();
  }

  static Future<String?> _fetchPublicIp() async {
    // Return cached IP if fresh (< 4 minutes old)
    if (_cachedPublicIp != null && _publicIpFetchedAt != null) {
      final age = DateTime.now().difference(_publicIpFetchedAt!);
      if (age < const Duration(minutes: 4)) {
        return _cachedPublicIp;
      }
    }
    // If a fetch is already in flight, wait for it
    if (_publicIpFetchFuture != null) {
      await _publicIpFetchFuture;
      return _cachedPublicIp;
    }
    // Fetch fresh IP
    _publicIpFetchFuture = _fetchPublicIpUncached();
    try {
      await _publicIpFetchFuture;
    } finally {
      _publicIpFetchFuture = null;
    }
    return _cachedPublicIp;
  }

  /// Pre-warm the public IP cache during bootstrap so it's ready by the time
  /// registerSession needs it. This prevents the main-thread block.
  static void warmUpPublicIp() {
    if (_cachedPublicIp != null && _publicIpFetchedAt != null) {
      final age = DateTime.now().difference(_publicIpFetchedAt!);
      if (age < const Duration(minutes: 4)) return;
    }
    _publicIpFetchFuture ??= _fetchPublicIpUncached();
  }

  static Future<void> _fetchPublicIpUncached() async {
    final start = DateTime.now();
    try {
      // Check connectivity before attempting fetch. The platform transport
      // result is only a hint, so a "no transport" answer is confirmed with
      // a real HTTP probe before the fetch is skipped.
      final signal = await resolveNetworkTransport();
      if (!signal.hasTransport) {
        if (kDebugMode) {
          debugPrint(
            '[BGSESSION] _fetchPublicIp: skipped - device is offline (elapsed=${DateTime.now().difference(start).inMilliseconds}ms)',
          );
        }
        return;
      }

      final r = await http
          .get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 5));
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        _cachedPublicIp = data['ip'] as String?;
        _publicIpFetchedAt = DateTime.now();
        if (kDebugMode) {
          debugPrint(
            '[BGSESSION] _fetchPublicIp: cached (elapsed=${elapsed}ms)',
          );
        }
      } else {
        if (kDebugMode) {
          debugPrint(
            '[BGSESSION] _fetchPublicIp: non-200 status=${r.statusCode} elapsed=${elapsed}ms',
          );
        }
      }
    } catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      // Suppress error logging for expected offline failures
      final errorText = e.toString().toLowerCase();
      // 'failed to fetch' is the browser-side generic error thrown for any
      // network-layer failure on web (CORS, mixed-content, offline, blocked
      // by an extension, etc.). It's noisy in dev logs but doesn't carry
      // any actionable info we don't already get from the connectivity
      // pre-check above, so demote it to a debug-level note.
      if (errorText.contains('socketexception') ||
          errorText.contains('failed host lookup') ||
          errorText.contains('no address associated with hostname') ||
          errorText.contains('failed to fetch') ||
          errorText.contains('clientexception')) {
        if (kDebugMode) {
          debugPrint(
            '[BGSESSION] _fetchPublicIp: offline - expected network failure (elapsed=${elapsed}ms)',
          );
        }
      } else {
        if (kDebugMode) {
          debugPrint(
            '[BGSESSION] _fetchPublicIp: failed: $e elapsed=${elapsed}ms',
          );
        }
      }
    }
  }

  static String _tokenHash(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static Future<String?> _getUserTimezone() async {
    try {
      final timezone = (await FlutterTimezone.getLocalTimezone()).identifier
          .trim();
      if (timezone.isEmpty || !timezone.contains('/')) {
        return null;
      }
      return timezone;
    } catch (e) {
      debugPrint('[BGSESSION] getUserTimezone failed: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>> collectSessionInfo({
    String? platformOverride,
    String? fcmTokenOverride,
    String? authMethodOverride,
  }) async {
    final totalStart = DateTime.now();
    final appInfo = await AppInfoService.getAppInfo();

    String? deviceModel = 'unknown';
    String? deviceId = '';

    // Run device info, IP fetch, timezone, and auth method in parallel
    // to avoid blocking the main thread sequentially.
    late final Future<String?> ipFuture;
    late final Future<String?> tzFuture;
    late final Future<String?> authMethodFuture;

    try {
      final deviceStart = DateTime.now();
      if (kIsWeb) {
        deviceModel = 'web';
        deviceId = await _getOrCreateWebDeviceId();
      } else {
        if (Platform.isAndroid) {
          final info = await _deviceInfo.androidInfo;
          deviceModel = info.model;
          deviceId = info.id;
        } else if (Platform.isIOS) {
          final info = await _deviceInfo.iosInfo;
          deviceModel = info.utsname.machine;
          deviceId = info.identifierForVendor;
        } else if (Platform.isMacOS) {
          final info = await _deviceInfo.macOsInfo;
          deviceModel = info.model;
        } else if (Platform.isWindows) {
          final info = await _deviceInfo.windowsInfo;
          deviceModel = info.computerName;
        } else if (Platform.isLinux) {
          final info = await _deviceInfo.linuxInfo;
          deviceModel = info.name;
        }
      }
      if (kDebugMode) {
        debugPrint(
          '[BGSESSION] collectSessionInfo: device info collected (elapsed=${DateTime.now().difference(deviceStart).inMilliseconds}ms)',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[BGSESSION] collectSessionInfo: device info collection failed: $e',
        );
      }
    }

    // Launch parallel futures for independent network/storage calls
    ipFuture = _fetchPublicIp();
    tzFuture = _getUserTimezone();
    authMethodFuture = _inferCurrentAuthMethod(
      explicitAuthMethod: authMethodOverride,
    );

    final session = Supabase.instance.client.auth.currentSession;
    final token = session?.accessToken ?? '';
    final tokenHash = token.isNotEmpty ? _tokenHash(token) : null;

    final platformText = platformOverride ?? _detectPlatform();

    final userAgent =
        '${appInfo.appName}/${appInfo.version} (${deviceModel ?? 'unknown'})';

    // Await all parallel results
    final results = await Future.wait<String?>([
      ipFuture,
      tzFuture,
      authMethodFuture,
    ]);
    final ip = results[0];
    final userTimezone = results[1];
    final authMethod = results[2];

    final metadata = {
      'app_name': appInfo.appName,
      'app_version': appInfo.version,
      'build_number': appInfo.buildNumber,
      'platform': platformText,
      'device_model': deviceModel ?? 'unknown',
      'passkey_platform_ready': _platformSupportsPasskeys(platformText),
    };
    if (authMethod != null) {
      metadata['auth_method'] = authMethod;
    }
    final overrideTrimmed = fcmTokenOverride?.trim();
    if (overrideTrimmed != null && overrideTrimmed.isNotEmpty) {
      await _storeFcmToken(overrideTrimmed);
    }

    final fcmToken = overrideTrimmed ?? await _getStoredFcmToken();
    if (fcmToken != null && fcmToken.isNotEmpty) {
      metadata['fcm_token'] = fcmToken;
      metadata['fcm_token_updated_at'] = DateTime.now().toIso8601String();
    }
    if (userTimezone != null) {
      metadata['user_timezone'] = userTimezone;
    }

    if (kDebugMode) {
      debugPrint(
        '[BGSESSION] collectSessionInfo: total elapsed=${DateTime.now().difference(totalStart).inMilliseconds}ms',
      );
    }

    return {
      'p_platform': platformText,
      'p_device_id': (deviceId != null && deviceId.isNotEmpty)
          ? deviceId
          : null,
      'p_device_model': deviceModel,
      'p_user_agent': userAgent,
      'p_ip': ip,
      'p_token_hash': tokenHash,
      'p_auth_method': authMethod,
      'p_metadata': metadata,
    };
  }

  static Future<String?> _inferCountryCodeFromCoordsHttp(
    double lat,
    double lon,
  ) async {
    try {
      final uri =
          Uri.https('nominatim.openstreetmap.org', '/reverse', <String, String>{
            'format': 'jsonv2',
            'lat': lat.toString(),
            'lon': lon.toString(),
            'zoom': '3',
            'addressdetails': '1',
          });
      final resp = await http
          .get(
            uri,
            headers: const <String, String>{'User-Agent': 'matchme.app'},
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final address = decoded['address'];
      if (address is! Map) return null;
      final code = (address['country_code'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      return code.length == 2 ? code : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> inferCountryCodeFromCoordinates(
    double lat,
    double lon,
  ) async {
    if (kIsWeb) {
      return _inferCountryCodeFromCoordsHttp(lat, lon);
    }

    try {
      final placemarks = await Geocoding()
          .placemarkFromCoordinates(lat, lon)
          .timeout(const Duration(seconds: 4));
      if (placemarks.isNotEmpty) {
        final code = (placemarks.first.isoCountryCode ?? '')
            .trim()
            .toUpperCase();
        if (code.length == 2) return code;
      }
    } catch (_) {}

    return _inferCountryCodeFromCoordsHttp(lat, lon);
  }

  static Future<String?> _inferCountryCodeBestEffort(
    String userId, {
    double? latitude,
    double? longitude,
  }) async {
    if (await PinnedLocationGate.isActive()) return null;
    final uid = userId.trim();
    if (uid.isEmpty) return null;

    if (latitude != null && longitude != null) {
      final hintedCode = await inferCountryCodeFromCoordinates(
        latitude,
        longitude,
      );
      if (hintedCode != null) return hintedCode;
    }

    try {
      final db = await LocalDbService.instance;
      final cached = await db.getCurrentLocation(uid);
      if (cached != null) {
        final lat = (cached['latitude'] as num?)?.toDouble();
        final lon = (cached['longitude'] as num?)?.toDouble();
        if (lat != null && lon != null) {
          final code = await inferCountryCodeFromCoordinates(lat, lon);
          if (code != null) return code;
        }
      }
    } catch (_) {}

    try {
      final rows = await Supabase.instance.client
          .from('user_locations')
          .select('latitude, longitude')
          .eq('user_id', uid)
          .order('updated_at', ascending: false)
          .limit(1);

      final list = (rows as List).cast<Map<String, dynamic>>();
      if (list.isNotEmpty) {
        final lat = (list.first['latitude'] as num?)?.toDouble();
        final lon = (list.first['longitude'] as num?)?.toDouble();
        if (lat != null && lon != null) {
          final code = await inferCountryCodeFromCoordinates(lat, lon);
          if (code != null) return code;
        }
      }
    } catch (_) {}

    try {
      final permission = await Geolocator.checkPermission();
      final granted =
          permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      if (!granted) return null;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 4),
        ),
      );
      return await inferCountryCodeFromCoordinates(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  static String _detectPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  /// Wait for JWT token to become available (max 5 seconds)
  static Future<bool> _waitForJwtToken({int maxWaitSeconds = 5}) async {
    final startTime = DateTime.now();
    while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
      final session = Supabase.instance.client.auth.currentSession;
      if (session?.accessToken != null && session!.accessToken.isNotEmpty) {
        debugPrint(
          '[BGSESSION] JWT token available after ${DateTime.now().difference(startTime).inMilliseconds}ms',
        );
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    debugPrint(
      '[BGSESSION] WARNING: JWT token not available after $maxWaitSeconds seconds',
    );
    return false;
  }

  static Future<bool> registerSession(
    String userId, {
    String? platform,
    String? fcmToken,
    String? authMethod,
    String? countryOverride,
    double? latitude,
    double? longitude,
    bool bypassCooldown = false,
  }) async {
    // Check if Supabase is paused (global offline mode) — uses cached state, no blocking calls
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '[BGSESSION] registerSession: skipped - Supabase communication paused',
      );
      OfflineCacheManager.instance.setSupabaseAvailability(false);
      return false;
    }

    // Debouncing: Skip if registration is already in progress
    if (_registerSessionInProgress) {
      debugPrint(
        '[BGSESSION] registerSession: Skipping - registration already in progress',
      );
      return false;
    }

    // Debouncing: Skip if within cooldown period for the SAME user (unless
    // bypassed for FCM updates). The cooldown is per-user so rapid account
    // switching (login/logout testing, multi-account devices) never starves
    // the newly signed-in user of a session row — without this, a different
    // account signing in within 60s of the previous one was silently skipped
    // and never appeared online.
    final now = DateTime.now();
    if (!bypassCooldown &&
        _lastRegisterSessionCall != null &&
        _lastRegisterSessionUserId == userId) {
      final timeSinceLastCall = now.difference(_lastRegisterSessionCall!);
      if (timeSinceLastCall < _registerSessionCooldown) {
        debugPrint(
          '[BGSESSION] registerSession: Skipping - cooldown active (${timeSinceLastCall.inSeconds}s < ${_registerSessionCooldown.inSeconds}s)',
        );
        return false;
      }
    }

    try {
      _registerSessionInProgress = true;
      _lastRegisterSessionCall = now;
      _lastRegisterSessionUserId = userId;

      if (kDebugMode) {
        debugPrint(
          '[BGSESSION] registerSession: start platformOverride=$platform hasFcmTokenOverride=${(fcmToken ?? '').trim().isNotEmpty}',
        );
      }

      // Quick check: if there's no current session at all, the JWT will never
      // become available (e.g. refresh token expired, user logged out). Avoid
      // the 5-second polling wait and bail early.
      final currentSession = Supabase.instance.client.auth.currentSession;
      if (currentSession?.accessToken == null ||
          currentSession!.accessToken.isEmpty) {
        debugPrint(
          '[BGSESSION] registerSession: No session exists - skipping JWT wait (user likely logged out)',
        );
      } else {
        // Wait for JWT token to be available before proceeding
        final hasToken = await _waitForJwtToken();
        if (!hasToken) {
          debugPrint(
            '[BGSESSION] WARNING: Proceeding without JWT token, RPC may fail',
          );
        }
      }

      final info = await collectSessionInfo(
        platformOverride: platform,
        fcmTokenOverride: fcmToken,
        authMethodOverride: authMethod,
      );
      final params = <String, dynamic>{'p_user_id': userId};

      // Map the collected values to RPC param names expected by the function
      if (info['p_platform'] != null) {
        params['p_platform'] = info['p_platform'];
      }
      if (info['p_device_id'] != null) {
        params['p_device_id'] = info['p_device_id'];
      }
      if (info['p_device_model'] != null) {
        params['p_device_model'] = info['p_device_model'];
      }
      if (info['p_user_agent'] != null) {
        params['p_user_agent'] = info['p_user_agent'];
      }
      if (info['p_ip'] != null) {
        params['p_ip'] = info['p_ip'];
      }
      if (info['p_token_hash'] != null) {
        params['p_token_hash'] = info['p_token_hash'];
      }
      if (info['p_auth_method'] != null) {
        params['p_auth_method'] = info['p_auth_method'];
      }
      if (info['p_metadata'] != null) {
        params['p_metadata'] = info['p_metadata'];
      }
      params['p_mfa_verified'] = isCurrentSessionMfaVerified();
      // Country must be determined from GPS coordinates - no IP fallback (VPN can spoof IP)
      final normalizedCountry = countryOverride?.trim().toUpperCase();
      String? country =
          normalizedCountry != null && normalizedCountry.length == 2
          ? normalizedCountry
          : await _inferCountryCodeBestEffort(
              userId,
              latitude: latitude,
              longitude: longitude,
            );

      // GPS-based country is REQUIRED for map pin visibility, but session
      // registration (which keeps the online count in sync) must still
      // happen without it. The user will be "online" but not on the map.
      if (country == null || country.isEmpty) {
        debugPrint(
          '[BGSESSION] registerSession: Cannot determine country from GPS - registering session without country (online, but not on map)',
        );
      } else {
        params['p_country'] = country;
      }

      final platformText = (params['p_platform'] as String?)?.trim();
      if (platformText != null && platformText.isNotEmpty) {
        final deviceId = (info['p_device_id'] as String?)?.trim();
        params['p_id'] = await _getOrCreateSessionId(
          userId,
          platformText,
          deviceId: deviceId,
        );
      }

      final session = Supabase.instance.client.auth.currentSession;
      if (session?.accessToken == null || session!.accessToken.isEmpty) {
        debugPrint(
          '[BGSESSION] registerSession: No valid auth token - skipping registration (user likely logged out)',
        );
        return false;
      }
      final authedUserId = Supabase.instance.client.auth.currentUser?.id;
      if (authedUserId == null || authedUserId.isEmpty) {
        debugPrint(
          '[BGSESSION] registerSession: No authenticated user - skipping registration (user likely logged out)',
        );
        return false;
      }
      if (kDebugMode) {
        debugPrint(
          '[BGSESSION] registerSession: auth currentUser present hasSession=true',
        );
      }

      final rpcStart = DateTime.now();
      dynamic result;
      try {
        result = await Supabase.instance.client.rpc(
          'upsert_user_session',
          params: params,
        );
        debugPrint(
          '[BGSESSION] registerSession: upsert_user_session completed (elapsed=${DateTime.now().difference(rpcStart).inMilliseconds}ms)',
        );
      } catch (rpcError) {
        debugPrint(
          '[BGSESSION] registerSession: RPC failed, trying direct upsert: $rpcError',
        );

        // Fallback: Try direct upsert into user_session table
        try {
          final sessionId = params['p_id'] as String? ?? _uuid.v4();
          final deviceId = params['p_device_id'] as String?;
          final deviceIdTrimmed = deviceId?.trim();

          final upsertData = {
            'id': sessionId,
            'user_id': userId,
            'platform': params['p_platform'],
            'device_id': deviceIdTrimmed?.isNotEmpty == true
                ? deviceIdTrimmed
                : null,
            'device_model': params['p_device_model'],
            'user_agent': params['p_user_agent'],
            'ip': params['p_ip'],
            'country': params['p_country'],
            'auth_method': params['p_auth_method'],
            'mfa_verified': params['p_mfa_verified'],
            'metadata': params['p_metadata'],
            'created_at': DateTime.now().toIso8601String(),
            'last_active_at': DateTime.now().toIso8601String(),
          };

          // Remove null values to avoid constraint violations
          upsertData.removeWhere((key, value) => value == null);

          final existingSessionId = deviceIdTrimmed?.isNotEmpty == true
              ? await _findExistingSessionId(
                  userId,
                  params['p_platform'] as String? ?? '',
                  deviceIdTrimmed!,
                )
              : null;

          if (existingSessionId != null && existingSessionId.isNotEmpty) {
            final updateData = Map<String, dynamic>.from(upsertData)
              ..remove('id')
              ..remove('user_id')
              ..remove('platform')
              ..remove('device_id');
            updateData['last_active_at'] = DateTime.now().toIso8601String();
            updateData['revoked'] = false;
            updateData['revoked_at'] = null;
            updateData['logout_at'] = null;
            updateData['terminated_by'] = null;

            await Supabase.instance.client
                .from('user_session')
                .update(updateData)
                .eq('id', existingSessionId)
                .eq('user_id', userId);
            result = existingSessionId;
          } else {
            await Supabase.instance.client
                .from('user_session')
                .insert(upsertData);
            result = sessionId;
          }

          debugPrint('[BGSESSION] registerSession: Direct upsert completed');
        } catch (upsertError) {
          if (_isDuplicateSessionConstraintError(upsertError)) {
            final deviceId = (params['p_device_id'] as String?)?.trim();
            final platformValue =
                (params['p_platform'] as String?)?.trim() ?? '';
            final existingSessionId = deviceId != null && deviceId.isNotEmpty
                ? await _findExistingSessionId(userId, platformValue, deviceId)
                : null;
            if (existingSessionId != null && existingSessionId.isNotEmpty) {
              debugPrint(
                '[BGSESSION] registerSession: Recovered from duplicate session conflict by reusing existing id=$existingSessionId',
              );
              await Supabase.instance.client
                  .from('user_session')
                  .update({
                    'revoked': false,
                    'revoked_at': null,
                    'logout_at': null,
                    'terminated_by': null,
                    'last_active_at': DateTime.now().toIso8601String(),
                  })
                  .eq('id', existingSessionId)
                  .eq('user_id', userId);
              await _storeSessionId(
                userId,
                platformValue,
                existingSessionId,
                deviceId: deviceId,
              );
              result = existingSessionId;
            }
          }
          debugPrint(
            '[BGSESSION] registerSession: Direct upsert also failed: $upsertError',
          );
          rethrow; // Re-throw the original RPC error
        }
      }

      final platformKey = (params['p_platform'] as String?)?.trim();
      if (platformKey != null && platformKey.isNotEmpty) {
        final sessionId = (result as dynamic)?.toString().trim();
        if (sessionId != null &&
            sessionId.isNotEmpty &&
            _looksLikeUuid(sessionId)) {
          final deviceId = (params['p_device_id'] as String?)?.trim();
          await _storeSessionId(
            userId,
            platformKey,
            sessionId,
            deviceId: deviceId,
          );
        }
      }

      OfflineCacheManager.instance.setSupabaseAvailability(true);

      // Verify the session was actually created — look up by the specific
      // session ID returned from the RPC, not just the latest row by
      // created_at. Without this, a multi-platform user (e.g. web + Android)
      // could see the wrong platform in the log because the web session's
      // created_at was newer.
      var verifiedActiveSession = false;
      try {
        final returnedSessionId = (result as dynamic)?.toString().trim();
        final exists =
            returnedSessionId != null &&
                returnedSessionId.isNotEmpty &&
                _looksLikeUuid(returnedSessionId)
            ? await Supabase.instance.client
                  .from('user_session')
                  .select(
                    'id, platform, device_id, country, created_at, revoked',
                  )
                  .eq('id', returnedSessionId)
                  .eq('revoked', false)
                  .limit(1)
            : await Supabase.instance.client
                  .from('user_session')
                  .select(
                    'id, platform, device_id, country, created_at, revoked',
                  )
                  .eq('user_id', userId)
                  .eq('revoked', false)
                  .order('created_at', ascending: false)
                  .limit(1);

        if (exists.isNotEmpty) {
          verifiedActiveSession = true;
          final sessionData = exists[0];
          if (kDebugMode) {
            debugPrint(
              '[BGSESSION] registerSession: user_session verified - platform=${sessionData['platform']}',
            );
          }
        } else {
          debugPrint(
            '[BGSESSION] registerSession: WARNING - No user_session found after registration',
          );
        }
      } catch (e) {
        debugPrint(
          '[BGSESSION] registerSession: user_session verification failed: $e',
        );
        return false;
      }

      if (!verifiedActiveSession) {
        return false;
      }

      // Notify listeners (e.g. the dashboard stats provider) that this user
      // now has a live session so the online count is refreshed immediately.
      try {
        await onSessionRegistered?.call();
      } catch (_) {}
    } catch (e) {
      final errorMsg = e.toString();
      debugPrint('[BGSESSION] registerSession failed: $e');
      if (_isTransientSupabaseNetworkFailure(e)) {
        debugPrint(
          '[BGSESSION] registerSession: transient network failure (will retry later)',
        );
        return false;
      }
      if (e is PostgrestException) {
        debugPrint(
          '[BGSESSION] registerSession PostgrestException: code=${e.code} message=${e.message} details=${e.details} hint=${e.hint}',
        );
      }
      if (errorMsg.toLowerCase().contains('invalid jwt') ||
          errorMsg.toLowerCase().contains('unauthorized') ||
          errorMsg.toLowerCase().contains('401') ||
          errorMsg.toLowerCase().contains('403')) {
        debugPrint(
          '⚠️ [BGSESSION] registerSession failed due to auth error - session JWT may be invalid',
        );
      }
      // Re-throw the error so the caller knows it failed
      rethrow;
    } finally {
      _registerSessionInProgress = false;
    }

    return true;
  }

  static Future<void> syncCurrentSessionMfaVerified({bool? forceValue}) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final user = Supabase.instance.client.auth.currentUser;
      if (session == null || user == null) return;

      final platform = _detectPlatform();
      final deviceId = await _getDeviceIdFast();
      final sessionId = await _getStoredSessionId(
        user.id,
        platform,
        deviceId: deviceId,
      );
      if (sessionId == null || sessionId.isEmpty) return;

      await Supabase.instance.client
          .from('user_session')
          .update({'mfa_verified': forceValue ?? isCurrentSessionMfaVerified()})
          .eq('id', sessionId)
          .eq('user_id', user.id);
    } catch (_) {}
  }

  static Future<String> _getOrCreateSessionId(
    String userId,
    String platform, {
    String? deviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _sessionIdPrefsKey(userId, platform, deviceId: deviceId);
    final existing = prefs.getString(key)?.trim();
    if (existing != null && _looksLikeUuid(existing)) return existing;
    final generated = _uuid.v4();
    try {
      await prefs.setString(key, generated);
    } catch (_) {}
    return generated;
  }

  static bool _isDuplicateSessionConstraintError(Object error) {
    if (error is PostgrestException) {
      final code = error.code?.trim();
      final message = error.message.toLowerCase();
      if (code == '23505' &&
          message.contains('idx_user_session_user_platform_device_id_unique')) {
        return true;
      }
    }
    final text = error.toString().toLowerCase();
    return text.contains('23505') &&
        text.contains('idx_user_session_user_platform_device_id_unique');
  }

  static Future<String?> _findExistingSessionId(
    String userId,
    String platform,
    String deviceId,
  ) async {
    final normalizedPlatform = platform.trim();
    final normalizedDeviceId = deviceId.trim();
    if (userId.trim().isEmpty ||
        normalizedPlatform.isEmpty ||
        normalizedDeviceId.isEmpty) {
      return null;
    }

    try {
      final existing = await Supabase.instance.client
          .from('user_session')
          .select('id')
          .eq('user_id', userId)
          .eq('platform', normalizedPlatform)
          .eq('device_id', normalizedDeviceId)
          .order('last_active_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final id = existing?['id']?.toString().trim();
      return (id == null || id.isEmpty) ? null : id;
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeUuid(String v) {
    final s = v.trim();
    if (s.length != 36) return false;
    final ok = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return ok.hasMatch(s);
  }
}
