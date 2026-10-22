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
import 'package:matchme/services/runtime_supabase_config.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/services/sensitive_session_store.dart';
import 'package:matchme/services/supabase_reachability.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/windows_location_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:matchme/utils/offline_utils.dart';

/// Whether a refresh-token failure is a benign rotation race or a genuinely
/// dead session.
///
/// * [RefreshTokenHealth.healthy] — the token still works; the session can be
///   renewed and the user stays online.
/// * [RefreshTokenHealth.race] — `refresh_token_already_used`: another process
///   (the Android background service) already spent this token. Recoverable by
///   trying another stored copy; NEVER a reason to sign the user out.
/// * [RefreshTokenHealth.dead] — the server no longer knows this token
///   (`Invalid Refresh Token` / `refresh_token_not_found`). The session family
///   was revoked server-side. This is NOT proof that the account was deleted,
///   so it never signs the user out by itself: the app keeps the persisted
///   session and the cached data.
/// * [RefreshTokenHealth.unknown] — the probe could not reach the server.
enum RefreshTokenHealth { healthy, race, dead, unknown }

class SessionService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static const String _prefsFcmTokenKey = 'fcm_token';
  static const String _prefsWnsChannelKey = 'wns_channel_uri';
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

  /// Re-arms persisted-session recovery after a brand-new sign-in.
  ///
  /// [disableRecovery] is scoped to the session that was proven dead (forced
  /// sign-out or deleted account). A later sign-in creates a different
  /// session, and that one must be recoverable on the next launch.
  static void enableRecovery() {
    _recoveryDisabled = false;
    _recoveredPersistedSessionThisLaunch = false;
    _lastRecoveryAttempt = null;
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
        // NEVER delete the persisted snapshot here.
        //
        // The Supabase SDK clears its in-memory session whenever a refresh
        // fails (that is exactly what gotrue does for
        // `refresh_token_already_used` on an expired session). Deleting the
        // snapshot at that moment destroyed the only material the recovery
        // ladder had left, so `hasAnyPersistedSession()` then reported
        // "nothing persisted" and the app fell through to the login screen
        // even though the user had never logged out.
        //
        // Snapshots are removed ONLY by an explicit sign-out or a confirmed
        // account deletion (see [clearPersistedSupabaseSessionSnapshot]).
        debugPrint(
          '🔐 [SESSION] persist skipped: no in-memory session (snapshot kept for recovery)',
        );
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

  static DateTime? _explicitUserSignOutAt;

  static void markExplicitUserSignOut() {
    _explicitUserSignOutAt = DateTime.now();
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
    cancelStaleSessionRenewal();
  }

  /// Whether the current sign-out was the user's own decision.
  ///
  /// The flag is STICKY: it stays set until the next successful sign-in
  /// ([clearExplicitUserSignOutFlag]). Several listeners need to know "was
  /// this the user's decision?" — the auth router (does the app go to the
  /// login screen?), the native background service (may its credentials be
  /// wiped?) and the cache cleanup (may the user's offline data be erased?).
  /// A one-shot flag could only be read by one of them, and the readers run
  /// in an unspecified order.
  static bool consumeExplicitUserSignOutFlag() {
    return _explicitUserSignOutAt != null;
  }

  /// Same question as [consumeExplicitUserSignOutFlag], but explicitly
  /// non-destructive.
  static bool get isExplicitUserSignOutPending =>
      _explicitUserSignOutAt != null;

  /// Called when a new session is established: the previous sign-out (if any)
  /// is no longer relevant.
  static void clearExplicitUserSignOutFlag() {
    _explicitUserSignOutAt = null;
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

  /// Bookkeeping after a successful renew.
  ///
  /// * Restores the SDK's scheduled auto-refresh lifecycle: gotrue stops the
  ///   timer on every failed refresh (`stopAutoRefresh` in `_doRefresh`) and
  ///   offline restores keep it stopped by design — without this, the app
  ///   would rely on per-call lazy refreshes for the rest of the launch.
  /// * If the app is currently flagged offline, ping the restore
  ///   coordinator: a completed refresh is itself proof that Supabase is
  ///   reachable, so the offline→online transition must fire even if the
  ///   transport-probe state never changes.
  static void _onSessionRefreshSuccess() {
    try {
      Supabase.instance.client.auth.startAutoRefresh();
    } catch (_) {}
    try {
      if (shouldSkipSupabaseCalls()) {
        notifySupabaseResumed();
      }
    } catch (_) {}
  }

  /// Serialize refreshSession calls and handle `refresh_token_already_used`
  /// races where the native background service (Android/iOS) may have already
  /// rotated the token in `flutter.refresh_token`. On `already_used` we retry
  /// with every refresh-token copy this device knows about (the native
  /// encrypted store first — it holds the freshest rotated token), with
  /// exponential backoff.
  static Future<bool> safeRefreshSession({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    // If another refresh is already in flight, wait for it (with timeout).
    // Return the real state of the session: returning true just because a
    // session object still exists turned a failed refresh into a logged
    // "Token refreshed successfully" while the expired access token kept
    // being sent to the server (401 / RLS 42501 on every call).
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      try {
        await _refreshCompleter!.future.timeout(timeout);
      } catch (_) {}
      final joined = Supabase.instance.client.auth.currentSession;
      final usable = _isUsableSession(joined);
      if (!usable) {
        debugPrint(
          '🔐 [SESSION] safeRefresh: joined an in-flight refresh that did not renew the session',
        );
      }
      return usable;
    }

    _refreshCompleter = Completer<void>();
    try {
      // Never start a refresh while the app already knows Supabase is
      // unreachable. GoTrue retries AuthRetryableFetchException internally
      // for up to ~30s, surviving our own timeout; that orphaned retry can
      // outlive the outage and later spend a refresh token that another
      // refresher already rotated, producing `refresh_token_already_used`
      // and a server-side revocation of the session family.
      if (!offlineCacheManager.isSupabaseAvailable) {
        debugPrint(
          '🔐 [SESSION] safeRefresh skipped (Supabase marked offline)',
        );
        return false;
      }

      // Confirm the transport with the anon probe before spending the
      // single-use refresh token. Dead DNS fails in milliseconds here,
      // instead of starting GoTrue's long retry loop.
      if (!await _canReachSupabaseForRefresh()) {
        debugPrint(
          '🔐 [SESSION] safeRefresh skipped (Supabase probe unreachable)',
        );
        return false;
      }

      // Prefer the freshest refresh-token copy on the device. The native
      // background service rotates the token in the shared encrypted store
      // but cannot update Dart's in-memory session; if it refreshed first,
      // the in-memory token is already spent. Spending it again is what
      // GoTrue answers with `already_used` (and then revokes the session
      // family). Every Dart refresh dual-writes the native copy, so that
      // copy is at least as new as the in-memory one.
      var tokenToSpend =
          Supabase.instance.client.auth.currentSession?.refreshToken?.trim() ??
          '';
      try {
        final candidates = await SensitiveSessionStore.instance
            .readRefreshTokenCandidates();
        if (candidates.isNotEmpty) {
          final freshest = candidates.first.trim();
          if (freshest.isNotEmpty && freshest != tokenToSpend) {
            debugPrint(
              '🔐 [SESSION] safeRefresh: using the newer stored refresh token',
            );
            tokenToSpend = freshest;
          }
        }
      } catch (_) {}

      if (tokenToSpend.isEmpty) {
        debugPrint('🔐 [SESSION] safeRefresh: no refresh token available');
        return false;
      }

      // Remember the token we are about to spend so the retry below never
      // re-uses the very token the server just rejected.
      final tokenBeingSpent = tokenToSpend;
      try {
        _lastRefreshStopwatch.start();
        final response = await Supabase.instance.client.auth
            .refreshSession(tokenBeingSpent)
            .timeout(timeout);
        _lastRefreshStopwatch.stop();
        _alreadyUsedRetryCount = 0; // Reset on success
        await _adoptRotatedSession(response);
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

            // NOTE: the SDK drops the in-memory session when a refresh fails,
            // so `currentSession?.refreshToken` is EMPTY at this point and
            // cannot be used to detect "this is the token we just spent".
            // Compare against every copy we know about instead, and try them
            // all (native store first: the background service rotates the
            // token there, so that copy is the freshest one).
            final candidates = await SensitiveSessionStore.instance
                .readRefreshTokenCandidates();
            for (final candidate in candidates) {
              if (candidate.isEmpty) continue;
              if (candidate == tokenBeingSpent) continue;
              debugPrint(
                '🔐 [SESSION] safeRefresh: retrying with a stored refresh-token copy (attempt $_alreadyUsedRetryCount/$_maxAlreadyUsedRetries) after already_used',
              );
              try {
                final retryResponse = await Supabase.instance.client.auth
                    .refreshSession(candidate)
                    .timeout(timeout);
                await _adoptRotatedSession(retryResponse);
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
                _onSessionRefreshSuccess();
                return Supabase.instance.client.auth.currentSession != null;
              } catch (_) {
                // This copy is spent too - try the next one.
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
      _onSessionRefreshSuccess();
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

  /// True when [session] carries a non-empty, not-yet-expired access token.
  static bool _isUsableSession(Session? session) {
    if (session == null) return false;
    if (session.accessToken.trim().isEmpty) return false;
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return true;
    return expiresAt > DateTime.now().millisecondsSinceEpoch / 1000;
  }

  /// Adopt the session returned by a refresh when GoTrue discarded it.
  ///
  /// `_doRefresh` ignores its own result if the session was mutated while the
  /// network call was in flight (an offline restore/sign-out race). The
  /// server has still rotated the refresh token at that point; keeping the
  /// old in-memory token makes the NEXT refresh fail with
  /// `refresh_token_already_used` and tears the session down. `recoverSession`
  /// persists the successful response without spending another token.
  static Future<void> _adoptRotatedSession(AuthResponse response) async {
    final returned = response.session;
    if (returned == null) return;
    if (returned.accessToken.trim().isEmpty) return;
    // recoverSession() signs the user out locally when handed an expired
    // session; a session that just came back from the server cannot be, but
    // never risk it.
    if (returned.isExpired) return;
    final current = Supabase.instance.client.auth.currentSession;
    final alreadyApplied =
        current != null &&
        current.accessToken == returned.accessToken &&
        current.refreshToken == returned.refreshToken;
    if (alreadyApplied) return;
    // Never let a slow refresh overwrite a different account that signed in
    // while the network call was in flight.
    if (current != null && current.user.id != returned.user.id) return;
    try {
      await Supabase.instance.client.auth.recoverSession(
        jsonEncode(returned.toJson()),
      );
      debugPrint(
        '🔐 [SESSION] Adopted a rotated session the auth client had discarded',
      );
    } catch (e) {
      debugPrint('🔐 [SESSION] Failed to adopt rotated session: $e');
    }
  }

  /// Cheap anon reachability check before spending a rotating refresh token.
  ///
  /// Returns true when the probe cannot run at all (never block a refresh on
  /// probe infrastructure) and only false on a definitive "nothing answered"
  /// verdict.
  static Future<bool> _canReachSupabaseForRefresh() async {
    final url = (runtimeSupabaseUrl ?? '').trim();
    final key = (runtimeSupabaseAnonKey ?? '').trim();
    if (url.isEmpty || key.isEmpty) return true;
    try {
      final result = await probeSupabaseReachability(
        timeout: const Duration(seconds: 3),
      );
      return result.isReachable;
    } catch (_) {
      return true;
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

    // Native bridge first: a plain MethodChannel read with no Keychain/
    // Keystore round trip on the FlutterSecureStorage platform channel. The
    // snapshot is dual-stored there (see persistCurrentSupabaseSessionSnapshot),
    // so a warm relaunch resolves the session WITHOUT queueing behind other
    // FlutterSecureStorage consumers (notably the Hive encryption key read,
    // which races this seed at bootstrap). That contention previously stalled
    // the gather past its timeout and silently downgraded every warm launch
    // to the slow Supabase.initialize recovery path (seeded=false).
    try {
      add(await NativeSecureStore.getString(_prefsPersistedSupabaseSessionKey));
    } catch (_) {}

    // Only fall back to the Dart SecureStorage copy when the native bridge
    // has nothing: this read contends with every other secure-storage
    // consumer and costs ~0.85s on a cold Keystore.
    if (candidates.isEmpty) {
      try {
        add(
          await SecureStorageService.instance.read(
            _prefsPersistedSupabaseSessionKey,
          ),
        );
      } catch (_) {}
    }

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

  /// Definitive "this account no longer exists on the server" signatures.
  ///
  /// Deliberately narrow. A refresh-token failure NEVER proves the account
  /// was deleted: it only proves that THIS token can no longer be exchanged.
  /// Treating "invalid refresh token" as "account gone" made the app hard-sign
  /// the user out on a rotation race (the native background service had
  /// already spent the token), which is exactly the failure this policy is
  /// meant to prevent.
  ///
  /// Only the auth server's "this user does not exist" answers qualify.
  static bool isAccountGoneAuthError(Object error) {
    if (_isTransientSupabaseNetworkFailure(error)) return false;
    final text = error.toString().toLowerCase();

    // Token/session-level failures prove nothing about the account.
    if (text.contains('refresh_token') ||
        text.contains('refresh token') ||
        text.contains('invalid_grant') ||
        text.contains('already used') ||
        text.contains('session not found') ||
        text.contains('session missing') ||
        text.contains('authsessionmissing') ||
        text.contains('invalid jwt') ||
        text.contains('jwt expired') ||
        text.contains('jwt is expired') ||
        text.contains('token is expired') ||
        text.contains('invalid token') ||
        text.contains('unauthorized') ||
        text.contains('invalid claim')) {
      return false;
    }

    // Check the definitive signatures BEFORE any status-code heuristic.
    // GoTrue answers a deleted auth user with HTTP 403 + `user_not_found`
    // ("User from sub claim in JWT does not exist"); treating 403 as a
    // blanket exclusion made deletion detection silently fail.
    return text.contains('user from sub claim') ||
        text.contains('user_not_found') ||
        text.contains('user not found') ||
        text.contains('user does not exist');
  }

  /// Whether a refresh-token failure is a benign rotation race or a genuinely
  /// dead session.
  ///
  /// * [RefreshTokenHealth.healthy] — the token still works; the session can
  ///   be renewed and the user stays online.
  /// * [RefreshTokenHealth.race] — `refresh_token_already_used`: another
  ///   process (the Android background service) already spent this token.
  ///   Recoverable by trying another stored copy; NEVER a reason to sign out.
  /// * [RefreshTokenHealth.dead] — the server no longer knows this token
  ///   (`Invalid Refresh Token` / `refresh_token_not_found`). The session
  ///   family was revoked server-side. This is not proof of deletion and is
  ///   NEVER a reason to sign out: keep the persisted session and cached data.
  /// * [RefreshTokenHealth.unknown] — the probe could not reach the server.
  static Future<RefreshTokenHealth> probeRefreshTokenHealth() async {
    final auth = Supabase.instance.client.auth;
    final candidates = await SensitiveSessionStore.instance
        .readRefreshTokenCandidates();
    if (candidates.isEmpty) return RefreshTokenHealth.unknown;

    var sawRace = false;
    var sawDead = false;
    for (final candidate in candidates) {
      try {
        await auth
            .refreshSession(candidate)
            .timeout(const Duration(seconds: 8));
        // A refresh succeeded: the session family is alive.
        try {
          await persistCurrentSupabaseSessionSnapshot();
        } catch (_) {}
        _onSessionRefreshSuccess();
        return RefreshTokenHealth.healthy;
      } catch (e) {
        if (_isTransientSupabaseNetworkFailure(e)) {
          return RefreshTokenHealth.unknown;
        }
        final text = e.toString().toLowerCase();
        final isRace =
            text.contains('already used') ||
            text.contains('already_used') ||
            text.contains('refresh_token_already_used');
        final isDead =
            text.contains('refresh_token_not_found') ||
            text.contains('invalid refresh token') ||
            text.contains('refresh token not found') ||
            text.contains('invalid_grant');
        if (isRace) {
          // Another process spent this token. Ambiguous: another copy may
          // still work, so this must never lead to a sign-out.
          sawRace = true;
          continue;
        }
        if (isDead) {
          sawDead = true;
          continue;
        }
        return RefreshTokenHealth.unknown;
      }
    }
    // A race on ANY copy outranks a dead copy: "someone else spent this
    // token" is ambiguous, while "dead" only means the server does not know
    // this particular token any more. Only when every copy is dead (and
    // none of them was merely spent) is the session really over.
    if (sawRace) return RefreshTokenHealth.race;
    if (sawDead) return RefreshTokenHealth.dead;
    return RefreshTokenHealth.unknown;
  }

  /// Asks the server whether the currently signed-in account still exists.
  ///
  /// Returns [true] only for a definitive deletion, [false] when the account
  /// is confirmed alive, and [null] when the answer is ambiguous (offline,
  /// expired JWT that the SDK cannot refresh, dead refresh token). Ambiguous
  /// answers keep the user signed in and leave the probe re-armed.
  ///
  /// [Auth.getUser] does not refresh an expired access token: GoTrue rejects
  /// the JWT before looking up the account, so after a long offline period it
  /// can no longer distinguish a deleted account from a revoked session. The
  /// anonymous [account_exists] probe closes that gap without touching the
  /// user's rotating refresh token.
  static Future<bool?> confirmAccountDeleted() async {
    final auth = Supabase.instance.client.auth;
    final session = auth.currentSession;
    if (session == null) return null;
    final userId = session.user.id.trim();
    if (userId.isEmpty) return null;

    try {
      await auth.getUser().timeout(const Duration(seconds: 8));
      return false; // the account still exists
    } catch (e) {
      if (isAccountGoneAuthError(e)) {
        return true; // definitive: the auth user is gone
      }
    }

    // `getUser` failed for a non-definitive reason. If the backend still
    // serves the narrow existence RPC, use it: it works with an expired
    // access token and a refresh token that was deleted with the account.
    final exists = await _probeAccountExistsAnon(userId);
    return exists == false ? true : null;
  }

  /// Raw anon probe for the account-existence RPC.
  ///
  /// Returns [true]/[false] when the RPC answered, and [null] when it is
  /// unavailable (not deployed, old backend, offline, timeout). A missing RPC
  /// is deliberately treated as "unknown", never as "deleted".
  static Future<bool?> _probeAccountExistsAnon(String userId) async {
    if (userId.isEmpty) return null;
    final base = (runtimeSupabaseUrl ?? '').trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final anonKey = (runtimeSupabaseAnonKey ?? '').trim();
    if (base.isEmpty || anonKey.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$base/rest/v1/rpc/account_exists'),
            headers: <String, String>{
              'apikey': anonKey,
              'Authorization': 'Bearer $anonKey',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'cache-control': 'no-cache',
            },
            body: jsonEncode(<String, String>{'p_user_id': userId}),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is bool) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Clears every local trace of the deleted account and routes the UI to
  /// the login screen. Marks the sign-out explicit so the auth provider's
  /// non-explicit-signedOut suppression cannot resurrect the dead session.
  static Future<void> signOutDeletedAccount(String reason) async {
    debugPrint(
      '🔐 [SESSION] Account no longer exists on the server — signing out: '
      '$reason',
    );
    try {
      await persistSignOutReason(reason: reason, source: 'accountDeletedCheck');
    } catch (_) {}
    disableRecovery();
    markExplicitUserSignOut();
    await clearPersistedSupabaseSessionSnapshot();
    try {
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
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

        final sessionJson = _extractSupabaseSessionJson(raw);
        if (sessionJson == null) {
          continue;
        }

        // STEP 1 — restore OFFLINE first.
        //
        // `setInitialSession` performs no network I/O, so it can never make
        // the SDK sign the user out and it never deletes the SDK's own
        // persisted session. It puts the last known-good session back into
        // memory, which is all the permissive session policy needs to keep
        // the user logged in.
        var restored = false;
        try {
          await Supabase.instance.client.auth
              .setInitialSession(sessionJson)
              .timeout(const Duration(seconds: 2));
          restored = Supabase.instance.client.auth.currentSession != null;
        } catch (_) {}

        // STEP 2 — if the restored session is still usable we are done.
        if (restored) {
          final s = Supabase.instance.client.auth.currentSession;
          if (s != null && !s.isExpired) {
            _recoveredPersistedSessionThisLaunch = true;
            await persistCurrentSupabaseSessionSnapshot();
            debugPrint('🔐 [SESSION] Session recovered (still valid)');
            return true;
          }
        }

        // STEP 3 — the access token expired: ask the server for a fresh one.
        //
        // `recoverSession` is given the BARE session JSON. Passing our own
        // wrapper shape (`{"currentSession": {...}, "expiresAt": N}`) made
        // gotrue's `Session.fromJson` return null, and gotrue answers that
        // with `_signOut(scope: local)` — an extra spurious sign-out that
        // also wiped the SDK's persisted session, on every single recovery
        // attempt.
        try {
          await Supabase.instance.client.auth
              .recoverSession(sessionJson)
              .timeout(timeout);
        } catch (_) {
          // Offline, or the refresh token was already spent. The session
          // restored in step 1 stays in memory; the caller decides what to
          // do with it.
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

        scheduleStaleSessionRenewalIfNeeded();
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

  // ---------------------------------------------------------------------------
  // Scheduled renewal of a stale (expired) in-memory session.
  //
  // The SDK stops its auto-refresh timer whenever a refresh fails, and an
  // offline restore deliberately keeps it stopped to break refresh-fail
  // loops. Left alone, such a session is only renewed lazily by the next
  // Supabase call - and when that per-call refresh keeps failing (spent
  // refresh token, flagged-offline app), the app can sit on Home with a dead
  // session and failing calls indefinitely. This schedule actively runs
  // [safeRefreshSession], whose retry loop is the only path that consumes a
  // FRESH token copy from the native store (rotated by the background
  // service). It never signs the user out; declaring the session dead and
  // routing to the login screen remains the auth router's ladder decision.
  // ---------------------------------------------------------------------------

  static Timer? _staleSessionRenewalTimer;
  static bool _staleSessionRenewalInFlight = false;
  static int _staleSessionRenewalAttempts = 0;
  static DateTime? _staleSessionRenewalDisabledUntil;
  static const int _maxStaleSessionRenewalAttempts = 3;
  static const Duration _staleSessionRenewalRetryDelay = Duration(minutes: 2);
  static const Duration _staleSessionRenewalCooldown = Duration(minutes: 10);

  /// Arms one bounded bundle of renewal attempts ([_maxStaleSessionRenewalAttempts])
  /// when the in-memory session is expired. Re-arming while a bundle is
  /// running or inside the cooldown after give-up is a no-op, so re-entrant
  /// callers (the sign-out ladder on every SDK refresh failure) cannot turn
  /// this into an infinite refresh storm.
  static void scheduleStaleSessionRenewalIfNeeded() {
    try {
      final s = Supabase.instance.client.auth.currentSession;
      if (s == null || !s.isExpired) return;
    } catch (_) {
      return;
    }
    if (_staleSessionRenewalTimer != null) return;
    if (_staleSessionRenewalInFlight) return;
    final now = DateTime.now();
    if (_staleSessionRenewalDisabledUntil != null &&
        now.isBefore(_staleSessionRenewalDisabledUntil!)) {
      return;
    }
    _staleSessionRenewalAttempts = 0;
    _runStaleSessionRenewalAttempt();
  }

  static void _runStaleSessionRenewalAttempt() {
    _staleSessionRenewalTimer = Timer(
      _staleSessionRenewalAttempts == 0
          ? const Duration(seconds: 2)
          : _staleSessionRenewalRetryDelay,
      () async {
        _staleSessionRenewalTimer = null;
        try {
          final before = Supabase.instance.client.auth.currentSession;
          if (before == null || !before.isExpired) return;
          if (isExplicitUserSignOutPending) return;
          _staleSessionRenewalInFlight = true;
          try {
            await safeRefreshSession(timeout: const Duration(seconds: 8));
          } finally {
            _staleSessionRenewalInFlight = false;
          }
        } catch (_) {
          // A failed renewal is never a logout; the ladder keeps the user
          // signed in on the cached session.
        }
        bool stillStale = false;
        try {
          final after = Supabase.instance.client.auth.currentSession;
          stillStale = after != null && after.isExpired;
        } catch (_) {}
        if (stillStale &&
            ++_staleSessionRenewalAttempts < _maxStaleSessionRenewalAttempts) {
          _runStaleSessionRenewalAttempt();
          return;
        }
        if (stillStale) {
          // Give the policy a quiet period: either a future DB call, a
          // connectivity transition, or a later re-arm retries this again.
          // Keeps a definitively spent token from hammering the auth server.
          _staleSessionRenewalDisabledUntil = DateTime.now().add(
            _staleSessionRenewalCooldown,
          );
        }
      },
    );
  }

  static void cancelStaleSessionRenewal() {
    _staleSessionRenewalTimer?.cancel();
    _staleSessionRenewalTimer = null;
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
          // Keep the snapshot in sync with what we just restored so a later
          // launch has the same (or a fresher) session to fall back on.
          try {
            await persistCurrentSupabaseSessionSnapshot();
          } catch (_) {}
          scheduleStaleSessionRenewalIfNeeded();
          return true;
        }
      }
      scheduleStaleSessionRenewalIfNeeded();
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      scheduleStaleSessionRenewalIfNeeded();
      return Supabase.instance.client.auth.currentSession != null;
    }
  }

  /// Seeds the auth client from the locally persisted session WITHOUT any
  /// network IO. Used by the bootstrap fast path so a warm relaunch can route
  /// to the cached home without waiting for the full `Supabase.initialize()`
  /// (whose secure-storage reads + deep-link platform channels cost 1.4-2.3s
  /// on cold Keychain/Keystore access).
  ///
  /// Unlike [restorePersistedSessionOfflineOnly] this does NOT stop
  /// auto-refresh: the SDK's own initialize continues in the background and
  /// owns the normal refresh lifecycle once it completes.
  ///
  /// Returns true when a session is in memory afterwards. Never clears
  /// anything — the permissive session policy only ever seeds.
  static Future<bool> seedSessionFromLocalStorage({
    // Generous enough to survive the rare fallback where the native bridge
    // is empty and the FlutterSecureStorage read must run contended (~1.6s
    // cold Keystore behind another consumer). The common path resolves from
    // the native bridge in ~100ms, so this cap almost never binds.
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    try {
      if (Supabase.instance.client.auth.currentSession != null) return true;
      final candidates = await _gatherPersistedSessionCandidates().timeout(
        timeout,
      );
      for (final raw in candidates) {
        if (raw.isEmpty) continue;
        final sessionJson = _extractSupabaseSessionJson(raw);
        if (sessionJson == null) continue;
        try {
          await Supabase.instance.client.auth
              .setInitialSession(sessionJson)
              .timeout(const Duration(seconds: 1));
        } catch (_) {
          continue;
        }
        if (Supabase.instance.client.auth.currentSession != null) {
          _recoveredPersistedSessionThisLaunch = true;
          try {
            await persistCurrentSupabaseSessionSnapshot().timeout(
              const Duration(milliseconds: 500),
            );
          } catch (_) {}
          debugPrint(
            '🔐 [SESSION] Seeded session from local storage (bootstrap fast path)',
          );
          scheduleStaleSessionRenewalIfNeeded();
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

  static Future<String?> _getStoredWnsChannel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefsWnsChannelKey);
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
      // firebase_messaging 17: unregister() replaces deleteToken(). It removes
      // the Firebase Installation ID (FID) the backend targets so a logged-out
      // install stops receiving pushes. FCM then reports the FID as
      // unregistered, which the senders treat like an expired token.
      await FirebaseMessaging.instance.unregister();
    } catch (_) {}
  }

  static Future<void> deleteWnsChannel() async {
    // Logging out on Windows: drop the cached channel so the next session
    // re-registers. WNS has no client-side unregister API; the server prunes
    // the row via revoked/whatever session lifecycle. (Stale URIs keep
    // working server-side, matching FCM's UNREGISTERED cleanup.)
    await clearLocalWnsChannel();
  }

  static Future<void> clearLocalWnsChannel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsWnsChannelKey);
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

    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await Supabase.instance.client
          .from('user_session')
          .update({
            'revoked': true,
            'revoked_at': now,
            'logout_at': now,
            'terminated_by': 'user',
          })
          .eq('id', sessionId)
          .eq('user_id', uid);
    } catch (_) {}
  }

  /// Ends only THIS device's session.
  ///
  /// A user may be signed in on several devices at once. Logging out here must
  /// not revoke the other devices' sessions, mark the account offline, or clear
  /// its account-level pinned location while another device is still active.
  /// The server-side [logout_user_device] RPC revokes the matching session and
  /// only drops presence when no non-revoked session remains.
  ///
  /// Returns TRUE when at least one other device session is still active.
  static Future<bool> logoutCurrentDevice({
    String? userId,
    bool clearPinnedLocation = true,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final uid = (userId ?? Supabase.instance.client.auth.currentUser?.id)
        ?.trim();
    if (uid == null || uid.isEmpty) return false;

    final platform = _detectPlatform();
    final deviceId = await _getDeviceIdFast();
    var sessionId = await _getStoredSessionId(
      uid,
      platform,
      deviceId: deviceId,
    );
    if (sessionId == null && deviceId != null && deviceId.trim().isNotEmpty) {
      sessionId = await _findExistingSessionId(uid, platform, deviceId);
    }

    // The caller may have begun this work before signOut but reached the RPC
    // only after auth was cleared. Running then would execute as `anon` and
    // fail with 42501, leaving a stale session. Skip instead.
    final client = Supabase.instance.client;
    if (client.auth.currentSession == null ||
        client.auth.currentUser?.id != uid) {
      debugPrint('[SESSION] logout_user_device skipped: auth session changed');
      await _clearStoredSessionId(uid, platform, deviceId: deviceId);
      return false;
    }

    var remainsOnline = false;
    try {
      final result = await client
          .rpc(
            'logout_user_device',
            params: {
              'p_user_id': uid,
              'p_session_id': sessionId,
              'p_platform': platform,
              'p_device_id': deviceId,
              'p_clear_pinned': clearPinnedLocation,
            },
          )
          .timeout(timeout);
      remainsOnline = result == true || result?.toString() == 'true';
    } catch (e) {
      // Do NOT fall back to direct table writes or set_user_offline here.
      // This call is only valid while the user JWT is still active; a timeout
      // or failure must not keep running after auth.signOut(), where it would
      // execute as `anon` and either fail noisily or leave a stale session.
      debugPrint('[SESSION] logout_user_device failed: $e');
    } finally {
      await _clearStoredSessionId(uid, platform, deviceId: deviceId);
    }

    return remainsOnline;
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
    if (uid != null && uid.isNotEmpty) {
      await logoutCurrentDevice(userId: uid);
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
    // Windows WNS channel (MSIX): registered by WindowsPushChannelService on
    // app start; server prunes stale URIs and clears pruned state via the
    // clear_user_session_wns_channel RPC.
    if (platformText == 'windows') {
      final wnsChannel = await _getStoredWnsChannel();
      if (wnsChannel != null && wnsChannel.startsWith('https://')) {
        metadata['wns_channel_uri'] = wnsChannel;
        metadata['wns_channel_uri_updated_at'] = DateTime.now()
            .toIso8601String();
      }
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
      final permission = await WindowsLocationChannel.checkPermission();
      final granted =
          permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      if (!granted) return null;

      final pos = await WindowsLocationChannel.getPosition(
        accuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 4),
      );
      if (pos == null) return null;
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
