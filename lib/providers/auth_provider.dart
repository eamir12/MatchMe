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

  Future<void> runAccountExistenceCheck(String source, {bool force = false}) async {
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
      if (deleted) {
        accountExistenceChecked = true;
        await SessionService.signOutDeletedAccount(
          'Account deleted on server (probe source: $source)',
        );
      } else {
        // Inconclusive or confirmed alive: don't re-probe on every auth
        // event. The resume hook re-runs it after the next
        // offline → online transition.
        accountExistenceChecked = true;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AUTH] Account existence check failed (suppressed): $e');
      }
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
    try {
      final duration = await appConfigService.getForcedSignOutDuration();
      if (duration == Duration.zero) return;
      var createdAt = await SessionService.getSessionCreatedAt();
      if (createdAt == null) {
        // Legacy session from before the forced-sign-out timer existed, or
        // snapshot restored without a timestamp: start the timer now rather
        // than never enforcing the policy.
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
      unawaited(auth.signOut(scope: SignOutScope.local).catchError((_) {}));
    } catch (_) {}
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
      if (initialEventEmitted || disposed) return;

      initialEventEmitted = true;
      initialEventTimeout?.cancel();

      // Emit the current session state (cached locally)
      final currentSession = auth.currentSession;
      final currentUser = auth.currentUser;

      debugPrint(
        '🔄 [AUTH] Emitting initial auth state from cache (offline fallback) - session: ${currentSession != null}, user: ${currentUser != null}',
      );

      // Always emit an event, even if session is null
      // This unblocks the UI from the loading state
      controller.add(AuthState(AuthChangeEvent.initialSession, currentSession));
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
    // Deleted-account probe: skipped while offline, so re-arm it for when
    // connectivity returns — that may be the first chance this launch gets
    // to learn the account no longer exists.
    ref.onDispose(
      onSupabaseResume(() {
        if (disposed) return;
        if (!accountExistenceChecked) {
          unawaited(runAccountExistenceCheck('connectivityRestoredOfflineStart'));
        }
      }),
    );
    ref.onDispose(() => controller.close());
    unawaited(() async {
      try {
        if (auth.currentSession == null) {
          await SessionService.recoverPersistedSupabaseSession();
          controller.add(
            AuthState(AuthChangeEvent.initialSession, auth.currentSession),
          );
        }
      } catch (e) {
        controller.add(AuthState(AuthChangeEvent.initialSession, null));
      } finally {
        controller.close();
      }
    }());
    return controller.stream;
  }

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
        final recovered =
            await SessionService.recoverPersistedSupabaseSession();
        if (disposed) return;
        if (recovered && auth.currentSession != null) {
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
          unawaited(SessionService.clearPersistedSupabaseSessionSnapshot());
        } else {
          // POLICY: non-explicit signedOut events must NEVER log the user
          // out. The Supabase SDK fires signedOut on its own when its
          // background token refresh fails (expired access token after the
          // app was closed, or a refresh_token_already_used race with the
          // native background service which shares the single-use rotating
          // refresh token). The SDK clears the in-memory session before
          // firing. We restore the persisted session and re-emit it so the
          // UI stays logged in. Only auth.forced_sign_out_days or an
          // explicit UI logout may clear the session.
          if (auth.currentSession == null) {
            final recovered =
                await SessionService.recoverPersistedSupabaseSession(
                  timeout: const Duration(seconds: 3),
                );
            if (!disposed && recovered && auth.currentSession != null) {
              effectiveAuthState = AuthState(
                AuthChangeEvent.initialSession,
                auth.currentSession,
              );
              debugPrint(
                '🔄 [AUTH] Recovered session after non-explicit sign-out',
              );
            } else if (!disposed && auth.currentSession == null) {
              // Recovery failed (cooldown, dead refresh token, or attempted
              // within 10s of the previous try). Re-seed the last known
              // session offline WITHOUT network IO and stop auto-refresh to
              // break the refresh-fail → signedOut loop. The user stays
              // logged in with cached data.
              final offlineRestored =
                  await SessionService.restorePersistedSessionOfflineOnly();
              if (!disposed && offlineRestored && auth.currentSession != null) {
                effectiveAuthState = AuthState(
                  AuthChangeEvent.initialSession,
                  auth.currentSession,
                );
                debugPrint(
                  '🔄 [AUTH] Restored persisted session offline after non-explicit sign-out (staying logged in)',
                );
              } else if (!disposed && auth.currentSession == null) {
                // Only forward a null session when nothing is persisted
                // anywhere (genuinely logged out, e.g. fresh install). If a
                // snapshot exists we keep suppressing: emitting null here
                // would log the user out, violating the session policy.
                final hasPersisted =
                    await SessionService.hasAnyPersistedSession();
                if (!disposed && hasPersisted) {
                  debugPrint(
                    '🔄 [AUTH] Suppressing non-explicit sign-out — persisted snapshot exists, staying logged in until it can be re-seeded',
                  );
                  // Re-emit the signedOut as an initialSession with a null
                  // session would still route to AuthScreen, so instead hold
                  // the last event: skip emitting this signedOut entirely
                  // and wait for the offline restore / next SDK event.
                  // Mark handled by returning early without controller.add.
                  return;
                }
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
        unawaited(SessionService.setSessionCreatedAt());
      }

      if (effectiveAuthState.session != null &&
          effectiveAuthState.event == AuthChangeEvent.initialSession) {
        unawaited(checkForcedSignOut());
      }

      controller.add(effectiveAuthState);
    },
    onError: (Object error, StackTrace stackTrace) {
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
          final session = auth.currentSession;
          final user = auth.currentUser;
          controller.add(AuthState(AuthChangeEvent.initialSession, session));
          if ((user == null && session == null) && shouldLog) {
            debugPrint(
              '[AUTH] No cached session available, user will see unauthenticated state',
            );
          }
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
        final session = auth.currentSession;
        final user = auth.currentUser;
        controller.add(AuthState(AuthChangeEvent.initialSession, session));
        if (user == null && session == null) {
          debugPrint(
            '📋 [AUTH] No cached session available — user sees unauthenticated state',
          );
        }
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
      if (!accountExistenceChecked) {
        unawaited(runAccountExistenceCheck('connectivityRestored'));
      }
    }),
  );

  ref.onDispose(() {
    disposed = true;
    initialEventTimeout?.cancel();
    sub?.cancel();
    controller.close();
  });

  return controller.stream;
});
