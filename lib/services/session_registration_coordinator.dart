import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matchme/services/session_service.dart';

/// Coalesces [SessionService.registerSession] during startup so bootstrap, FCM,
/// auth listener, and background service do not stack concurrent registrations.
class SessionRegistrationCoordinator {
  SessionRegistrationCoordinator._();

  static final SessionRegistrationCoordinator instance =
      SessionRegistrationCoordinator._();

  Timer? _debounceTimer;
  String? _pendingUserId;
  String? _pendingPlatform;
  String? _pendingFcmToken;
  bool _running = false;
  bool _registeredWithFcm = false;

  // Cold-start dedup: bootstrap + the auth-state `signedIn` listener + the
  // FCM getToken() call can all reach schedule() within a few hundred ms of
  // each other for the SAME user+platform. We coalesce those by keying on
  // (userId, platform) and short-circuiting repeated calls inside the window.
  // The FCM token is still merged into the pending state, so the eventual
  // single registerSession RPC carries it.
  String? _lastScheduledKey;
  DateTime? _lastScheduledAt;
  static const Duration _dedupWindow = Duration(seconds: 5);

  // Cold-start (bootstrap/FCM) registrations are debounced 5s to land past the
  // first-frame jank and to give the FCM getToken() call time to complete.
  // A fresh sign-in ('auth-signed-in') has no first-frame pressure — the user
  // is already interacting — so a short debounce makes the online count (and
  // session row) appear within ~1s instead of ~5s.
  static const Duration _coldStartDebounce = Duration(milliseconds: 5000);
  static const Duration _loginDebounce = Duration(milliseconds: 1000);

  void schedule({
    required String userId,
    String? platform,
    String? fcmToken,
    String source = 'unknown',
  }) {
    final uid = userId.trim();
    if (uid.isEmpty) return;

    // Always merge FCM into the pending state, even when we short-circuit
    // the timer reset — this is the path that lets the bootstrap call hand
    // off its FCM token to whichever call eventually runs.
    if (fcmToken != null && fcmToken.trim().isNotEmpty) {
      _pendingFcmToken = fcmToken.trim();
    }

    final effectivePlatform = (platform != null && platform.trim().isNotEmpty)
        ? platform.trim()
        : _pendingPlatform;
    final dedupKey = '$uid|${effectivePlatform ?? ''}';
    final now = DateTime.now();
    if (_lastScheduledKey == dedupKey &&
        _lastScheduledAt != null &&
        now.difference(_lastScheduledAt!) < _dedupWindow) {
      if (kDebugMode) {
        debugPrint(
          '[BGSESSION] coordinator: dedup schedule ($source) key=$dedupKey',
        );
      }
      return;
    }
    _lastScheduledKey = dedupKey;
    _lastScheduledAt = now;

    _pendingUserId = uid;
    if (platform != null && platform.trim().isNotEmpty) {
      _pendingPlatform = platform.trim();
    }

    // If registration is already running, don't start a new timer.
    // The running method's finally block picks up the FCM token.
    if (_running) {
      if (kDebugMode) {
        debugPrint(
          '[BGSESSION] coordinator: FCM captured during active registration ($source)',
        );
      }
      return;
    }

    _debounceTimer?.cancel();
    // Cold-start registrations (bootstrap/FCM) are deferred past the first
    // frame: the first call into collectSessionInfo() blocks the Android UI
    // thread for ~1.2 s (initial matchme/app_info method-channel +
    // DeviceInfoPlugin + Connectivity init, visible in the cold-start log as
    // a "Skipped 74 frames" / Davey 1241 ms right after the first frame).
    // 5 s moves the registration past the post-first-frame jank AND gives
    // the web FCM getToken() call (3-5 s end-to-end) time to land before the
    // first run, so the single RPC carries the token.
    // Fresh sign-ins ('auth-signed-in') have no first-frame pressure — the
    // user is already interacting — so a 1 s debounce makes the session row
    // (and thus the online count) appear ~4 s sooner.
    final debounce = source == 'auth-signed-in'
        ? _loginDebounce
        : _coldStartDebounce;
    _debounceTimer = Timer(debounce, () {
      unawaited(_runPending(source: source));
    });

    if (kDebugMode) {
      debugPrint('[BGSESSION] coordinator: scheduled ($source) userId=$uid');
    }
  }

  /// Force an immediate FCM/session resync, bypassing the cold-start dedup
  /// window and cooldown. Used for token refresh, app resume, boot recovery,
  /// and periodic refresh so killed/off/reboot gaps never leave a stale
  /// `user_session.metadata.fcm_token` on the server.
  void scheduleImmediate({
    required String userId,
    String? platform,
    String? fcmToken,
    String source = 'immediate',
  }) {
    final uid = userId.trim();
    if (uid.isEmpty) return;
    if (fcmToken != null && fcmToken.trim().isNotEmpty) {
      _pendingFcmToken = fcmToken.trim();
    }
    _pendingUserId = uid;
    if (platform != null && platform.trim().isNotEmpty) {
      _pendingPlatform = platform.trim();
    }
    // Break the dedup window so this run always executes.
    _lastScheduledKey = null;
    _lastScheduledAt = null;
    _debounceTimer?.cancel();
    if (_running) {
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        unawaited(_runPendingWithFcm());
      });
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(_runPending(source: source));
    });
    if (kDebugMode) {
      debugPrint(
        '[BGSESSION] coordinator: scheduled immediate ($source) userId=$uid',
      );
    }
  }

  Future<void> _runPending({required String source}) async {
    final userId = _pendingUserId;
    if (userId == null || userId.isEmpty) return;
    if (_running) {
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        unawaited(_runPending(source: source));
      });
      return;
    }

    _running = true;
    final platform = _pendingPlatform;
    final fcm = _pendingFcmToken;
    try {
      final registered = await SessionService.registerSession(
        userId,
        platform: platform,
        fcmToken: fcm,
      );
      if (registered && fcm != null && fcm.trim().isNotEmpty) {
        _registeredWithFcm = true;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[BGSESSION] coordinator run failed ($source): $e\n$st');
      }
    } finally {
      _running = false;
      if (fcm == null && _pendingFcmToken != null && !_registeredWithFcm) {
        if (kDebugMode) {
          debugPrint(
            '[BGSESSION] coordinator: FCM arrived post-registration, re-running with token',
          );
        }
        _debounceTimer?.cancel();
        _debounceTimer = Timer(const Duration(milliseconds: 200), () {
          unawaited(_runPendingWithFcm());
        });
      }
    }
  }

  Future<void> _runPendingWithFcm() async {
    final userId = _pendingUserId;
    final fcm = _pendingFcmToken;
    if (userId == null || fcm == null) return;
    _pendingFcmToken = null;
    _running = true;
    try {
      final registered = await SessionService.registerSession(
        userId,
        platform: _pendingPlatform,
        fcmToken: fcm,
        bypassCooldown: true,
      );
      _registeredWithFcm = registered;
    } catch (_) {
    } finally {
      _running = false;
    }
  }
}
