// lib/providers/auth_provider.dart
// ...existing code...
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthUiMessageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setMessage(String? message) {
    // Force notification even when the payload matches the previous value.
    // Repeated OAuth failures can produce identical messages; Riverpod skips
    // listener updates when state is unchanged, which leaves the auth screen
    // stuck in a loading/disabled state.
    state = null;
    state = message;
  }

  void clear() {
    state = null;
  }
}

final authUiMessageProvider = NotifierProvider<AuthUiMessageNotifier, String?>(
  () {
    return AuthUiMessageNotifier();
  },
);

// This creates a stream that notifies the app when the auth state changes
final authStateProvider = StreamProvider<AuthState>((ref) {
  final controller = StreamController<AuthState>();
  final auth = Supabase.instance.client.auth;

  bool disposed = false;
  StreamSubscription<AuthState>? sub;
  bool validationInFlight = false;
  String? lastValidatedAccessToken;
  bool initialEventEmitted = false;
  bool initialEventLogged = false;
  bool initialEventFallbackInProgress = false;
  Timer? initialEventTimeout;
  DateTime? lastLanguageSyncScheduledAt;
  DateTime? lastOfflineFallbackLogAt;

  // A spent rotating refresh token makes the SDK fire signedOut for every
  // request that touches the expired session. Re-seeding the persisted
  // session immediately re-arms the same refresh storm, so offline restores
  // are rate-limited and a background retry probes for a token rotated by
  // the native background service in the meantime.
  DateTime? lastOfflineRestoreAt;
  const offlineRestoreCooldown = Duration(seconds: 30);
  Timer? sessionRecoveryRetryTimer;
  Duration sessionRecoveryRetryDelay = const Duration(minutes: 2);
  const maxSessionRecoveryRetryDelay = Duration(minutes: 15);

  // ---- Deleted-account detection -------------------------------------------
  // A device whose persisted session predates the account's deletion (admin
  // or self-delete on another device) recovers that session offline-only and
  // lands on the home screen, where every query fails. The permissive
  // session policy suppresses the SDK's signedOut events, so nothing would
  // ever clear the dead session. This probe asks the server once — at
  // startup and whenever connectivity is restored — whether the account
  // still exists, and performs a REAL sign-out (login screen) when it
  // doesn't. Ambiguous failures (offline, expired JWT, token-rotation race)
  // never sign out.
  bool accountExistenceChecked = false;
  DateTime? lastAccountExistenceCheckAt;

  // The `auth.forced_sign_out_days` policy is checked once per launch. It is
  // deliberately NOT tied to a specific SDK auth event: the duplicate
  // `initialSession` suppression below returns early for every SDK event
  // after the first one, which used to make the policy unreachable in
  // practice (the app only ever reached the login screen through accidents).
  bool forcedSignOutChecked = false;

  Future<void> runAccountExistenceCheck(
    String source, {
    bool force = false,
  }) async {
    if (disposed) return;
    final now = DateTime.now();
    if (lastAccountExistenceCheckAt != null &&
        now.difference(lastAccountExistenceCheckAt!) <
            const Duration(seconds: 60)) {
      return;
    }
    if (!force && accountExistenceChecked) return;
    if (auth.currentSession == null) return;
    // Only probe when we actually have a path to the server; offline use of
    // a cached session stays valid until connectivity returns (the
    // onSupabaseResume hook below re-runs the check then).
    if (!offlineCacheManager.isSupabaseAvailable) return;
    if (offlineCacheManager.shouldUseCachedData()) return;
    lastAccountExistenceCheckAt = now;
    try {
      final deleted = await SessionService.confirmAccountDeleted();
      if (disposed) return;
      if (deleted == true) {
        accountExistenceChecked = true;
        await SessionService.signOutDeletedAccount(
          'Account deleted on server (probe source: $source)',
        );
      } else if (deleted == false) {
        // Confirmed alive: don't re-probe on every auth event. The resume
        // hook re-runs it after the next offline → online transition.
        accountExistenceChecked = true;
      } else {
        // Inconclusive (network blip, expired JWT without a working existence
        // RPC, dead token). Keep the session and leave the probe re-armed.
        accountExistenceChecked = false;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AUTH] Account existence check failed (suppressed): $e');
      }
    }
  }

  late void Function() scheduleSessionRecoveryRetry;

  /// Probes the stored refresh tokens without resurrecting a dead session in
  /// memory. Only a successful rotation puts a session back and re-emits it;
  /// repeated failures back off up to [maxSessionRecoveryRetryDelay] instead
  /// of hammering the token endpoint.
  Future<void> retrySessionRecovery() async {
    if (disposed || auth.currentSession != null) return;
    // The family was proven dead: every stored copy is rejected server-side.
    // The re-login gate owns recovery; probing again only replays them.
    if (SessionService.deadSessionDetected.value) return;
    // Hold the ladder off while the probe is in flight: a failed refresh
    // makes the SDK emit signedOut, and the ladder must not re-seed the dead
    // session in the middle of the probe.
    lastOfflineRestoreAt = DateTime.now();
    RefreshTokenHealth health = RefreshTokenHealth.unknown;
    try {
      health = await SessionService.probeRefreshTokenHealth();
    } catch (_) {}
    if (disposed) return;
    if (health == RefreshTokenHealth.healthy && auth.currentSession != null) {
      lastOfflineRestoreAt = null;
      sessionRecoveryRetryDelay = const Duration(minutes: 2);
      debugPrint(
        '🔄 [AUTH] Session renewed by background retry after a spent refresh token',
      );
      controller.add(
        AuthState(AuthChangeEvent.tokenRefreshed, auth.currentSession),
      );
      return;
    }
    scheduleSessionRecoveryRetry();
  }

  scheduleSessionRecoveryRetry = () {
    if (disposed) return;
    // No point retrying a family the server has already revoked; the gate
    // stays up until the user signs in again.
    if (SessionService.deadSessionDetected.value) return;
    sessionRecoveryRetryTimer?.cancel();
    final delay = sessionRecoveryRetryDelay;
    sessionRecoveryRetryTimer = Timer(delay, () {
      if (disposed) return;
      unawaited(retrySessionRecovery());
    });
    final nextMinutes = (sessionRecoveryRetryDelay.inMinutes * 2)
        .clamp(2, maxSessionRecoveryRetryDelay.inMinutes)
        .toInt();
    sessionRecoveryRetryDelay = Duration(minutes: nextMinutes);
    debugPrint(
      '[AUTH] Scheduled session recovery retry in ${delay.inMinutes}m',
    );
  };

  void cancelSessionRecoveryRetry() {
    sessionRecoveryRetryTimer?.cancel();
    sessionRecoveryRetryTimer = null;
    sessionRecoveryRetryDelay = const Duration(minutes: 2);
  }

  /// When connectivity returns, try to renew a session that was only
  /// restored offline (expired access token, spent refresh token).
  ///
  /// The native background service rotates the refresh token on its own
  /// schedule, so by the time the network is back the newest stored token
  /// may be exchangeable again. This NEVER signs the user out: a failed
  /// renewal simply leaves the cached session in place.
  Future<void> tryRenewSessionOnResume() async {
    if (disposed) return;
    sessionRecoveryRetryTimer?.cancel();
    sessionRecoveryRetryTimer = null;
    sessionRecoveryRetryDelay = const Duration(minutes: 2);
    final wasMissing = auth.currentSession == null;
    if (wasMissing) {
      // A previous non-explicit sign-out may have left the SDK without a
      // session to break the refresh storm. Connectivity is back, so give
      // the persisted session another chance (the native background service
      // may have rotated the token while we were offline).
      lastOfflineRestoreAt = DateTime.now();
      try {
        await SessionService.restorePersistedSessionOfflineOnly();
      } catch (_) {}
      if (disposed) return;
    }
    final session = auth.currentSession;
    if (session == null) {
      unawaited(retrySessionRecovery());
      return;
    }
    if (!session.isExpired) {
      if (wasMissing) {
        controller.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
      }
      return;
    }
    try {
      final renewed = await SessionService.safeRefreshSession(
        timeout: const Duration(seconds: 8),
      );
      if (!disposed && renewed && auth.currentSession != null) {
        lastOfflineRestoreAt = null;
        controller.add(
          AuthState(AuthChangeEvent.tokenRefreshed, auth.currentSession),
        );
        debugPrint('🔄 [AUTH] Session renewed after connectivity was restored');
      } else if (!disposed) {
        scheduleSessionRecoveryRetry();
      }
    } catch (_) {
      // Keep the cached session — a failed renewal is never a logout.
      scheduleSessionRecoveryRetry();
    }
  }

  void syncLanguageForAuthenticatedSession() {
    if (!offlineCacheManager.isSupabaseAvailable) {
      if (kDebugMode) {
        debugPrint('[AUTH] Skipping language sync - Supabase offline');
      }
      return;
    }
    // Coalesce duplicate auth events (initialSession + signedIn + provider
    // rebuilds can all fire within the same second). The locale notifier
    // has its own cooldown, but that only helps after the 750ms delay —
    // this guard stops N delayed tasks from ever being scheduled.
    final now = DateTime.now();
    if (lastLanguageSyncScheduledAt != null &&
        now.difference(lastLanguageSyncScheduledAt!) <
            const Duration(seconds: 10)) {
      return;
    }
    lastLanguageSyncScheduledAt = now;
    try {
      // Defer past the first frame so the cold-start paint is not further
      // delayed. The language sync kicks off network IO (DB read + UPDATE +
      // smart retranslation pass) that is purely best-effort and not needed
      // for the UI to render.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 750), () async {
          if (!ref.mounted) return;
          // Re-check auth — the user may have been signed out in the
          // 750ms window (e.g. token refresh failure in bootstrap).
          if (auth.currentUser == null) return;
          final localization = ref.read(localizationProvider.notifier);
          // syncLanguageAfterLogin awaits whenInitialized internally, so the
          // push-to-DB only happens once _init has finished seeding the
          // cold-start locale (which now reads the user's saved DB
          // preference). This avoids the cold-start double-write race where
          // the device-locale fallback would otherwise clobber the DB.
          await localization.syncLanguageAfterLogin().catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            if (kDebugMode) {
              debugPrint('[AUTH] Language sync after auth failed: $error');
            }
          });
        }),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[AUTH] Failed to schedule language sync after auth: $error',
        );
      }
    }
  }

  void bestEffortSignOut(Object error) {
    // PERMISSIVE POLICY: do not auto-sign-out from auth errors.
    // The app should stay logged in until explicit user logout or forced
    // sign-out days. This function now only persists diagnostic info.
    try {
      unawaited(
        SessionService.persistSignOutReason(
          reason: error.toString(),
          source: 'bestEffortSignOut',
        ),
      );
    } catch (_) {}
  }

  bool isLikelyNetworkAuthError(Object error) {
    final msg = (error is AuthException) ? error.message : error.toString();
    final lower = msg.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('clientexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('software caused connection abort') ||
        lower.contains('timed out') ||
        lower.contains('authretryablefetchexception');
  }

  bool shouldSignOutForError(Object error) {
    if (isLikelyNetworkAuthError(error)) {
      return false;
    }

    // PERMISSIVE POLICY: never auto-sign-out on token/JWT errors.
    // Preserve the logged-in session for offline use and let the backend
    // enforce expiration. Only forced-sign-out days or an explicit user
    // action should clear the session locally.
    return false;
  }

  bool isPkceCodeVerifierError(Object error) {
    final msg = (error is AuthException) ? error.message : error.toString();
    return msg.toLowerCase().contains('code verifier could not be found');
  }

  void validateSessionBestEffort(AuthState authState) {
    if (validationInFlight) return;
    final session = authState.session;
    if (session == null) return;
    if (!offlineCacheManager.isSupabaseAvailable ||
        offlineCacheManager.shouldUseCachedData() ||
        SessionService.recoveredPersistedSessionThisLaunch) {
      return;
    }
    final token = session.accessToken.trim();
    if (token.isEmpty) return;
    if (token == lastValidatedAccessToken) return;

    validationInFlight = true;
    () async {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      final exp = session.expiresAt;
      if (exp != null && exp <= now + 30) {
        try {
          await SessionService.safeRefreshSession();
        } catch (_) {}
      }
      try {
        await auth.getUser();
        lastValidatedAccessToken = token;
      } catch (e) {
        if (disposed) return;
        if (shouldSignOutForError(e)) {
          lastValidatedAccessToken = null;
          bestEffortSignOut(e);
        }
      } finally {
        validationInFlight = false;
      }
    }();
  }

  Future<void> checkForcedSignOut() async {
    if (forcedSignOutChecked) return;
    // Nothing to sign out while there is no session. Do NOT mark the check as
    // done here: the policy must still be evaluated as soon as a session
    // exists, and the countdown must start from the session's creation, not
    // from the first app launch on a fresh install.
    if (auth.currentSession == null) return;
    forcedSignOutChecked = true;
    try {
      final duration = await appConfigService.getForcedSignOutDuration();
      if (duration == Duration.zero) return;
      var createdAt = await SessionService.getSessionCreatedAt();
      if (createdAt == null) {
        // Legacy session from before the forced-sign-out timer existed, or
        // snapshot restored without a timestamp: start the timer now rather
        // than never enforcing the policy. The timestamp is persisted, so the
        // countdown keeps running across launches instead of restarting.
        await SessionService.setSessionCreatedAt();
        createdAt = await SessionService.getSessionCreatedAt();
        if (createdAt == null) return;
      }
      if (DateTime.now().isBefore(createdAt.add(duration))) return;
      unawaited(
        SessionService.persistSignOutReason(
          reason: 'Forced sign-out after ${duration.inDays} days',
          source: 'forcedSignOutCheck',
        ),
      );
      SessionService.markExplicitUserSignOut();
      // Revoke only this device while the JWT is still valid. BackgroundService
      // stop is local-only, so doing this after signOut would run as `anon`.
      if (OfflineCacheManager.instance.isSupabaseAvailable) {
        try {
          await SessionService.logoutCurrentDevice(
            userId: auth.currentUser?.id,
          );
        } catch (_) {}
      }
      // The forced sign-out ends the session for good: drop the persisted
      // snapshot and the native credentials too, so the next launch starts
      // on the login screen.
      unawaited(SessionService.clearPersistedSupabaseSessionSnapshot());
      unawaited(auth.signOut(scope: SignOutScope.local).catchError((_) {}));
    } catch (_) {}
  }

  /// Emits the best session we can offer after an auth-stream error.
  ///
  /// A stream error is NOT a logout. If the SDK dropped its in-memory
  /// session (it does that whenever a refresh fails), the persisted snapshot
  /// is put back before anything is emitted — emitting a null session here
  /// would route the user to the login screen because of a network blip.
  ///
  /// Returns true when a state was emitted, false when the caller should
  /// keep the previous state (a session exists on disk but could not be
  /// restored, so nothing may be emitted yet).
  Future<bool> emitBestAvailableSession({required String logPrefix}) async {
    var session = auth.currentSession;
    if (session == null) {
      final now = DateTime.now();
      final cooldownActive =
          lastOfflineRestoreAt != null &&
          now.difference(lastOfflineRestoreAt!) < offlineRestoreCooldown;
      if (cooldownActive) {
        try {
          if (await SessionService.hasAnyPersistedSession()) {
            debugPrint(
              '$logPrefix — offline restore cooldown active; keeping the current state',
            );
            return false;
          }
        } catch (_) {}
      }
      lastOfflineRestoreAt = now;
      try {
        await SessionService.restorePersistedSessionOfflineOnly();
        session = auth.currentSession;
      } catch (_) {}
    }
    if (session == null) {
      try {
        final hasPersisted = await SessionService.hasAnyPersistedSession();
        if (hasPersisted) {
          debugPrint(
            '$logPrefix — a persisted session exists but could not be restored; keeping the current state instead of logging out',
          );
          return false;
        }
      } catch (_) {}
    }
    controller.add(AuthState(AuthChangeEvent.initialSession, session));
    if (session == null) {
      debugPrint(
        '$logPrefix — no session available, user will see the unauthenticated state',
      );
    }
    return true;
  }

  Future<void> emitInitialEvent() async {
    if (initialEventEmitted || disposed || initialEventFallbackInProgress) {
      return;
    }
    initialEventFallbackInProgress = true;
    try {
      if (auth.currentSession == null) {
        // Recovery reads the secure store / SharedPreferences and can block
        // on a stalled platform channel. It must never hold the splash: fall
        // through and emit whatever the SDK has in memory.
        try {
          await SessionService.recoverPersistedSupabaseSession().timeout(
            const Duration(milliseconds: 2500),
          );
        } catch (_) {}
      }
      if (auth.currentSession == null) {
        // Second chance, strictly offline: put the persisted session back
        // without any network IO.
        try {
          await SessionService.restorePersistedSessionOfflineOnly();
        } catch (_) {}
      }
      if (initialEventEmitted || disposed) return;

      initialEventEmitted = true;
      initialEventTimeout?.cancel();

      // Emit the current session state (cached locally)
      final currentSession = auth.currentSession;
      final currentUser = auth.currentUser;

      debugPrint(
        '🔄 [AUTH] Emitting initial auth state from cache (offline fallback) - session: ${currentSession != null}, user: ${currentUser != null}',
      );

      if (currentSession == null) {
        // The SDK can emit an `initialSession` with a null session before its
        // own storage restoration completes. Emitting null there routes the
        // user to the login screen even though this device still holds a
        // valid session, so double-check before giving up.
        try {
          final hasPersisted = await SessionService.hasAnyPersistedSession();
          if (hasPersisted && !disposed) {
            // A snapshot exists but could not be turned into a usable
            // session. Record why, but still unblock the UI: an endless
            // splash is worse than the login screen.
            unawaited(
              SessionService.persistSignOutReason(
                reason:
                    'A persisted session snapshot exists but could not be restored',
                source: 'emitInitialEvent',
              ),
            );
          }
        } catch (_) {}
      }

      // Always emit an event, even if session is null
      // This unblocks the UI from the loading state
      controller.add(AuthState(AuthChangeEvent.initialSession, currentSession));
      unawaited(checkForcedSignOut());
    } finally {
      initialEventFallbackInProgress = false;
    }
  }

  if (!offlineCacheManager.isSupabaseAvailable) {
    // Emit the cached session synchronously if already recovered by Supabase init,
    // so the StreamProvider delivers data on the very first frame instead of
    // showing the loader even briefly while the async fallback runs.
    if (auth.currentSession != null) {
      controller.add(
        AuthState(AuthChangeEvent.initialSession, auth.currentSession),
      );
    }
    // The `auth.forced_sign_out_days` policy is evaluated once per launch
    // (see [forcedSignOutChecked]).
    unawaited(checkForcedSignOut());
    // Deleted-account probe: skipped while offline, so re-arm it for when
    // connectivity returns — that may be the first chance this launch gets
    // to learn the account no longer exists.
    ref.onDispose(
      onSupabaseResume(() {
        if (disposed) return;
        // Re-run even if a previous probe was inconclusive or confirmed the
        // account alive: the account can be deleted while this device is
        // offline. The 60s throttle inside prevents storms.
        unawaited(
          runAccountExistenceCheck(
            'connectivityRestoredOfflineStart',
            force: true,
          ),
        );
      }),
    );
    // Even offline, an explicit user logout MUST route to the login screen.
    // The SDK clears the in-memory session synchronously on signOut() and then
    // fires `signedOut`; the online branch below is not active on this path, so
    // we observe the raw event and forward a null-session state. Non-explicit
    // signedOut events stay suppressed to honour the offline session policy.
    // This branch is selected once, at build time: the app may have started
    // while the backend was unreachable, but connectivity can return later in
    // the same session and the user can then sign in. Forward every
    // non-sign-out event that carries a session too — main.dart swaps the
    // tree only when this stream emits, so dropping `signedIn` leaves the
    // user stuck on the auth screen's full-screen loading state forever.
    sub = auth.onAuthStateChange.listen((authState) {
      if (disposed || controller.isClosed) return;
      if (authState.event == AuthChangeEvent.signedOut) {
        if (!SessionService.consumeExplicitUserSignOutFlag()) return;
        controller.add(AuthState(AuthChangeEvent.signedOut, null));
        return;
      }
      if (authState.session != null) {
        if (authState.event == AuthChangeEvent.signedIn) {
          // A new session invalidates any pending "the user signed out" flag
          // and re-arms recovery/policy probes for this account.
          SessionService.clearExplicitUserSignOutFlag();
          SessionService.enableRecovery();
          accountExistenceChecked = false;
          lastAccountExistenceCheckAt = null;
          // Do NOT re-run checkForcedSignOut here: setSessionCreatedAt() is
          // async, and a check racing it could read the PREVIOUS session's
          // timestamp and sign the new user out immediately. The next launch
          // evaluates the policy against the new timestamp.
          forcedSignOutChecked = false;
        }
        unawaited(SessionService.persistCurrentSupabaseSessionSnapshot());
        controller.add(authState);
      }
    });
    ref.onDispose(() {
      sub?.cancel();
      controller.close();
    });
    unawaited(() async {
      try {
        if (auth.currentSession == null) {
          await SessionService.recoverPersistedSupabaseSession();
          controller.add(
            AuthState(AuthChangeEvent.initialSession, auth.currentSession),
          );
        }
      } catch (e) {
        // Recovery threw (storage/channel failure). Try the strictly local
        // re-seed once more before accepting an unauthenticated state —
        // a thrown recovery must not turn into an auto-logout.
        try {
          await SessionService.restorePersistedSessionOfflineOnly();
        } catch (_) {}
        controller.add(
          AuthState(AuthChangeEvent.initialSession, auth.currentSession),
        );
      }
    }());
    return controller.stream;
  }

  // Ladder reentrancy guard: each failed refresh attempt inside the
  // non-explicit-signedOut ladder below makes the SDK emit yet another
  // `signedOut` event. That event re-enters this listener while the ladder
  // is still awaiting its own recovery/refresh steps (8s timeouts each), so
  // without this guard the ladders stack and multiply the refresh storm on
  // the same single-use token. The in-flight ladder owns the decision.
  var nonExplicitSignedOutLadderInFlight = false;

  sub = auth.onAuthStateChange.listen(
    (authState) async {
      if (disposed) return;

      AuthState effectiveAuthState = authState;

      // Replace null session with the in-memory cached session, but only for
      // non-signedOut events.  A signedOut event means the SDK intentionally
      // cleared the session (e.g. refresh_token_already_used), and resurrecting
      // it here keeps a dead session alive until the deferred validation kills
      // it — causing a confusing "Session recovered → immediately cleared" cycle.
      if (effectiveAuthState.session == null &&
          auth.currentSession != null &&
          authState.event != AuthChangeEvent.signedOut) {
        effectiveAuthState = AuthState(authState.event, auth.currentSession);
        debugPrint(
          '[AUTH] Replaced empty auth event session with current cached session',
        );
      }

      // Supabase can emit an immediate null initialSession before its own
      // storage restoration completes. Try our explicit offline recovery
      // before accepting that unauthenticated state.
      if (!initialEventEmitted &&
          authState.event == AuthChangeEvent.initialSession &&
          authState.session == null) {
        await SessionService.recoverPersistedSupabaseSession();
        if (disposed) return;
        if (auth.currentSession == null) {
          // Recovery suppresses itself for 10s after a recent attempt (to
          // break the SDK refresh-fail loop). Re-seed from disk without any
          // network IO before accepting an unauthenticated cold start.
          try {
            await SessionService.restorePersistedSessionOfflineOnly();
          } catch (_) {}
          if (disposed) return;
        }
        if (auth.currentSession != null) {
          effectiveAuthState = AuthState(
            AuthChangeEvent.initialSession,
            auth.currentSession,
          );
          debugPrint(
            '[AUTH] Replaced null initial session with recovered persisted session',
          );
        }
      }

      // Mark that we received an initial auth state.
      // Guard against duplicate initialSession events from the Supabase
      // SDK (can fire twice during cold start when session recovery and
      // subscription setup race).
      if (!initialEventEmitted) {
        initialEventEmitted = true;
        initialEventTimeout?.cancel();
        if (!initialEventLogged) {
          initialEventLogged = true;
          debugPrint('🔄 [AUTH] Stream emitted initial event');
        }
      } else if (authState.event == AuthChangeEvent.initialSession) {
        return; // suppress duplicate initialSession event
      }

      if (effectiveAuthState.event == AuthChangeEvent.signedOut) {
        if (SessionService.consumeExplicitUserSignOutFlag()) {
          lastOfflineRestoreAt = null;
          cancelSessionRecoveryRetry();
          unawaited(SessionService.clearPersistedSupabaseSessionSnapshot());
        } else {
          if (nonExplicitSignedOutLadderInFlight) {
            debugPrint(
              '🔄 [AUTH] Suppressing re-entrant non-explicit signedOut — ladder already in flight',
            );
            return;
          }
          nonExplicitSignedOutLadderInFlight = true;
          try {
            // POLICY (unchanged, now enforced): a non-explicit `signedOut`
            // event must NEVER log the user out. The Supabase SDK fires
            // signedOut on its own when its background token refresh fails
            // (expired access token after the app was closed, or a
            // refresh_token_already_used race with the native background
            // service, which shares the single-use rotating refresh token).
            // The SDK clears the in-memory session before firing. We restore
            // the persisted session and re-emit it so the UI stays logged in.
            //
            // The only legitimate automatic sign-outs are:
            //   * `auth.forced_sign_out_days` (app config) -> checkForcedSignOut
            //   * the account was deleted on the server -> runAccountExistenceCheck
            // A dead/revoked refresh token is NOT one of them: it proves only
            // that the session cannot be renewed, so the persisted session and
            // cached data stay in place.
            if (auth.currentSession == null) {
              final now = DateTime.now();
              final cooldownActive =
                  lastOfflineRestoreAt != null &&
                  now.difference(lastOfflineRestoreAt!) <
                      offlineRestoreCooldown;

              var recovered = false;
              if (!cooldownActive) {
                recovered =
                    await SessionService.recoverPersistedSupabaseSession(
                      timeout: const Duration(seconds: 3),
                    );
              }

              // Recovery may return false because its own cooldown is active
              // while a concurrent path (bootstrap safety net, background
              // service) restored the session in the meantime. Trust the
              // live session instead of the boolean, otherwise this ladder
              // emits a null session and briefly routes to the login screen.
              var restoredSession = auth.currentSession;

              if (!disposed && restoredSession == null && !cooldownActive) {
                lastOfflineRestoreAt = now;
                final offlineRestored =
                    await SessionService.restorePersistedSessionOfflineOnly();
                if (offlineRestored) restoredSession = auth.currentSession;
              }

              if (!disposed && restoredSession != null) {
                effectiveAuthState = AuthState(
                  AuthChangeEvent.initialSession,
                  restoredSession,
                );
                if (restoredSession.isExpired) {
                  // A refresh already failed for this session (that is why
                  // the SDK signed out), so re-seeding it is only a stopgap:
                  // keep the cooldown armed and retry the rotation later.
                  lastOfflineRestoreAt = now;
                  scheduleSessionRecoveryRetry();
                  debugPrint(
                    '🔄 [AUTH] Restored persisted session offline after non-explicit sign-out (staying logged in)',
                  );
                } else {
                  debugPrint(
                    recovered
                        ? '🔄 [AUTH] Recovered session after non-explicit sign-out'
                        : '🔄 [AUTH] Session restored concurrently after non-explicit sign-out',
                  );
                }
              }

              if (!disposed && auth.currentSession == null) {
                // Repeated refresh failures on a spent rotating token make
                // the SDK emit signedOut for every request that touches the
                // expired session. Re-seeding it again inside the cooldown
                // would only re-arm the same refresh storm, so stay on the
                // last known session and let connectivity/resume (or the
                // background retry) attempt a real renewal.
                if (cooldownActive) {
                  final hasPersisted =
                      await SessionService.hasAnyPersistedSession();
                  if (!disposed && hasPersisted) {
                    debugPrint(
                      '🔄 [AUTH] Suppressing repeated non-explicit sign-out — offline restore cooldown active (staying logged in)',
                    );
                    return;
                  }
                }

                // Nothing could be restored. Before routing to the login
                // screen, find out WHY: a rotation race (some other process
                // spent the token) or a revoked session family must never
                // log the user out. Only a genuinely empty device (fresh
                // install) may show the login screen; a deleted account is
                // detected separately by runAccountExistenceCheck.
                final health = await SessionService.probeRefreshTokenHealth();
                if (!disposed && health == RefreshTokenHealth.dead) {
                  // Every stored copy is unknown to the server: no rotation
                  // can ever succeed again. Block the app on the re-login
                  // gate instead of leaving a signed-in shell on screen.
                  unawaited(SessionService.markDeadSession());
                }
                if (!disposed && auth.currentSession != null) {
                  // The probe renewed the session (a stored copy of the
                  // refresh token still worked). Keep the user logged in.
                  lastOfflineRestoreAt = null;
                  sessionRecoveryRetryDelay = const Duration(minutes: 2);
                  effectiveAuthState = AuthState(
                    AuthChangeEvent.initialSession,
                    auth.currentSession,
                  );
                  debugPrint(
                    '🔄 [AUTH] Session renewed by the refresh-token probe — staying logged in',
                  );
                } else if (!disposed) {
                  final hasPersisted =
                      await SessionService.hasAnyPersistedSession();
                  if (!disposed && hasPersisted) {
                    debugPrint(
                      '🔄 [AUTH] Suppressing non-explicit sign-out (health=$health) — persisted snapshot exists, staying logged in',
                    );
                    scheduleSessionRecoveryRetry();
                    return;
                  }
                  debugPrint(
                    '🔄 [AUTH] Non-explicit sign-out with nothing persisted (health=$health) — routing to login',
                  );
                }
              }
            } else {
              effectiveAuthState = AuthState(
                AuthChangeEvent.initialSession,
                auth.currentSession,
              );
              debugPrint(
                '🔄 [AUTH] Suppressed non-explicit sign-out — keeping recovered session',
              );
            }
            // The SDK only fires signedOut on its own when its background
            // token refresh failed. Most causes are tolerated races, but an
            // account deleted on the server (admin or self-delete on another
            // device) produces the same event. Probe the server once so a
            // deleted account lands on the login screen instead of an
            // error-ridden home screen. Debounced inside the check.
            unawaited(
              Future<void>.delayed(const Duration(seconds: 2), () {
                runAccountExistenceCheck('nonExplicitSignedOut', force: true);
              }),
            );
          } finally {
            nonExplicitSignedOutLadderInFlight = false;
          }
        }
      } else if (effectiveAuthState.session != null) {
        unawaited(SessionService.persistCurrentSupabaseSessionSnapshot());
      }

      if (effectiveAuthState.event == AuthChangeEvent.initialSession ||
          effectiveAuthState.event == AuthChangeEvent.signedIn ||
          effectiveAuthState.event == AuthChangeEvent.tokenRefreshed) {
        validateSessionBestEffort(effectiveAuthState);
      }
      if ((effectiveAuthState.event == AuthChangeEvent.initialSession ||
              effectiveAuthState.event == AuthChangeEvent.signedIn) &&
          effectiveAuthState.session != null) {
        syncLanguageForAuthenticatedSession();
      }

      if (effectiveAuthState.event == AuthChangeEvent.signedIn &&
          effectiveAuthState.session != null) {
        // A new session invalidates any pending "the user signed out" flag:
        // from here on, a signedOut event is NOT the user's decision.
        SessionService.clearExplicitUserSignOutFlag();
        // A fresh sign-in mints a new refresh-token family: any dead-family
        // detection from the previous one is obsolete.
        unawaited(SessionService.clearDeadSessionState());
        lastOfflineRestoreAt = null;
        cancelSessionRecoveryRetry();
        // Recovery may have been disabled by the PREVIOUS session (forced
        // sign-out or deleted account). The new session must be recoverable
        // on the next launch, and the policy probes must be evaluated for
        // this account instead of inheriting the previous account's result.
        SessionService.enableRecovery();
        accountExistenceChecked = false;
        lastAccountExistenceCheckAt = null;
        // Do NOT re-run checkForcedSignOut here: setSessionCreatedAt() is
        // async, and a check racing it could read the PREVIOUS session's
        // timestamp and sign the new user out immediately. The next launch
        // evaluates the policy against the new timestamp.
        forcedSignOutChecked = false;
        unawaited(SessionService.setSessionCreatedAt());
        unawaited(
          Future<void>.delayed(const Duration(seconds: 2), () {
            runAccountExistenceCheck('signedIn', force: true);
          }),
        );
      }

      if (effectiveAuthState.session != null &&
          effectiveAuthState.event == AuthChangeEvent.initialSession) {
        unawaited(checkForcedSignOut());
      }

      controller.add(effectiveAuthState);
    },
    onError: (Object error, StackTrace stackTrace) async {
      if (disposed) return;

      if (isPkceCodeVerifierError(error)) {
        SharedPreferences.getInstance().then((prefs) {
          final pendingProvider =
              prefs.getString('pending_oauth_provider') ?? '';
          prefs.remove('pending_oauth_provider');
          try {
            ref
                .read(authUiMessageProvider.notifier)
                .setMessage(
                  'authOAuthProviderFailed|||$error|||$pendingProvider',
                );
          } catch (_) {}
        });
        return;
      }

      // Network errors during auth operations are non-fatal offline scenarios
      // Instead of crashing, emit cached session state.
      // NOTE: a single SocketException / Failed host lookup does NOT prove
      // the device is offline (transient DNS blip, VPN/Private-DNS, emulator
      // DNS, wifi handover). True offline is owned by
      // connectivityHealthProvider (transport + internet + backend probes).
      // So: stay silent-ish here, don't force the whole app offline on one
      // blip, and treat cached-session fallback as normal offline use.
      if (isLikelyNetworkAuthError(error)) {
        final now = DateTime.now();
        final shouldLog =
            lastOfflineFallbackLogAt == null ||
            now.difference(lastOfflineFallbackLogAt!) >
                const Duration(seconds: 30);
        if (shouldLog) {
          lastOfflineFallbackLogAt = now;
          debugPrint(
            '[AUTH] Offline mode - using cached session (auth refresh unreachable, will retry)',
          );
          if (kDebugMode) {
            debugPrint('[AUTH] Suppressed auth network error details: $error');
          }
        }
        // Non-force: lets OfflineCacheManager apply its 20s grace + 4-signal
        // guard instead of flipping the entire app offline on one DNS blip.
        offlineCacheManager.setSupabaseAvailability(false);
        try {
          await emitBestAvailableSession(
            logPrefix:
                '[AUTH] Offline mode - using cached session (auth refresh unreachable, will retry)',
          );
        } catch (e) {
          debugPrint('[AUTH] Failed to emit cached state: $e');
        }
        return;
      }

      // For all other auth stream errors, log and emit the cached session
      // instead of propagating the error to the UI. Propagating causes the
      // entire app to flip between AuthScreen and an error screen, making the
      // login form unusable (especially after a failed OAuth callback where
      // the SDK may emit transient errors).
      debugPrint('⚠️ [AUTH] Non-fatal auth stream error (suppressed): $error');
      try {
        await emitBestAvailableSession(
          logPrefix:
              '📋 [AUTH] Auth stream error — falling back to the cached session',
        );
      } catch (e) {
        debugPrint('❌ [AUTH] Failed to emit cached state after error: $e');
      }
    },
  );

  // Emit a cached session quickly if the auth stream stalls offline.
  initialEventTimeout = Timer(
    const Duration(seconds: 1),
    () => unawaited(emitInitialEvent()),
  );

  // WARM RELAUNCH FAST PATH: on a relaunch the SDK's real initialSession event
  // already fired *inside* Supabase.initialize() (which bootstrap awaited
  // before this provider was built) — and onAuthStateChange does not replay
  // past events. Without this, the provider would sit in loading until the
  // 1s [initialEventTimeout] fires, which is the whole "time to see Home".
  // The session is already recovered in memory, so emit it synchronously and
  // let the router resolve on the very first frame. The stream subscription
  // above still handles every subsequent (and any late) event; the dedup guard
  // suppresses a duplicate initialSession if the real one still arrives.
  if (!initialEventEmitted && auth.currentSession != null) {
    initialEventEmitted = true;
    initialEventLogged = true;
    initialEventTimeout.cancel();
    debugPrint(
      '🔄 [AUTH] Emitting recovered session synchronously on warm relaunch (skipping 1s wait)',
    );
    controller.add(
      AuthState(AuthChangeEvent.initialSession, auth.currentSession),
    );
  }

  // The `auth.forced_sign_out_days` policy is evaluated once per launch,
  // independently of the SDK's auth events (see [forcedSignOutChecked]).
  unawaited(checkForcedSignOut());

  // Deleted-account probe: shortly after startup (deferred so it never
  // delays the cold-start paint), and re-armed on every connectivity
  // restore — a cold start that began offline learns about a deleted
  // account the moment the device comes back online.
  Timer(const Duration(seconds: 5), () {
    if (disposed) return;
    unawaited(runAccountExistenceCheck('startup'));
  });
  ref.onDispose(
    onSupabaseResume(() {
      if (disposed) return;
      // The account may have been deleted while this device was offline, so
      // re-probe on every restore (the 60s throttle inside prevents storms).
      unawaited(runAccountExistenceCheck('connectivityRestored', force: true));
      // A session that was recovered offline (expired access token, spent
      // refresh token) can usually be renewed once the network is back:
      // the native background service may have rotated the token in the
      // meantime. Try again so the app returns to full online mode instead
      // of limping along with cached data.
      unawaited(tryRenewSessionOnResume());
    }),
  );

  ref.onDispose(() {
    disposed = true;
    initialEventTimeout?.cancel();
    sessionRecoveryRetryTimer?.cancel();
    sub?.cancel();
    controller.close();
  });

  return controller.stream;
});
