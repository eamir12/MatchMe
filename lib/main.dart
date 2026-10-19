// lib/main.dart
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/firebase_options.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart'
    show
        debugPrint,
        FlutterExceptionHandler,
        TargetPlatform,
        defaultTargetPlatform,
        kDebugMode,
        kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/screens/auth/auth_screen.dart';
import 'package:matchme/screens/auth/profile_check_screen.dart';
import 'package:matchme/screens/settings/notifications_settings_screen.dart';
import 'package:matchme/screens/notifications/notification_inbox_screen.dart';
import 'package:matchme/screens/settings/matching_settings_screen.dart';
import 'package:matchme/screens/settings/security_center_screen.dart';
import 'package:matchme/screens/settings/settings_screen.dart';
import 'package:matchme/screens/subscription/subscription_payment_screen.dart';
import 'package:matchme/services/secure_local_storage.dart';
import 'package:matchme/services/ad_platform_support.dart';
import 'package:matchme/services/outbox_sync_service.dart';
import 'package:matchme/services/runtime_supabase_config.dart';
import 'package:matchme/services/sensitive_session_store.dart';
import 'package:matchme/services/auth_transition_guard.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/services/chat_view_state_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/local_db_service.dart'; // Added for explicit init
import 'package:matchme/services/map_tile_cache_service.dart';
import 'package:matchme/services/offline_trail_service.dart';
import 'package:matchme/services/storage_helper.dart'; // Persisted photo URL warmup
import 'package:matchme/services/startup_cache_warmer.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/encrypted_cache_service.dart';
import 'package:matchme/providers/chat_key_provider.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/offline_cache_manager.dart'; // Added for offline support
import 'package:matchme/services/network_availability.dart';
import 'package:matchme/services/supabase_reachability.dart';
import 'package:matchme/services/offline_mutation_queue.dart'; // Added for offline mutations
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/services/session_registration_coordinator.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/windows_push_channel_service.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/app_info_service.dart';
import 'package:matchme/services/outlook_web_auth.dart'
    if (dart.library.io) 'package:matchme/services/outlook_web_auth_stub.dart';
import 'package:matchme/services/platform_trace_logger.dart';
import 'package:matchme/utils/permission_helper.dart';
import 'package:matchme/utils/permission_coordinator.dart';
import 'package:matchme/utils/permission_manager.dart';
import 'package:matchme/utils/resume_route_restore.dart';
import 'package:matchme/utils/time_of_day_ranges.dart';
import 'package:quick_actions/quick_actions.dart';
// (flutter/services.dart already imported above)

import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/icon_badge_provider.dart';
import 'package:matchme/providers/chat_provider.dart'
    show
        clearUserScopedChatMemoryCaches,
        pendingMessageTranslationProvider,
        migrateLegacyTranslationPrefs;
import 'package:matchme/providers/match_notification_provider.dart'
    show matchNotificationProvider;
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/utils/app_shortcuts.dart';
import 'package:matchme/web_imports.dart' as html;
import 'package:matchme/services/referral_service.dart';
import 'package:matchme/services/admin_broadcast_service.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/widgets/startup_loader.dart';
import 'package:matchme/widgets/birthday_overlay.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
// ignore: unnecessary_import - Kept for compatibility with other files that depend on it
import 'package:matchme/services/mobile_local_notification_service.dart';
import 'package:matchme/services/encrypted_notification_preview_service.dart';
import 'package:matchme/services/expiry_local_schedule_service.dart';
import 'package:matchme/services/app_badge_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/widgets/safe_text.dart';

final container = ProviderContainer();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// MainActivity (Android) can deliver notification taps while the app is running.
// If we receive one before Navigator is ready, keep it here and replay post-frame.
String? _pendingNotificationRoute;
bool _fcmHandlersInstalled = false;
Timer? _fcmResyncTimer;

late final Future<_BootstrapInitResult> _bootstrapInitFuture;
bool _webFrameKickShutdown = false;
bool _webFrameKickInstalled = false;
Timer? _webWarmupTimer;
DateTime? _webWarmupStartedAt;
bool _webWarmupShutdown = false;
bool _webWarmupInstalled = false;
FlutterExceptionHandler? _webWarmupPrevFlutterErrorHandler;
final Set<String> _oauthCodesInFlight = <String>{};
String? _lastHandledOAuthCode;
bool _timezonesInitialized = false;

void _ensureTimezonesInitialized() {
  if (_timezonesInitialized) return;
  tz_data.initializeTimeZones();
  _timezonesInitialized = true;
}

bool _isUsersBirthdayToday({
  required DateTime? dateOfBirth,
  required String? userTimezone,
}) {
  if (dateOfBirth == null) return false;

  DateTime localNow;
  final timezoneName = (userTimezone ?? '').trim();
  if (timezoneName.isNotEmpty) {
    try {
      final location = tz.getLocation(timezoneName);
      localNow = tz.TZDateTime.from(DateTime.now().toUtc(), location);
    } catch (_) {
      localNow = DateTime.now();
    }
  } else {
    localNow = DateTime.now();
  }

  return localNow.month == dateOfBirth.month && localNow.day == dateOfBirth.day;
}

void _reportNonFatal(Object error, StackTrace stackTrace) {
  FlutterError.reportError(
    FlutterErrorDetails(exception: error, stack: stackTrace),
  );
}

bool _isIgnorableWebSocketError(Object error) {
  if (!kIsWeb) return false;
  final message = error.toString().toLowerCase();
  return message.contains('websocketchannelexception') &&
      message.contains('websocket connection failed');
}

bool _shouldConnectRealtime() {
  final auth = Supabase.instance.client.auth;
  return auth.currentSession != null && auth.currentUser != null;
}

bool _isIgnorableRealtimePresenceError(Object error, StackTrace stack) {
  final message = error.toString().toLowerCase();
  final stackText = stack.toString().toLowerCase();
  return message.contains("type 'null' is not a subtype of type 'string'") &&
      stackText.contains('realtime_presence.dart');
}

// Supabase GoTrue auto-recovers the persisted session during Supabase.initialize()
// via CancelableCompleter.complete, which can rethrow AuthApiException into the
// root zone even though our auth listener's onError would normally handle it.
// The auth state stream's own onError handler treats these as "sign out" events,
// so once the SDK tears the local session down the user is correctly routed to
// AuthScreen — we just don't want the original rethrow to surface as an
// Unhandled Exception (which in debug mode triggers a Flutter engine restart
// and re-runs the entire bootstrap, doubling the geolocator engine-connect
// count and producing the duplicate "Cleared all persisted auth data" log
// observed in the cold-start trace).
bool _isIgnorableAuthRecoveryError(Object error, StackTrace stack) {
  if (error is AuthException) return true;
  final message = error.toString().toLowerCase();
  final stackText = stack.toString().toLowerCase();
  final isSupabaseAuthStack =
      stackText.contains('gotrue/src') ||
      stackText.contains('supabase_flutter/src') ||
      stackText.contains('supabase/src');
  if (!isSupabaseAuthStack) return false;
  return message.contains('invalid refresh token') ||
      message.contains('refresh_token_already_used') ||
      message.contains('refresh_token_not_found') ||
      message.contains('already used') ||
      message.contains('auth session missing') ||
      message.contains('authsessionmissing') ||
      message.contains('invalid jwt') ||
      message.contains('jwt expired') ||
      message.contains('token is expired');
}

/// Checks if an AuthException is specifically an OAuth code exchange failure.
/// These occur when the Supabase ↔ provider configuration is incomplete (e.g.
/// Azure AD not fully set up) and are not actionable by the user mid-flow —
/// the app should show a user-friendly message and let them retry or choose
/// another provider instead of logging a scary DartError.
bool _isOAuthCodeExchangeError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('unable to exchange external code') ||
      message.contains('unable to exchange code') ||
      (message.contains('oauth') &&
          message.contains('exchange') &&
          message.contains('code')) ||
      (message.contains('external') &&
          message.contains('code') &&
          message.contains('exchange'));
}

/// Zone-level guard that catches unhandled async errors not reaching
/// PlatformDispatcher.onError (dart2js zone path).
bool _suppressUnhandledError(Object error, StackTrace stack) {
  if (_isIgnorableAuthRecoveryError(error, stack)) {
    debugPrint('🔐 [AUTH] Zone guard suppressing auth-recovery error: $error');
    return true;
  }
  if (_isOAuthCodeExchangeError(error)) {
    debugPrint(
      '🔐 [AUTH] Zone guard suppressing OAuth code exchange error: $error',
    );
    return true;
  }
  if (_isIgnorableWebSocketError(error)) {
    return true;
  }
  if (_isIgnorableRealtimePresenceError(error, stack)) {
    debugPrint('Ignoring known realtime presence null-cast error: $error');
    return true;
  }
  if (_isIgnorableConnectivityStreamError(error)) {
    return true;
  }
  return false;
}

/// On Windows, connectivity_plus's NetworkManager::StartListen can fail with
/// E_INVALIDARG (-2147024809) when the platform thread is inside certain
/// input-synchronous windows (COM rejects the outgoing Advise). The Dart
/// framework surfaces that as a PlatformException thrown during stream
/// activation, which — with no error handler — becomes an uncaught
/// exception that crashes the app. Connectivity is non-critical: the
/// monitor probes real reachability over HTTP on its own timer, so a failed
/// event stream just means we lose change notifications.
bool _isIgnorableConnectivityStreamError(Object error) {
  if (!Platform.isWindows) return false;
  final message = error.toString().toLowerCase();
  return message.contains('platformexception') &&
      (message.contains('-2147024809') ||
          message.contains('networkmanager::startlisten') ||
          message.contains('e_invalidarg'));
}

void main() {
  // bindings + runApp MUST share the same zone. Using runZonedGuarded
  // to catch unhandled async exceptions that would otherwise bypass
  // PlatformDispatcher.onError (dart2js root-zone path).
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      ChatKeyService.instance.attachLifecycleObserver();
      _mainSync();
    },
    (error, stack) {
      // Last-resort zone guard. Catches errors that escape through the
      // dart2js microtask loop without being caught by any Future catch.
      if (!_suppressUnhandledError(error, stack)) {
        debugPrint('Unhandled error in zone: $error');
      }
    },
  );
}

void _mainSync() {
  _ensureTimezonesInitialized();
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }
  // Increase buffer size for flutter/lifecycle to avoid "discarded before it could be handled" warnings on Web
  ServicesBinding.instance.channelBuffers.resize('flutter/lifecycle', 20);

  AdminBroadcastService.setProviderContainer(container);
  AdminBroadcastService.setAppInForeground(true);
  MobileLocalNotificationService.setProviderContainer(container);
  WebNotificationService.setProviderContainer(container);
  EncryptedNotificationPreviewService.setProviderContainer(container);
  VoiceGuidanceService.setProviderContainer(container);
  print('[BOOTSTRAP] Initializing VoiceGuidanceService...');
  unawaited(VoiceGuidanceService.instance.loadEnabledFromPrefs());
  PlatformDispatcher.instance.onError = (error, stack) {
    print('[STARTUP_DIAG] platform_error type=${error.runtimeType}');
    // PlatformDispatcher runs AFTER the zone guard, so errors caught here
    // are ones that escaped the zone guard AND are non-ignorable.
    // Still check our suppression patterns as a safety net.
    if (_suppressUnhandledError(error, stack)) return true;
    return false;
  };

  // Second safety net: FlutterError.onError catches errors that surface via
  // the framework's error reporter (including the "Unhandled Exception" lines
  // emitted by dart_vm_initializer when an unhandled async error escapes the
  // current zone). Without this, Supabase GoTrue's internal recoverSession()
  // can rethrow an AuthApiException from inside a CancelableCompleter
  // callback, which PlatformDispatcher.onError sometimes does not see
  // depending on the zone the throw originates in.
  final prevFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final error = details.exception;
    final stack = details.stack ?? StackTrace.current;
    print(
      '[STARTUP_DIAG] flutter_error '
      'type=${error.runtimeType} '
      'library=${details.library ?? "unknown"} '
      'context=${details.context?.toDescription() ?? "unknown"}',
    );
    if (_suppressUnhandledError(error, stack)) return;
    if (_isIgnorableWebSocketError(error)) {
      return;
    }
    prevFlutterErrorHandler?.call(details);
    FlutterError.presentError(details);
  };
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null) return;
    final lower = message.toLowerCase();
    if (!lower.contains('translation') &&
        !lower.contains('l10n') &&
        !lower.contains('missing message') &&
        !lower.contains('missing translation') &&
        !lower.contains('calendarsync') &&
        !lower.contains('resume-diag') &&
        !lower.contains('bootstrap') &&
        !lower.contains('maptiles') &&
        !lower.contains('hivecrypto') &&
        !lower.contains('profileedit') &&
        !lower.contains('matchmeapp') &&
        !lower.contains('[settings]') &&
        !lower.contains('profilesyncservice') &&
        !lower.contains('cache_warm') &&
        !lower.contains('connectivity')) {
      return;
    }
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };
  ResumeDiagnostics.setEnabled(kDebugMode);
  ResumeDiagnostics.log('main() started');

  _resetNativeAdState();
  _installWebVisibilityFrameKick();

  _bootstrapInitFuture = _bootstrapInitialize(container);
  runApp(_BootstrapApp(container: container, initFuture: _bootstrapInitFuture));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    print(
      '[STARTUP_DIAG] first_root_frame '
      'at=${DateTime.now().millisecondsSinceEpoch}',
    );
  });
  void logFirstFrameTiming(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    SchedulerBinding.instance.removeTimingsCallback(logFirstFrameTiming);
    final timing = timings.first;
    print(
      '[STARTUP_DIAG] first_frame_timing '
      'buildUs=${timing.buildDuration.inMicroseconds} '
      'rasterUs=${timing.rasterDuration.inMicroseconds}',
    );
  }

  SchedulerBinding.instance.addTimingsCallback(logFirstFrameTiming);
  _installWebStartupWarmupFrames();
}

/// Triggers google_mobile_ads' internal `_init` cleanup on the platform side.
///
/// Touching [MobileAds.instance] makes the plugin send `'_init'`, which calls
/// `instanceManager.disposeAllAds()` on Android. The Dart-side ad registry and
/// its counter restart at 0 whenever the Dart isolate restarts (hot restart,
/// engine recreation) — but the native ad map survives until `_init` arrives.
/// Without this cleanup, the first `BannerAd.load()` after a restart assigns
/// Dart adId 0 again, the platform side throws
/// `IllegalArgumentException: Ad for following adId already exists: 0`, the
/// load future never completes, and every later banner load wedges behind it.
///
/// Fire-and-forget BEFORE any ad widget can mount, Android/iOS only (the
/// google_mobile_ads plugin registered there; elsewhere the call would just
/// produce a MissingPluginException for nothing).
void _resetNativeAdState() {
  if (kIsWeb) return;
  if (!isAdRenderNative) return;
  try {
    MobileAds.instance.updateRequestConfiguration(RequestConfiguration());
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[Ads] native ad state reset skipped: $e');
    }
  }
}

void _installWebVisibilityFrameKick() {
  if (!kIsWeb || _webFrameKickInstalled) return;
  _webFrameKickInstalled = true;

  bool isVisible() =>
      html.document.hidden != true && html.document.visibilityState != 'hidden';

  void kickFrame() {
    if (_webFrameKickShutdown) return;
    try {
      SchedulerBinding.instance.scheduleFrame();
    } catch (_) {}
  }

  try {
    html.document.addEventListener('visibilitychange', (_) {
      if (isVisible()) kickFrame();
    });
    html.window.addEventListener('pageshow', (_) => kickFrame());
    html.window.addEventListener('beforeunload', (_) {
      _webFrameKickShutdown = true;
    });
    html.window.addEventListener('unload', (_) {
      _webFrameKickShutdown = true;
    });
  } catch (_) {}

  if (isVisible()) kickFrame();
}

void _stopWebWarmupTimer() {
  _webWarmupTimer?.cancel();
  _webWarmupTimer = null;
  _webWarmupStartedAt = null;
}

void _shutdownWebWarmup() {
  _webWarmupShutdown = true;
  _stopWebWarmupTimer();
}

void _installWebStartupWarmupFrames() {
  if (!kIsWeb || _webWarmupInstalled) return;
  _webWarmupInstalled = true;

  bool isHidden() =>
      html.document.hidden == true || html.document.visibilityState == 'hidden';

  void shutdownWarmup() => _shutdownWebWarmup();

  void updateTimer() {
    if (_webWarmupShutdown) {
      _stopWebWarmupTimer();
      return;
    }

    if (!isHidden()) {
      _stopWebWarmupTimer();
      return;
    }

    _webWarmupStartedAt ??= DateTime.now();
    if (_webWarmupTimer == null) {
      for (var i = 0; i < 20; i++) {
        Future.delayed(Duration(milliseconds: 25 * i), () {
          if (_webWarmupShutdown || !isHidden()) return;
          try {
            if (SchedulerBinding.instance.hasScheduledFrame) return;
            SchedulerBinding.instance.scheduleWarmUpFrame();
            SchedulerBinding.instance.scheduleFrame();
          } catch (_) {
            _shutdownWebWarmup();
          }
        });
      }
    }
    _webWarmupTimer ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_webWarmupShutdown) {
        _stopWebWarmupTimer();
        return;
      }

      if (!isHidden()) {
        _stopWebWarmupTimer();
        return;
      }

      final startedAt = _webWarmupStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) > const Duration(minutes: 2)) {
        _shutdownWebWarmup();
        return;
      }

      try {
        if (SchedulerBinding.instance.hasScheduledFrame) return;
        SchedulerBinding.instance.scheduleWarmUpFrame();
        SchedulerBinding.instance.scheduleFrame();
      } catch (_) {
        _shutdownWebWarmup();
      }
    });
  }

  _webWarmupPrevFlutterErrorHandler ??= FlutterError.onError;
  final prevHandler = _webWarmupPrevFlutterErrorHandler;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    if (_isIgnorableWebSocketError(details.exception)) {
      return;
    }
    if (message.contains('disposed EngineFlutterView') ||
        message.contains('Trying to render a disposed EngineFlutterView')) {
      // Quietly shutdown warmup without re-throwing to user
      _shutdownWebWarmup();
      return;
    }
    prevHandler?.call(details);
    FlutterError.presentError(details);
  };

  try {
    html.document.addEventListener('visibilitychange', (_) => updateTimer());
    html.window.addEventListener('pageshow', (_) => updateTimer());
    html.window.addEventListener('pagehide', (_) => shutdownWarmup());
    html.window.addEventListener('beforeunload', (_) => shutdownWarmup());
    html.window.addEventListener('unload', (_) => shutdownWarmup());
  } catch (_) {}

  updateTimer();
}

class _BootstrapApp extends StatefulWidget {
  final ProviderContainer container;
  final Future<_BootstrapInitResult> initFuture;
  const _BootstrapApp({required this.container, required this.initFuture});

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  bool _showMainApp = false;
  bool _didLogInitComplete = false;
  int _lastWaitingLogAtMs = 0;
  late Future<_BootstrapInitResult> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = widget.initFuture;
  }

  void _retryBootstrap() {
    setState(() {
      _showMainApp = false;
      _didLogInitComplete = false;
      _initFuture = _bootstrapInitialize(widget.container);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BootstrapInitResult>(
      future: _initFuture,
      builder: (context, snapshot) {
        print(
          '[STARTUP_DIAG] future_builder '
          'state=${snapshot.connectionState.name} '
          'hasError=${snapshot.hasError} hasResult=${snapshot.data != null}',
        );
        if (snapshot.connectionState != ConnectionState.done) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastWaitingLogAtMs >= 1000) {
            _lastWaitingLogAtMs = nowMs;
            debugPrint('⏱️ [BOOTSTRAP] Waiting for initFuture at $nowMs');
          }
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: StartupLoaderScaffold(),
          );
        }

        final result = snapshot.data;
        if (!_didLogInitComplete) {
          _didLogInitComplete = true;
          debugPrint(
            '⏱️ [BOOTSTRAP] Init complete at ${DateTime.now().millisecondsSinceEpoch}',
          );
          print(
            '[STARTUP_DIAG] future_builder_completed '
            'hasError=${snapshot.hasError} hasResult=${result != null} '
            'errorApp=${result?.errorApp != null}',
          );
        }
        if (snapshot.hasError || result == null) {
          print(
            '[STARTUP_DIAG] selecting_bootstrap_error '
            'errorType=${snapshot.error?.runtimeType ?? "none"} '
            'error=${snapshot.error}',
          );
          final bootstrapStack = snapshot.stackTrace;
          if (bootstrapStack != null) {
            print('[STARTUP_DIAG] bootstrap_error_stack $bootstrapStack');
          }
          final err =
              snapshot.error?.toString() ??
              LocalizationState.defaultTranslation('bootstrapUnknownError');
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ProviderScope(
              child: SupabaseInitErrorApp(error: err, onRetry: _retryBootstrap),
            ),
          );
        }

        if (result.errorApp != null) {
          print('[STARTUP_DIAG] selecting_result_error_app');
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: result.errorApp!,
          );
        }

        // Defer building the full app by one frame so this frame stays light (avoids jank).
        if (!_showMainApp) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Give the engine one more frame to recover from any startup load
            // before unblocking the deferred bootstrap work (chat keys, BGSESSION,
            // L10N retranslation, etc.).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              BootstrapDeferral.markAppReady();
            });
            if (mounted) {
              print('[STARTUP_DIAG] switching_to_main_app');
              setState(() => _showMainApp = true);
            }
          });
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: StartupLoaderScaffold(),
          );
        }

        print('[STARTUP_DIAG] building_match_me_app');
        return UncontrolledProviderScope(
          container: widget.container,
          child: const MatchMeApp(),
        );
      },
    );
  }
}

final supabase = Supabase.instance.client;

bool _isFcmSupportedPlatform() {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

int? _parseTabIndexFromAny(Object? raw) {
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw);
  return null;
}

void _applyNavigationFromPushData(
  Map<String, dynamic> data, {
  bool isUserInteraction = false,
}) {
  // Defense-in-depth: server now stamps match_expiry pushes with the target
  // user_id. Drop pushes meant for a different account sharing this device's
  // old FCM token (multi-account testing left stale user_session rows).
  try {
    final pushType =
        ((data['type'] ?? data['kind'] ?? data['notification_type']) as Object?)
            ?.toString()
            .trim()
            .toLowerCase();
    if (pushType == 'match_expiry' || pushType == 'pinned_expiry') {
      final targetUid =
          ((data['user_id'] ?? data['userId']) as Object?)?.toString().trim() ??
          '';
      if (targetUid.isNotEmpty) {
        final currentUid = supabase.auth.currentUser?.id.trim() ?? '';
        if (currentUid.isNotEmpty && targetUid != currentUid) return;
      }
    }
  } catch (_) {}
  final matchId = ((data['matchId'] ?? data['match_id']) as String?)?.trim();
  final routeFromData = ((data['route'] ?? data['deep_link']) as String?)
      ?.trim();
  final tabIndex = _parseTabIndexFromAny(data['tabIndex'] ?? data['tab_index']);

  final effectiveRoute = (routeFromData != null && routeFromData.isNotEmpty)
      ? routeFromData
      : (matchId != null && matchId.isNotEmpty)
      ? '/chat/$matchId'
      : null;

  if (!isUserInteraction) {
    return;
  }

  // Tapping a card consumes the event: record matches so no poll/realtime
  // path re-posts them, and drop sibling cards/alarms for the same expiry
  // event so the shade cannot keep duplicates of what was just consumed.
  try {
    final tapType =
        ((data['type'] ?? data['kind'] ?? data['notification_type']) as Object?)
            ?.toString()
            .trim()
            .toLowerCase();
    if (tapType == 'match' || tapType == 'new_match') {
      final tappedMatchId =
          (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
      if (tappedMatchId.isNotEmpty) {
        unawaited(BackgroundService.markMatchNotified(tappedMatchId));
      }
    } else if (tapType == 'match_expiry' || tapType == 'pinned_expiry') {
      unawaited(_reconcileExpiryEventOnOpen(data, kind: tapType!));
    }
  } catch (_) {}

  // Pinned-expiry tap: open Matching Settings directly (Home base card).
  try {
    final tapType =
        ((data['type'] ?? data['kind'] ?? data['notification_type']) as Object?)
            ?.toString()
            .trim()
            .toLowerCase();
    if (tapType == 'pinned_expiry') {
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      nav.push(
        MaterialPageRoute(builder: (_) => const MatchingSettingsScreen()),
      );
      return;
    }
  } catch (_) {}

  if (tabIndex != null && tabIndex >= 0 && tabIndex <= 4) {
    AppShortcuts.setPendingTabIndex(tabIndex);
    try {
      container.read(navigationIndexProvider.notifier).setIndex(tabIndex);
    } catch (_) {}
    return;
  }

  if (effectiveRoute == null || !effectiveRoute.startsWith('/chat/')) return;

  final nav = navigatorKey.currentState;
  if (nav == null) {
    _pendingNotificationRoute = effectiveRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = _pendingNotificationRoute;
      final nav2 = navigatorKey.currentState;
      if (pending != null && nav2 != null) {
        _pendingNotificationRoute = null;
        nav2.pushNamed(pending);
      }
    });
    return;
  }

  nav.pushNamed(effectiveRoute);
}

/// Threshold (seconds) of an expiry push payload.
int? _expiryThresholdSecondsFromData(Map<String, dynamic> data) {
  final raw = (data['threshold_seconds'] ?? data['thresholdSeconds'] ?? '')
      .toString()
      .trim();
  return int.tryParse(raw);
}

/// Exact expiry instant (epoch ms) of an expiry push payload. Cron sends
/// `expiry_at` as an ISO timestamp; raw epoch millis are tolerated too.
int? _expiryMsFromData(Map<String, dynamic> data) {
  final raw = (data['expiry_at'] ?? data['expiryAt'] ?? '').toString().trim();
  if (raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed.millisecondsSinceEpoch;
  return int.tryParse(raw);
}

/// Tag of the server (FCM SDK) card for an expiry event. Mirrors the collapse
/// tag built by cron-jobs/push-message:
/// `${type}_${match_id ?? user_id}_${threshold_seconds}`.
String _expiryServerCardTag({
  required String kind,
  required Map<String, dynamic> data,
}) {
  final key =
      (data['match_id'] ??
              data['matchId'] ??
              data['user_id'] ??
              data['userId'] ??
              '')
          .toString()
          .trim();
  final thr = (data['threshold_seconds'] ?? data['thresholdSeconds'] ?? '')
      .toString()
      .trim();
  return thr.isEmpty ? '${kind}_$key' : '${kind}_${key}_$thr';
}

/// Mark a match-expiry warning as surfaced (the shared prefs gate the in-app
/// scan writes too) and drop the OS-scheduled fallback alarm for that exact
/// (match, threshold, expiry window) so no other path adds a second card.
Future<void> _markExpiryWarningSurfaced(
  Map<String, dynamic> data, {
  String kind = 'match_expiry',
}) async {
  try {
    if (kind != 'match_expiry') return;
    final matchId =
        (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
    final thresholdSeconds = _expiryThresholdSecondsFromData(data);
    final expiryMs = _expiryMsFromData(data);
    if (matchId.isEmpty || thresholdSeconds == null || expiryMs == null) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      ExpiryLocalScheduleService.warnPrefsKey(
        matchId: matchId,
        thresholdSeconds: thresholdSeconds,
        expiryMs: expiryMs,
      ),
      true,
    );
    await ExpiryLocalScheduleService.cancelThreshold(
      matchId: matchId,
      thresholdSeconds: thresholdSeconds,
      expiryMs: expiryMs,
    );
  } catch (_) {}
}

/// Foreground expiry push (onMessage): exactly one card per
/// (match, threshold, expiry window). The in-app scan writes the same gate,
/// so whichever path fired first wins; the OS-scheduled alarm and any server
/// card still in the shade for this exact event are dropped in favor of the
/// card posted here.
Future<void> _handleForegroundExpiryPush({
  required String kind,
  required Map<String, dynamic> data,
  required String title,
  required String body,
}) async {
  try {
    final matchId =
        (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
    final thresholdSeconds = _expiryThresholdSecondsFromData(data);
    final expiryMs = _expiryMsFromData(data);
    final serverTag = _expiryServerCardTag(kind: kind, data: data);

    if (kind == 'match_expiry' &&
        matchId.isNotEmpty &&
        thresholdSeconds != null &&
        expiryMs != null) {
      final prefs = await SharedPreferences.getInstance();
      final gateKey = ExpiryLocalScheduleService.warnPrefsKey(
        matchId: matchId,
        thresholdSeconds: thresholdSeconds,
        expiryMs: expiryMs,
      );
      final alreadySurfaced = prefs.getBool(gateKey) ?? false;
      unawaited(
        ExpiryLocalScheduleService.cancelThreshold(
          matchId: matchId,
          thresholdSeconds: thresholdSeconds,
          expiryMs: expiryMs,
        ),
      );
      if (alreadySurfaced) {
        // The in-app scan (or an earlier delivery of this same push) already
        // surfaced this warning — a second card would double the event.
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          await MobileLocalNotificationService.hasDeliveredServerNotification(
            serverTag,
          )) {
        // The server banner for this exact event is already delivered (drawn
        // while the app was killed) — it is the notification. Record the
        // gate so the in-app scan and restart paths stay quiet.
        await prefs.setBool(gateKey, true);
        return;
      }
      await prefs.setBool(gateKey, true);
    }

    // Pinned expiry (and any path that skipped the gate above): a delivered
    // server banner for this exact event is already the notification.
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        await MobileLocalNotificationService.hasDeliveredServerNotification(
          serverTag,
        )) {
      return;
    }

    // Replace any server card for this exact event that was drawn while the
    // app was backgrounded: the local card below is the single entry.
    unawaited(BackgroundService.cancelServerCard(serverTag));

    if (kIsWeb) {
      await WebNotificationService.showMatchNotification(
        matchId: matchId.isNotEmpty ? matchId : kind,
        matchName: title,
        matchPhotoUrl: '',
        tag: serverTag,
      );
      return;
    }

    await MobileLocalNotificationService.showMatchExpiryNotification(
      matchId: matchId.isNotEmpty ? matchId : kind,
      title: title,
      body: body,
      notificationKey:
          '${kind}_${thresholdSeconds ?? data['threshold_seconds'] ?? data['thresholdSeconds'] ?? 'warn'}',
      serverTag: serverTag,
    );
  } catch (_) {}
}

/// Tap on an expiry card (onMessageOpenedApp / initial message): the event is
/// consumed, so record it as surfaced and drop whatever other card or alarm
/// for the same event may still be pending.
Future<void> _reconcileExpiryEventOnOpen(
  Map<String, dynamic> data, {
  required String kind,
}) async {
  await _markExpiryWarningSurfaced(data, kind: kind);
  unawaited(
    BackgroundService.cancelServerCard(
      _expiryServerCardTag(kind: kind, data: data),
    ),
  );
}

/// Foreground match push: the native Realtime/poll path may have already
/// posted its own card for this match (or may post one later). Exactly one
/// card per match: whichever path fires first wins, the loser skips, and the
/// match is recorded as buzzed so the periodic poll cannot re-post it.
Future<void> _showForegroundMatchPush({
  required String matchId,
  required String title,
  required String body,
}) async {
  try {
    if (await BackgroundService.wasMatchNotified(matchId)) return;
    await BackgroundService.markMatchNotified(matchId);
    // Replace any server card for this match drawn while the app was
    // backgrounded: the local card below is the single entry.
    unawaited(BackgroundService.cancelServerCard('new_match_$matchId'));
    await MobileLocalNotificationService.showNewMatchNotification(
      matchId: matchId,
      title: title,
      body: body,
    );
  } catch (_) {}
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Handle admin broadcast messages (in-app bookkeeping + tray for
    // data-only pushes). `fromBackground: true` stops this isolate from
    // re-posting the tray entry the Android/FCM SDK already drew for the
    // message's `notification` block (that duplicate showed the same broadcast
    // twice for a single admin Resend click).
    try {
      AdminBroadcastService.handleBroadcastMessage(
        message,
        fromBackground: true,
      );
    } catch (_) {}
    if (defaultTargetPlatform == TargetPlatform.android) {
      final data = Map<String, dynamic>.from(message.data);
      final messageId = (data['messageId'] ?? data['message_id'])
          ?.toString()
          .trim();
      final matchId = (data['matchId'] ?? data['match_id'])?.toString().trim();
      final kind = (data['kind'] ?? data['type'] ?? data['notification_type'])
          ?.toString()
          .trim()
          .toLowerCase();

      // NOTE: previously this only ran when message.notification == null,
      // but the server always sends notification+data so the branch never
      // fired for real chat/match pushes. Handle both shapes so killed /
      // background / reboot pushes still refresh the native tray, history,
      // and MessagingStyle via the native service.
      final isChat =
          (messageId != null && messageId.isNotEmpty) ||
          kind == 'message' ||
          kind == 'chat_message' ||
          kind == 'chat' ||
          (data['senderId'] ?? data['sender_id']) != null;
      final isMatch =
          kind == 'match' || kind == 'new_match' || kind == 'match_extended';
      final isExpiry = kind == 'match_expiry' || kind == 'pinned_expiry';
      // NOTE: admin broadcasts are deliberately NOT routed through the native
      // service here. `checkNotifications` -> `showTranslatedNotification`
      // posts a chat/MessagingStyle notification built from the passed
      // senderName/translatedContent (i.e. the broadcast title/body), which
      // duplicated the broadcast in the tray on top of the FCM/OS entry.
      final isRetraction =
          kind == 'message_edited' || kind == 'message_deleted';

      // Silent retraction tick: drop the stale grouped card + history, then
      // re-check latest so remaining unreads re-post with correct text.
      if (isRetraction && (matchId != null && matchId.isNotEmpty)) {
        try {
          await BackgroundService.dismissChatNotification(matchId);
        } catch (_) {}
        try {
          await BackgroundService.resetChatNotification(matchId);
        } catch (_) {}
        try {
          await BackgroundService.triggerNotificationCheck(matchId: matchId);
        } catch (_) {}
        return;
      }

      if (isChat && !isMatch && !isExpiry) {
        // Chat pushes: route through the native RPC path WITHOUT the server
        // body. push-message always sends the localized placeholder ("New
        // message" etc.) since it can't decrypt — passing it would clobber
        // the real card the Realtime/native path posts. messageId marks an
        // immediate trigger; the native service fetches the stored
        // plaintext/translated text and drops the FCM SDK's tagged card
        // (tag match_<matchId>) before posting, so background states
        // converge on a single tray entry per chat.
        if ((messageId != null && messageId.isNotEmpty) ||
            (matchId != null && matchId.isNotEmpty)) {
          await BackgroundService.triggerNotificationCheck(
            messageId: (messageId != null && messageId.isNotEmpty)
                ? messageId
                : null,
            matchId: (matchId != null && matchId.isNotEmpty) ? matchId : null,
          );
        }
      } else if (isMatch) {
        // Matches: the server FCM card (tag new_match_<matchId>) IS the
        // notification, and the native RPC path knows that
        // (isMatchPushInTray) — it only posts its own card when the server
        // push never landed. Passing crafted copy here stacked a second
        // match card next to the server one.
        if (matchId != null && matchId.isNotEmpty) {
          await BackgroundService.triggerNotificationCheck(matchId: matchId);
        }
      } else if (isExpiry) {
        // The FCM SDK already draws the tray card for the notification
        // payload; this handler must not post another one. Record the event
        // against the shared expiry gate (same key the in-app scan uses) and
        // drop the OS-scheduled fallback alarm so exactly one card remains.
        await _markExpiryWarningSurfaced(data, kind: kind ?? 'match_expiry');
      }
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final data = Map<String, dynamic>.from(message.data);
      final kind = (data['kind'] ?? data['type'] ?? data['notification_type'])
          ?.toString()
          .trim()
          .toLowerCase();
      final matchId = (data['matchId'] ?? data['match_id'])?.toString().trim();
      final messageId = (data['messageId'] ?? data['message_id'])
          ?.toString()
          .trim();
      if ((kind == 'message' || kind == 'chat_message' || kind == 'chat') &&
          matchId != null &&
          matchId.isNotEmpty &&
          data['should_alert'] == 'false') {
        // Follow-up unread messages arrive data-only. Rebuild the same local
        // conversation card silently instead of asking iOS to alert again.
        await MobileLocalNotificationService.showMessageNotification(
          chatId: matchId,
          matchId: matchId,
          senderName: (data['notification_title'] ?? 'Someone').toString(),
          messageContent: (data['notification_body'] ?? '').toString(),
          messageId: messageId,
          alreadyAggregated: true,
          shouldAlertOverride: false,
        );
      }
    }
  } catch (_) {}
}

/// The latest Firebase Installation ID (FID) emitted by FCM.
///
/// firebase_messaging 17 replaced the rotating FCM registration token
/// (deprecated `getToken()`/`onTokenRefresh`) with the stable FID: the new
/// `register()` returns void and the value is delivered on `onRegistered`.
/// FCM accepts the FID in the `token` field of a v1 `messages:send`, so the
/// `fcmToken` parameter and the server column keep their names.
String? _lastFcmRegistrationId;

/// Registers this install with FCM and returns the current FID, or null.
///
/// `onRegistered` is a broadcast stream, so the long-lived listener installed
/// by `_initializeFcmForCurrentUser` keeps receiving events alongside this
/// temporary one. Falls back to the last FID seen by the long-lived listener:
/// the FID is stable per install, so a cache hit is valid even when
/// `register()` does not re-emit.
Future<String?> _ensureFcmRegistered() async {
  final messaging = FirebaseMessaging.instance;

  String? vapidKey;
  if (kIsWeb) {
    final envVapid = const String.fromEnvironment(
      'FCM_WEB_VAPID_KEY',
      defaultValue: '',
    ).trim();
    String dotVapid = '';
    try {
      dotVapid = (dotenv.env['FCM_WEB_VAPID_KEY'] ?? '').trim();
    } catch (_) {}
    final resolved = envVapid.isNotEmpty ? envVapid : dotVapid;
    vapidKey = resolved.isNotEmpty ? resolved : null;
  }

  final completer = Completer<String?>();
  StreamSubscription<String>? sub;
  try {
    sub = messaging.onRegistered.listen((fid) {
      final trimmed = fid.trim();
      if (trimmed.isEmpty) return;
      _lastFcmRegistrationId = trimmed;
      if (!completer.isCompleted) completer.complete(trimmed);
    });
    await messaging.register(vapidKey: vapidKey);
    final emitted = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
    return emitted ?? _lastFcmRegistrationId;
  } catch (_) {
    return _lastFcmRegistrationId;
  } finally {
    unawaited(sub?.cancel());
  }
}

Future<void> _initializeFcmForCurrentUser() async {
  if (!_isFcmSupportedPlatform()) return;

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {
    return;
  }

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await PermissionManager.requestNotificationPermission();
    } catch (_) {}
  }

  if (kIsWeb) {
    try {
      await WebNotificationService.initialize();
    } catch (_) {}
  }

  if (!_fcmHandlersInstalled) {
    _fcmHandlersInstalled = true;
    if (!kIsWeb) {
      try {
        FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler,
        );
      } catch (_) {}
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      var hasApsEntitlement = true;
      try {
        hasApsEntitlement = await AppInfoService.hasApsEnvironmentEntitlement();
      } catch (_) {}

      try {
        if (hasApsEntitlement) {
          await FirebaseMessaging.instance.requestPermission(
            alert: true,
            badge: true,
            sound: true,
          );
        }
      } catch (_) {}
      try {
        // Foreground notifications are rendered by the shared app handler.
        // Keep native iOS presentation disabled so it cannot bypass the
        // currently-viewed-chat exception or duplicate our grouped card.
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
              // Foreground notifications are rendered by the app's shared
              // per-type handler. Letting iOS auto-present FCM alerts here
              // bypasses per-chat suppression and duplicates local cards.
              alert: false,
              badge: false,
              sound: false,
            );
      } catch (_) {}
    }

    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        try {
          unawaited(AppBadgeService.clear());
        } catch (_) {}
        _applyNavigationFromPushData(
          Map<String, dynamic>.from(initial.data),
          isUserInteraction: true,
        );
      }
    } catch (_) {}

    try {
      FirebaseMessaging.onMessage.listen((message) {
        // Handle admin broadcast messages
        AdminBroadcastService.handleBroadcastMessage(message);
        // A foreground push means the backend just recorded a notification for
        // this user (push-message writes the inbox row before sending FCM), so
        // refresh the inbox: it must not depend on the Realtime socket being
        // healthy (it may be reconnecting or the channel may have silently
        // died). Realtime remains the primary path; this is the safety net.
        final inboxContext = navigatorKey.currentContext;
        if (inboxContext != null && supabase.auth.currentUser?.id != null) {
          try {
            unawaited(
              ProviderScope.containerOf(
                inboxContext,
                listen: false,
              ).read(notificationInboxProvider.notifier).refresh(),
            );
          } catch (_) {}
        }
        final data = Map<String, dynamic>.from(message.data);
        final type = (data['type'] ?? data['kind'] ?? data['notification_type'])
            ?.toString()
            .trim()
            .toLowerCase();
        if (type == 'profile_edit_review') {
          final requestId = (data['request_id'] ?? data['requestId'])
              ?.toString()
              .trim();
          final title = message.notification?.title?.trim();
          final body = message.notification?.body?.trim();
          if (title != null &&
              title.isNotEmpty &&
              body != null &&
              body.isNotEmpty) {
            unawaited(
              MobileLocalNotificationService.showAdminBroadcastNotification(
                broadcastId: requestId?.isNotEmpty == true
                    ? 'profile_edit_review:$requestId'
                    : 'profile_edit_review',
                title: title,
                body: body,
              ),
            );
          }
        } else if (type == 'match' || type == 'new_match') {
          // Foreground match push: Realtime overlay may be disconnected, so
          // also raise an OS notification (tap routes via onMessageOpenedApp).
          final matchId =
              (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
          final title = message.notification?.title?.trim().isNotEmpty == true
              ? message.notification!.title!.trim()
              : 'New Match!';
          final body = message.notification?.body?.trim().isNotEmpty == true
              ? message.notification!.body!.trim()
              : 'You have a new match. Tap to view.';
          if (matchId.isNotEmpty && !kIsWeb) {
            unawaited(
              _showForegroundMatchPush(
                matchId: matchId,
                title: title,
                body: body,
              ),
            );
          } else if (kIsWeb) {
            final otherUser =
                (data['otherUserId'] ?? data['other_user_id'] ?? '').toString();
            unawaited(
              WebNotificationService.showMatchNotification(
                matchId: matchId.isNotEmpty ? matchId : 'unknown',
                matchName: otherUser.isNotEmpty ? otherUser : title,
                matchPhotoUrl: '',
                // Same identity as the server push tag: a web card already
                // delivered for this match gets replaced, not duplicated.
                tag: matchId.isNotEmpty ? 'new_match_$matchId' : null,
              ),
            );
          }
        } else if (type == 'match_extended') {
          // Foreground extension push: the peer extended the chat window, so
          // surface it as its own notification rather than reusing the
          // new-match copy ("New Match!" would be wrong and confusing).
          final matchId =
              (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
          final title = message.notification?.title?.trim().isNotEmpty == true
              ? message.notification!.title!.trim()
              : 'You have more time';
          final body = message.notification?.body?.trim().isNotEmpty == true
              ? message.notification!.body!.trim()
              : 'Say hi before this match runs out.';
          if (!kIsWeb && matchId.isNotEmpty) {
            unawaited(
              MobileLocalNotificationService.showMatchExtendedNotification(
                matchId: matchId,
                title: title,
                body: body,
              ),
            );
          } else if (kIsWeb) {
            unawaited(
              WebNotificationService.showMatchNotification(
                matchId: matchId.isNotEmpty ? matchId : 'match_extended',
                matchName: title,
                matchPhotoUrl: '',
              ),
            );
          }
        } else if (type == 'match_expiry' || type == 'pinned_expiry') {
          // Foreground expiry push: one card per (match, threshold, expiry
          // window) — shared gate with the in-app scan, late OS alarm and
          // stale server cards are dropped by the helper.
          final title = message.notification?.title?.trim().isNotEmpty == true
              ? message.notification!.title!.trim()
              : (type == 'pinned_expiry'
                    ? 'Pinned location expiring soon'
                    : 'Match expiring soon');
          final body = message.notification?.body?.trim().isNotEmpty == true
              ? message.notification!.body!.trim()
              : 'Open the app to add more time.';
          unawaited(
            _handleForegroundExpiryPush(
              kind: type ?? 'match_expiry',
              data: data,
              title: title,
              body: body,
            ),
          );
        } else if (type == 'ai_quota') {
          // Foreground admin AI-quota alert: Android does not auto-display
          // FCM notification payloads while the app is foregrounded, so
          // surface it through the admin-broadcast channel.
          final title = message.notification?.title?.trim().isNotEmpty == true
              ? message.notification!.title!.trim()
              : 'System alert';
          final body = message.notification?.body?.trim().isNotEmpty == true
              ? message.notification!.body!.trim()
              : 'AI provider quota needs attention.';
          if (!kIsWeb) {
            unawaited(
              MobileLocalNotificationService.showAdminBroadcastNotification(
                broadcastId: 'ai_quota:${(data['metric'] ?? data['provider'] ?? 'alert').toString()}',
                title: title,
                body: body,
              ),
            );
          } else {
            unawaited(
              WebNotificationService.showMatchNotification(
                matchId: 'ai_quota',
                matchName: title,
                matchPhotoUrl: '',
              ),
            );
          }
        } else if (type == 'location_share') {
          // Foreground location-share push: the realtime path usually beats
          // the queue-driven push and shows the persistent banner; this
          // covers the case where realtime was torn down. Both paths post to
          // the SAME OS notification id, so they replace instead of stack.
          final matchId =
              (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
          final title = message.notification?.title?.trim().isNotEmpty == true
              ? message.notification!.title!.trim()
              : '📍 Live location';
          final body = message.notification?.body?.trim().isNotEmpty == true
              ? message.notification!.body!.trim()
              : 'is sharing their live location with you';
          if (matchId.isNotEmpty) {
            if (kIsWeb) {
              unawaited(
                WebNotificationService.showLocationShareNotification(
                  title: title,
                  body: body,
                ),
              );
            } else {
              unawaited(
                MobileLocalNotificationService.showLocationShareNotification(
                  notificationId: 'location_share_$matchId',
                  title: title,
                  body: body,
                ),
              );
            }
          }
        } else if (type == 'message_edited' || type == 'message_deleted') {
          // Silent retraction tick in foreground: Realtime already merged the
          // edit/delete locally; drop the stale tray card and rebuild from
          // the RPC latest on Android so remaining unreads re-post cleanly.
          final matchId =
              (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
          if (matchId.isNotEmpty && !kIsWeb) {
            unawaited(
              MobileLocalNotificationService.dismissChatNotification(matchId),
            );
            if (defaultTargetPlatform == TargetPlatform.android) {
              unawaited(BackgroundService.resetChatNotification(matchId));
              unawaited(
                BackgroundService.triggerNotificationCheck(matchId: matchId),
              );
            }
          }
        } else if (type == 'message' ||
            type == 'chat_message' ||
            type == 'chat' ||
            (data['messageId'] ?? data['message_id']) != null) {
          // Foreground chat push: the Realtime path may be down (offline,
          // reconnecting, backgrounded WebView), so FCM is the fallback
          // signal. On Android route it through the native background
          // service — the same producer the Realtime path uses — so both
          // converge on ONE tray card (notificationId = matchId.hashCode()).
          // Posting the flutter_local_notifications card here stacked a
          // second entry for every message because its id space (Dart
          // hashCode) can never replace the native card. No content is
          // passed: the native RPC path fetches the stored
          // plaintext/translated text, so the localized placeholder body
          // from the server push can't clobber a real card.
          final matchId =
              (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
          final messageId =
              (data['messageId'] ?? data['message_id'])?.toString().trim() ??
              '';
          final sender =
              (data['senderName'] ??
                      data['sender_name'] ??
                      data['notification_title'] ??
                      message.notification?.title ??
                      'Someone')
                  .toString();
          final text =
              (data['notification_body'] ??
                      data['body'] ??
                      data['message'] ??
                      message.notification?.body ??
                      'New message')
                  .toString();
          final alreadyAggregated = data['aggregated_messages'] == 'true';
          final alertValue = data['should_alert']?.toString();
          final bool? shouldAlert = alertValue == 'true'
              ? true
              : alertValue == 'false'
              ? false
              : null;
          if (matchId.isNotEmpty) {
            if (kIsWeb) {
              unawaited(
                WebNotificationService.showMessageNotification(
                  chatId: matchId,
                  senderName: sender,
                  messageContent: text,
                  matchId: matchId,
                  alreadyAggregated: alreadyAggregated,
                  shouldAlertOverride: shouldAlert,
                ),
              );
            } else if (defaultTargetPlatform == TargetPlatform.android) {
              unawaited(
                BackgroundService.triggerNotificationCheck(
                  matchId: matchId,
                  messageId: messageId.isNotEmpty ? messageId : null,
                  translatedContent: text,
                  originalContent: text,
                  senderName: sender,
                  shouldAlert: shouldAlert,
                ),
              );
            } else {
              unawaited(
                MobileLocalNotificationService.showMessageNotification(
                  chatId: matchId,
                  senderName: sender,
                  messageContent: text,
                  matchId: matchId,
                  messageId: messageId.isNotEmpty ? messageId : null,
                  alreadyAggregated: alreadyAggregated,
                  shouldAlertOverride: shouldAlert,
                ),
              );
            }
          }
        }
        // Don't navigate automatically for background messages - just show notification
        _applyNavigationFromPushData(
          Map<String, dynamic>.from(message.data),
          isUserInteraction: false,
        );
      });
    } catch (_) {}

    try {
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        // Tapping a tray entry means its content is seen: drop the icon
        // badge (server re-asserts the true count on the next push).
        try {
          unawaited(AppBadgeService.clear());
        } catch (_) {}
        // Handle admin broadcast message opens
        AdminBroadcastService.handleBroadcastMessageOpened(message);
        // Navigate when user taps on notification
        _applyNavigationFromPushData(
          Map<String, dynamic>.from(message.data),
          isUserInteraction: true,
        );
      });
    } catch (_) {}

    try {
      // FID registration API (firebase_messaging 17+): the stable Firebase
      // Installation ID replaces the rotating FCM registration token and is
      // what the server stores as the push target. FCM accepts the FID in the
      // `token` field of a v1 messages:send, so the `fcmToken` parameter and
      // the server column keep their names.
      FirebaseMessaging.instance.onRegistered.listen((fid) async {
        final trimmed = fid.trim();
        if (trimmed.isEmpty) return;
        _lastFcmRegistrationId = trimmed;
        final current = supabase.auth.currentUser?.id;
        if (current == null || current.isEmpty) return;
        final platformText = kIsWeb
            ? 'web'
            : defaultTargetPlatform == TargetPlatform.android
            ? 'android'
            : 'ios';
        // Immediate (bypass dedup/cooldown) so a registration/re-registration
        // reaches user_session without waiting 5s.
        SessionRegistrationCoordinator.instance.scheduleImmediate(
          userId: current,
          platform: platformText,
          fcmToken: trimmed,
          source: 'fcm-token-refresh',
        );
      });
    } catch (_) {}
    // Periodic FCM resync: the FID is stable per install, but re-asserting it
    // every 6h while UI is alive keeps user_session correct after a reinstall
    // or a server-side clear (covers reboot/off gaps on next launch + while
    // running).
    try {
      _fcmResyncTimer?.cancel();
      _fcmResyncTimer = Timer.periodic(const Duration(hours: 6), (_) async {
        try {
          final current = supabase.auth.currentUser?.id;
          if (current == null || current.isEmpty) return;
          final fresh = await _ensureFcmRegistered();
          final trimmed = (fresh ?? '').trim();
          if (trimmed.isEmpty) return;
          final platformText = kIsWeb
              ? 'web'
              : defaultTargetPlatform == TargetPlatform.android
              ? 'android'
              : 'ios';
          SessionRegistrationCoordinator.instance.scheduleImmediate(
            userId: current,
            platform: platformText,
            fcmToken: trimmed,
            source: 'fcm-periodic-resync',
          );
        } catch (_) {}
      });
    } catch (_) {}
  }

  final userId = supabase.auth.currentUser?.id;
  if (userId == null || userId.isEmpty) return;

  final token = await _ensureFcmRegistered();

  if (token != null) {
    final trimmed = token.trim();
    if (trimmed.isNotEmpty) {
      try {
        final platformText = kIsWeb
            ? 'web'
            : defaultTargetPlatform == TargetPlatform.android
            ? 'android'
            : 'ios';
        SessionRegistrationCoordinator.instance.schedule(
          userId: userId,
          platform: platformText,
          fcmToken: trimmed,
          source: 'fcm-initial-token',
        );
      } catch (_) {}
      // Post-reboot recovery: native BootReceiver stamps
      // boot_service_start_ms. If we booted recently, force a second
      // immediate upsert (bypass dedup/cooldown) so a token rotated while
      // the device was off/killed reaches user_session on first launch.
      try {
        final prefs = await SharedPreferences.getInstance();
        // Native BootReceiver writes boot time as long + string (Dart
        // SharedPreferences cannot reliably read native longs).
        int bootMs = 0;
        try {
          final str =
              prefs.getString('boot_service_start_ms_str') ??
              prefs.getString('flutter.boot_service_start_ms_str');
          if (str != null && str.trim().isNotEmpty) {
            bootMs = int.tryParse(str.trim()) ?? 0;
          }
        } catch (_) {}
        if (bootMs == 0) {
          try {
            bootMs = prefs.getInt('boot_service_start_ms') ?? 0;
            if (bootMs != 0 && bootMs < 100000000000) {
              // Seconds fallback written by BootReceiver.
              bootMs = bootMs * 1000;
            }
          } catch (_) {}
        }
        if (bootMs > 0) {
          final ageMs = DateTime.now().millisecondsSinceEpoch - bootMs;
          if (ageMs >= 0 && ageMs < 24 * 60 * 60 * 1000) {
            final platformText = kIsWeb
                ? 'web'
                : defaultTargetPlatform == TargetPlatform.android
                ? 'android'
                : 'ios';
            Future.delayed(const Duration(seconds: 8), () {
              try {
                SessionRegistrationCoordinator.instance.scheduleImmediate(
                  userId: userId,
                  platform: platformText,
                  fcmToken: trimmed,
                  source: 'fcm-boot-resync',
                );
              } catch (_) {}
            });
          }
        }
        // Web SW identity: keep the service worker's recipient filter in
        // sync so background pushes are dropped for the wrong account and
        // kept for the right one even after restart.
        if (kIsWeb) {
          try {
            WebNotificationService.setServiceWorkerUserId(userId);
          } catch (_) {}
        }
      } catch (_) {}
    }
  }
}

class _BootstrapInitResult {
  final Widget? errorApp;
  final String? supabaseUrl;
  final String? supabaseAnonKey;
  const _BootstrapInitResult({
    this.errorApp,
    this.supabaseUrl,
    this.supabaseAnonKey,
  });
}

class _SupabaseRuntimeConfig {
  final String url;
  final String anonKey;
  const _SupabaseRuntimeConfig({required this.url, required this.anonKey});
}

const String _prefsSupabaseUrlKey = 'runtime_supabase_url';
const String _prefsSupabaseAnonKeyKey = 'runtime_supabase_anon_key';
const String _prefsLastHandledOAuthCodeKey = 'oauth_last_handled_code';
const String _prefsGoogleSwitchFlowIdKey = 'google_switch_flow_id';
const String _prefsGoogleSwitchCompletedFlowIdKey =
    'google_switch_completed_flow_id';

String _stripOptionalQuotes(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2) {
    final first = trimmed[0];
    final last = trimmed[trimmed.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
  }
  return trimmed;
}

Future<_SupabaseRuntimeConfig> _resolveSupabaseRuntimeConfig() async {
  final envUrl = _stripOptionalQuotes(
    const String.fromEnvironment('SUPABASE_URL', defaultValue: ''),
  );
  final envAnonKey = _stripOptionalQuotes(
    const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: ''),
  );

  var url = envUrl;
  var anonKey = envAnonKey;

  if (url.isEmpty) url = _stripOptionalQuotes(dotenv.env['SUPABASE_URL'] ?? '');
  if (anonKey.isEmpty) {
    anonKey = _stripOptionalQuotes(dotenv.env['SUPABASE_ANON_KEY'] ?? '');
  }

  // Optimization: If we have keys from .env, return immediately to avoid
  // waiting for SharedPreferences (which is slow on Android).
  // Query param overrides (Web) and Prefs fallback are only needed if .env is missing.
  if (url.isNotEmpty && anonKey.isNotEmpty) {
    // If on Web, we might still want to capture query params, but we can do that asynchronously
    // without blocking the main bootstrap.
    if (kIsWeb) {
      unawaited(_captureWebQueryParams(url, anonKey));
    }
    return _SupabaseRuntimeConfig(url: url, anonKey: anonKey);
  }

  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (e, st) {
    _reportNonFatal(e, st);
  }

  if (kIsWeb) {
    try {
      final qp = Uri.base.queryParameters;
      final qpUrl = _stripOptionalQuotes(
        qp['SUPABASE_URL'] ?? qp['supabase_url'] ?? '',
      );
      final qpKey = _stripOptionalQuotes(
        qp['SUPABASE_ANON_KEY'] ?? qp['supabase_anon_key'] ?? '',
      );

      if (url.isEmpty && qpUrl.isNotEmpty) url = qpUrl;
      if (anonKey.isEmpty && qpKey.isNotEmpty) anonKey = qpKey;

      if (prefs != null) {
        if (qpUrl.isNotEmpty) {
          await prefs.setString(_prefsSupabaseUrlKey, qpUrl);
        }
        if (qpKey.isNotEmpty) {
          await prefs.setString(_prefsSupabaseAnonKeyKey, qpKey);
        }
      }
    } catch (e, st) {
      _reportNonFatal(e, st);
    }
  }

  if (prefs != null) {
    if (url.isEmpty) {
      url = _stripOptionalQuotes(prefs.getString(_prefsSupabaseUrlKey) ?? '');
    }
    if (anonKey.isEmpty) {
      anonKey = _stripOptionalQuotes(
        prefs.getString(_prefsSupabaseAnonKeyKey) ?? '',
      );
    }
  }

  return _SupabaseRuntimeConfig(url: url, anonKey: anonKey);
}

Future<void> _captureWebQueryParams(
  String currentUrl,
  String currentKey,
) async {
  try {
    final qp = Uri.base.queryParameters;
    final qpUrl = _stripOptionalQuotes(
      qp['SUPABASE_URL'] ?? qp['supabase_url'] ?? '',
    );
    final qpKey = _stripOptionalQuotes(
      qp['SUPABASE_ANON_KEY'] ?? qp['supabase_anon_key'] ?? '',
    );

    if (qpUrl.isEmpty && qpKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    if (qpUrl.isNotEmpty) await prefs.setString(_prefsSupabaseUrlKey, qpUrl);
    if (qpKey.isNotEmpty) {
      await prefs.setString(_prefsSupabaseAnonKeyKey, qpKey);
    }
  } catch (e, st) {
    _reportNonFatal(e, st);
  }
}

/// Windows: request a fresh WNS channel URI (fire-and-forget) so
/// SessionService attaches `metadata.wns_channel_uri` on the next session
/// registration. Server senders (push-message, cron-jobs) dispatch toasts
/// through it while the app is closed. No-op on every other platform.
Future<void> _registerWindowsWnsChannel() async {
  if (kIsWeb) return;
  try {
    final uri = await WindowsPushChannelService.ensureChannel();
    if (uri == null) {
      debugPrint('[BOOTSTRAP] [WNS] No channel URI (unpackaged or failed)');
      return;
    }
    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      debugPrint('[BOOTSTRAP] [WNS] Channel fetched before auth; session '
          'registration will attach it');
      return;
    }
    SessionRegistrationCoordinator.instance.scheduleImmediate(
      userId: userId,
      platform: 'windows',
      source: 'wns-channel',
    );
    debugPrint('[BOOTSTRAP] [WNS] Channel registered');
  } catch (e) {
    debugPrint('⚠️ [BOOTSTRAP] [WNS] registration failed: $e');
  }
}

/// Setup deep link handler for OAuth callbacks from Google and Outlook
/// This is CRITICAL for the calendar sync OAuth flow to work on mobile
Future<void> _setupDeepLinkHandler() async {
  if (kIsWeb) return;

  try {
    final appLinks = AppLinks();
    debugPrint('🔗 [DeepLink] Setting up handler...');

    // CRITICAL: Set up stream listener FIRST, SYNCHRONOUSLY
    // This must be done immediately to catch callbacks that arrive while app is running
    // Do NOT await this - just set it up immediately
    appLinks.uriLinkStream.listen(
      (uri) async {
        debugPrint('🔗 [DeepLink] STREAM link received: $uri');
        await _processDeepLink(uri);
      },
      onError: (err) {
        debugPrint('⚠️ [DeepLink] Stream error: $err');
      },
    );
    debugPrint(
      '✅ [DeepLink] Stream listener registered (ready for callbacks while running)',
    );

    // Handle INITIAL deep link in background (when app launches via deep link)
    // This won't block the main flow
    scheduleMicrotask(() async {
      try {
        // Windows cold-start via toast activation: the matchme:// URI arrives
        // in the process command line (app_links cannot see it), so the
        // native push channel reads it directly.
        final windowsLaunch = await WindowsPushChannelService
            .getInitialLaunchPayload();
        if (windowsLaunch != null) {
          debugPrint(
            '[BOOTSTRAP] [DeepLink] Windows launch URI: $windowsLaunch',
          );
          await _processDeepLink(Uri.parse(windowsLaunch));
          return;
        }
        final initialLink = await appLinks.getInitialLink();
        if (initialLink != null) {
          debugPrint(
            '[BOOTSTRAP] [DeepLink] INITIAL link received on startup: $initialLink',
          );
          await _processDeepLink(initialLink);
        } else {
          debugPrint('[BOOTSTRAP] [DeepLink] No initial link on startup');
        }
      } catch (e) {
        debugPrint('⚠️ [DeepLink] Error getting initial link: $e');
      }
    });

    debugPrint(
      '✅ [DeepLink] Handler setup complete - listener active, initial link handler queued',
    );
  } catch (e, st) {
    debugPrint('⚠️ [DeepLink] Failed to setup handler: $e\n$st');
    _reportNonFatal(e, st);
  }
}

/// Helper function to restore the original session after detecting a user change
Future<void> _performSessionRestoration(
  Session? originalSession,
  String? originalUserId,
  String? newGoogleUserId,
  String? googleProviderToken,
  String? googleProviderEmail,
) async {
  if (originalSession == null || originalUserId == null) {
    debugPrint('⚠️ [OAuth] Restoration conditions not met, skipping');
    return;
  }

  debugPrint('🔐 [OAuth] ========== RESTORATION SEQUENCE START ==========');
  debugPrint('🔐 [OAuth] originalUserId: $originalUserId');
  debugPrint('🔐 [OAuth] newGoogleUserId: $newGoogleUserId');

  // Run restoration directly (no nested unawaited)
  try {
    debugPrint('🔐 [OAuth] Encoding session JSON...');
    final normalizedGoogleToken = googleProviderToken?.trim();
    if (normalizedGoogleToken != null && normalizedGoogleToken.isNotEmpty) {
      await CalendarSyncService.cacheGoogleImportToken(
        token: normalizedGoogleToken,
        expiry: DateTime.now().add(const Duration(minutes: 55)),
        userEmail: googleProviderEmail,
      );
      debugPrint('✅ [OAuth] Cached Google token before session restoration');
    }

    final sessionJson = jsonEncode(originalSession.toJson());
    debugPrint(
      '🔐 [OAuth] Session JSON encoded, about to call recoverSession()...',
    );

    await Supabase.instance.client.auth
        .recoverSession(sessionJson)
        .timeout(const Duration(seconds: 5));

    debugPrint(
      '✅ [OAuth] Original session RESTORED: user back to $originalUserId',
    );
    debugPrint(
      '✅ [OAuth] Google token available for calendar sync: ${googleProviderToken?.isNotEmpty == true ? 'YES' : 'NO'}',
    );

    // CRITICAL FIX: Force Supabase to persist the recovered session to its storage layer
    // recoverSession() only updates in-memory; refreshSession() forces validation and persistence
    try {
      debugPrint(
        '🔄 [OAuth] Forcing session persistence via refreshSession()...',
      );
      await Supabase.instance.client.auth.refreshSession().timeout(
        const Duration(seconds: 5),
      );
      debugPrint(
        '✅ [OAuth] Session refreshed and persisted to Supabase storage',
      );
    } catch (e) {
      debugPrint(
        '⚠️ [OAuth] refreshSession() encountered an issue: $e - but continuing with recovery',
      );
    }

    // CRITICAL FIX: Persist the restored session's credentials to secure store
    // (SecureStorage source of truth + plain shim for native background
    // service's restoreCredentialsAndConnect()). This prevents the background
    // service from overwriting with stale user_id/tokens.
    try {
      final currentUser = Supabase.instance.client.auth.currentUser;
      final currentSession = Supabase.instance.client.auth.currentSession;

      if (currentUser != null && currentSession != null) {
        await SensitiveSessionStore.instance.writeAuthTokens(
          userId: currentUser.id,
          accessToken: currentSession.accessToken,
          refreshToken: currentSession.refreshToken,
        );

        debugPrint(
          '💾 [OAuth] ✅ Persisted restored session to secure store: userId=$originalUserId',
        );
      }
    } catch (e) {
      debugPrint(
        '⚠️ [OAuth] Failed to persist restored session to secure store: $e',
      );
      // Continue anyway - this is a safety measure, not critical
    }
  } on TimeoutException catch (e) {
    debugPrint(
      '⚠️ [OAuth] recoverSession() timed out after 5s, but continuing: $e',
    );
  } catch (e, st) {
    debugPrint('❌ [OAuth] FATAL ERROR during restoration: $e');
    debugPrint('❌ [OAuth] Stack trace: $st');
  } finally {
    debugPrint('🔐 [OAuth] ========== RESTORATION SEQUENCE END ==========');
  }
}

/// Process any deep link (OAuth, email change, etc.)
Future<void> _processDeepLink(Uri uri) async {
  debugPrint(
    '🔗 [DeepLink] Processing: ${uri.scheme}://${uri.host}${uri.path}',
  );

  // Check if this is an email change confirmation link from our custom deep link
  if (uri.scheme == 'com.example.matchme' &&
      uri.host == 'email-change-confirm') {
    await _processEmailChangeDeepLink(uri);
    return;
  }

  // Check if this is a Supabase email change link (from email template)
  // Supabase sends links like: https://yourapp.supabase.co/auth/v1/verify?token=...&type=email_change
  if (uri.scheme == 'https' && uri.path.contains('/auth/v1/verify')) {
    final type = uri.queryParameters['type']?.trim();
    if (type == 'email_change') {
      await _processEmailChangeDeepLink(uri);
      return;
    }
  }

  // Otherwise process as OAuth link
  await _processOAuthDeepLink(uri);
}

/// Process email change confirmation deep link
Future<void> _processEmailChangeDeepLink(Uri uri) async {
  debugPrint('📧 [EmailChange] Processing email change confirmation link');

  try {
    final token = uri.queryParameters['token']?.trim();
    final type = uri.queryParameters['type']?.trim();

    debugPrint(
      '📧 [EmailChange] Token: ${token == null || token.isEmpty ? 'none' : 'present'}, len=${token?.length ?? 0}',
    );
    debugPrint('📧 [EmailChange] Type: $type');

    if (token == null || token.isEmpty) {
      debugPrint('⚠️ [EmailChange] No token in link');
      return;
    }

    if (type != 'email_change') {
      debugPrint('⚠️ [EmailChange] Invalid type: $type');
      return;
    }

    // The token is already processed by Supabase when the user clicked the link
    // We just need to refresh the session to get the updated email
    final auth = Supabase.instance.client.auth;

    // Capture localization and messenger before the async gap
    final String successMessage;
    final ScaffoldMessengerState? messenger;
    if (navigatorKey.currentContext != null) {
      final ctx = navigatorKey.currentContext!;
      messenger = ScaffoldMessenger.of(ctx);
      successMessage = ProviderScope.containerOf(
        ctx,
        listen: false,
      ).read(localizationProvider).getString('emailChangeSuccess');
    } else {
      messenger = null;
      successMessage = 'Email changed successfully!';
    }

    try {
      debugPrint(
        '📧 [EmailChange] Refreshing session to confirm email change...',
      );
      await auth.refreshSession().timeout(const Duration(seconds: 5));

      final updatedUser = auth.currentUser;
      debugPrint(
        '✅ [EmailChange] Email change confirmed! New email: ${updatedUser?.email}',
      );

      // Show success notification
      messenger?.showSnackBar(
        SnackBar(
          content: Text(successMessage),
          duration: const Duration(seconds: 3),
        ),
      );
    } on TimeoutException {
      debugPrint('⚠️ [EmailChange] Session refresh timed out');
    } catch (e) {
      debugPrint('⚠️ [EmailChange] Error refreshing session: $e');
    }
  } catch (e, st) {
    debugPrint('⚠️ [EmailChange] Error processing email change link: $e\n$st');
  }
}

/// Closes the in-app browser that hosted a provider sign-in flow, if one is
/// still on screen.
///
/// On iOS, `url_launcher` opens the OAuth URL (https) in an in-app
/// SFSafariViewController for [LaunchMode.platformDefault]. That view does not
/// dismiss itself when the provider redirects back into the app through the
/// `com.example.matchme://login-callback` custom scheme, so after a successful
/// login it lingers as a blank page the user must close by tapping "Done".
/// Android opens an external browser/Custom Tab instead, which the system
/// handles correctly, so nothing is done there. Calls are a no-op when no
/// browser is open (cold start, user already tapped "Done", etc.).
Future<void> _dismissLingeringAuthBrowser() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    await closeInAppWebView();
    debugPrint('[OAuth] Closed lingering in-app auth browser');
  } catch (e) {
    debugPrint('⚠️ [OAuth] Could not close in-app auth browser: $e');
  }
}

Future<void> _processOAuthDeepLink(Uri uri) async {
  debugPrint(
    '[BOOTSTRAP] [OAuth] Processing deep link: ${uri.scheme}://${uri.host}',
  );

  // Must match the redirect URI exactly: com.example.matchme://login-callback
  if (uri.scheme != 'com.example.matchme' || uri.host != 'login-callback') {
    debugPrint('[BOOTSTRAP] [OAuth] Not an OAuth callback link');
    return;
  }

  debugPrint('[BOOTSTRAP] [OAuth] Matched login-callback pattern');
  debugPrint('[BOOTSTRAP] [OAuth] Query params: ${uri.queryParameters}');

  // The callback has arrived (success or error) - take the user back out of
  // the in-app browser on iOS before processing it.
  await _dismissLingeringAuthBrowser();

  final code = uri.queryParameters['code']?.trim();
  final state = uri.queryParameters['state']?.trim();
  final error = uri.queryParameters['error']?.trim();
  final errorDescription = uri.queryParameters['error_description']?.trim();

  // Handle OAuth errors from sign-in flows even without a session context.
  // The user was not logged in before starting the OAuth flow, so
  // originalSession/originalUserId will be null — but we must still show the error.
  if (error != null && error.isNotEmpty) {
    debugPrint('[BOOTSTRAP] [OAuth] OAuth error: $error - $errorDescription');
    try {
      await CalendarSyncService.failGoogleImportOAuthFlow(
        errorDescription ?? error,
      );
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingProvider = prefs.getString('pending_oauth_provider') ?? '';
      await prefs.remove('pending_oauth_provider');
      // OAuth temp session now lives in SecureStorage (not plain prefs).
      await SensitiveSessionStore.instance.clearOAuthSession();
      final effectiveError = errorDescription ?? error;
      final key = effectiveError.toLowerCase().contains('cancel')
          ? 'authOAuthCancelled'
          : 'authOAuthProviderFailed';
      final errorMsg = '$key|||$effectiveError|||$pendingProvider';
      // Store in SharedPreferences so AuthScreen.build() can read it
      // even if authUiMessageProvider listener hasn't been registered yet.
      await prefs.setString('oauth_bootstrap_error', errorMsg);
      container.read(authUiMessageProvider.notifier).setMessage(errorMsg);
    } catch (_) {}
    return;
  }

  if (code == null || code.isEmpty) {
    debugPrint('[BOOTSTRAP] [OAuth] No auth code in callback');
    return;
  }

  // CRITICAL: Try to get the original user from memory first.
  // Code exchange requires a session context; skip stale links when none exists.
  var originalUserId = Supabase.instance.client.auth.currentUser?.id;
  var originalSession = Supabase.instance.client.auth.currentSession;
  debugPrint(
    '[BOOTSTRAP] [OAuth] Original session user (from memory): $originalUserId',
  );

  // If session is null but it was saved to SecureStorage during switchGoogleAccount,
  // the background service may have cleared the in-memory session
  if (originalSession == null && originalUserId == null) {
    debugPrint(
      '💾 [OAuth] In-memory session is null, checking SecureStorage...',
    );
    try {
      final savedSessionJson = await SensitiveSessionStore.instance
          .readOAuthSessionJson();
      final savedUserId = await SensitiveSessionStore.instance
          .readOAuthUserId();

      if (savedSessionJson != null && savedUserId != null) {
        debugPrint(
          '💾 [OAuth] Found saved session in SecureStorage: $savedUserId',
        );
        try {
          await Supabase.instance.client.auth
              .recoverSession(savedSessionJson)
              .timeout(const Duration(seconds: 5));
          debugPrint(
            '🔄 [OAuth] Forcing session persistence via refreshSession()...',
          );
          await Supabase.instance.client.auth.refreshSession().timeout(
            const Duration(seconds: 5),
          );
          debugPrint(
            '✅ [OAuth] Session refreshed and persisted to Supabase storage',
          );
          originalSession = Supabase.instance.client.auth.currentSession;
          originalUserId = savedUserId;
          debugPrint(
            '✅ [OAuth] Restored session from SecureStorage: $originalUserId',
          );
          try {
            final currentUser = Supabase.instance.client.auth.currentUser;
            final currentSession = Supabase.instance.client.auth.currentSession;
            if (currentUser != null && currentSession != null) {
              // SecureStorage is source of truth; plain shim kept for native
              // background service (see SensitiveSessionStore).
              await SensitiveSessionStore.instance.writeAuthTokens(
                userId: currentUser.id,
                accessToken: currentSession.accessToken,
                refreshToken: currentSession.refreshToken,
              );
              debugPrint(
                '💾 [OAuth] ✅ Persisted restored session to secure store: userId=$originalUserId',
              );
            }
          } catch (e) {
            debugPrint(
              '⚠️ [OAuth] Failed to persist restored session to secure store: $e',
            );
          }
        } on TimeoutException {
          debugPrint(
            '⚠️ [OAuth] recoverSession() from SecureStorage timed out after 5s, continuing anyway...',
          );
        } catch (e, st) {
          final errorMsg = e.toString().toLowerCase();
          if (errorMsg.contains('refresh_token_already_used') ||
              errorMsg.contains('invalid refresh token') ||
              errorMsg.contains('refresh token not found')) {
            // NEVER auto-sign-out: a stale oauth_original_* entry must not
            // log the user out. Only discard the stale switch-account
            // scratch keys and keep the current session as-is.
            debugPrint(
              '⚠️ [OAuth] Refresh token is stale/already used, discarding saved switch-account scratch keys only (keeping current session)',
            );
            await SensitiveSessionStore.instance.clearOAuthSession();
          } else {
            debugPrint(
              '⚠️ [OAuth] Failed to restore session from SecureStorage: $e',
            );
            debugPrint('⚠️ [OAuth] Stack trace: $st');
          }
          originalSession = Supabase.instance.client.auth.currentSession;
          originalUserId = originalSession?.user.id ?? savedUserId;
        }
      } else {
        debugPrint(
          'ℹ️ [OAuth] No saved session in SecureStorage (this is normal for direct OAuth without account switch)',
        );
      }
    } catch (e) {
      debugPrint('⚠️ [OAuth] Error reading SecureStorage: $e');
    }
  }

  // CRITICAL: If we have no session context at all, don't try to process the OAuth code
  // This prevents processing stale deep links from previous sessions when the app starts
  if (originalSession == null && originalUserId == null) {
    debugPrint(
      '[BOOTSTRAP] [OAuth] No session context found (not logged in and no saved session)',
    );
    debugPrint(
      '[BOOTSTRAP] [OAuth] Ignoring OAuth code exchange - this is likely a stale deep link from a previous session',
    );
    return;
  }

  String? callbackCode;
  try {
    callbackCode = code;

    debugPrint(
      '✅ [OAuth] Auth code received: ${code.isEmpty ? 'empty' : 'present'}, len=${code.length}',
    );
    debugPrint(
      '✅ [OAuth] State: ${state == null || state.isEmpty ? 'none' : 'present'}, len=${state?.length ?? 0}',
    );
    debugPrint(
      '🔓 [OAuth] Auth client current session before recovery: ${Supabase.instance.client.auth.currentSession?.user.id}',
    );

    final prefs = await SharedPreferences.getInstance();
    final switchAccountFlowActive = await SensitiveSessionStore.instance
        .hasOAuthSession();
    final persistedHandledCode = prefs.getString(_prefsLastHandledOAuthCodeKey);
    if (_oauthCodesInFlight.contains(code)) {
      debugPrint(
        'ℹ️ [OAuth] Callback code already being processed, ignoring duplicate',
      );
      return;
    }
    if (_lastHandledOAuthCode == code || persistedHandledCode == code) {
      debugPrint(
        'ℹ️ [OAuth] Callback code already handled previously, ignoring stale duplicate',
      );
      return;
    }
    _oauthCodesInFlight.add(code);

    // CRITICAL: Supabase should have ALREADY exchanged the code and updated its internal state
    // But the events might not have fired yet. Listen to auth changes and also poll.

    bool sessionRecovered = false;
    String? googleProviderToken;
    String? newGoogleUserId;
    String? googleProviderEmail;
    StreamSubscription? authListener;
    Future<void>? restorationFuture;

    String? extractGoogleIdentityToken(User? user) {
      final identities = user?.identities;
      if (identities == null) {
        return null;
      }
      for (final identity in identities) {
        if (identity.provider == 'google' && identity.identityData != null) {
          final identData = identity.identityData as Map<String, dynamic>;
          final token = (identData['access_token'] as String?)?.trim();
          if (token != null && token.isNotEmpty) {
            return token;
          }
        }
      }
      return null;
    }

    String? extractGoogleIdentityEmail(User? user) {
      final identities = user?.identities;
      if (identities == null) {
        return null;
      }
      for (final identity in identities) {
        if (identity.provider == 'google' && identity.identityData != null) {
          final identData = identity.identityData as Map<String, dynamic>;
          final email = (identData['email'] as String?)?.trim();
          if (email != null && email.isNotEmpty) {
            return email;
          }
        }
      }
      return null;
    }

    bool userHasGoogleIdentity(User? user) {
      final meta = user?.appMetadata;
      final directProvider = meta?['provider']?.toString().toLowerCase().trim();
      if (directProvider == 'google') {
        return true;
      }
      final providers = meta?['providers'];
      if (providers is List) {
        for (final provider in providers) {
          if (provider.toString().toLowerCase().trim() == 'google') {
            return true;
          }
        }
      }
      final identities = user?.identities;
      if (identities == null) {
        return false;
      }
      for (final identity in identities) {
        if (identity.provider == 'google') {
          return true;
        }
      }
      return false;
    }

    void cacheGoogleImportTokenIfPresent(Session session, String source) {
      final sessionProviderToken = userHasGoogleIdentity(session.user)
          ? session.providerToken?.trim()
          : null;
      final identityToken = extractGoogleIdentityToken(session.user);
      final previousToken = googleProviderToken;

      googleProviderToken =
          previousToken ?? sessionProviderToken ?? identityToken;

      if (googleProviderToken != previousToken && googleProviderToken != null) {
        googleProviderEmail =
            extractGoogleIdentityEmail(session.user) ?? session.user.email;
      }

      if (googleProviderToken != null &&
          googleProviderToken!.isNotEmpty &&
          googleProviderToken != previousToken) {
        unawaited(
          CalendarSyncService.cacheGoogleImportToken(
            token: googleProviderToken!,
            expiry: DateTime.now().add(const Duration(minutes: 55)),
            userEmail: googleProviderEmail,
          ),
        );
        debugPrint('✅ [OAuth] Cached Google token from $source');
      }
    }

    bool hasOAuthResult(Session session) {
      cacheGoogleImportTokenIfPresent(session, 'oauth-session-check');
      return session.user.id != originalUserId ||
          (googleProviderToken?.isNotEmpty == true);
    }

    bool shouldRestoreOriginalSession(Session session) {
      return switchAccountFlowActive &&
          originalSession != null &&
          originalUserId != null;
    }

    void scheduleRestorationIfNeeded(Session session) {
      if (restorationFuture != null || !shouldRestoreOriginalSession(session)) {
        return;
      }
      final newUserId = session.user.id;
      debugPrint(
        '🔐 [OAuth] DETECTED: Different user after OAuth: original=$originalUserId, new=$newUserId',
      );
      newGoogleUserId = newUserId;
      if (session.user.id != originalUserId) {
        debugPrint(
          'ðŸ” [OAuth] DETECTED: Different user after OAuth: original=$originalUserId, new=$newGoogleUserId',
        );
      } else {
        debugPrint(
          'ðŸ” [OAuth] DETECTED: Session changed during switch-account flow for user=$originalUserId; restoring original MatchMe session',
        );
      }
      debugPrint('🔐 [OAuth] ========== IMMEDIATE RESTORATION ==========');
      restorationFuture = _performSessionRestoration(
        originalSession,
        originalUserId,
        newGoogleUserId,
        googleProviderToken,
        googleProviderEmail,
      );
      unawaited(
        Future.microtask(() async {
          await authListener?.cancel();
          debugPrint(
            '🔓 [OAuth] Listener cancelled to prevent stream conflicts',
          );
        }),
      );
    }

    debugPrint(
      '🔓 [OAuth] Starting recovery with dual approach (listen + poll)...',
    );

    // Approach 1: Listen for auth state changes (most reliable for completed exchanges)
    final authFuture = Future<void>(() async {
      final completer = Completer<void>();
      authListener = Supabase.instance.client.auth.onAuthStateChange.listen(
        (data) {
          debugPrint(
            '🔓 [OAuth] Auth state change detected: event=${data.event}',
          );
          debugPrint('✅ [OAuth] Session from event: ${data.session?.user.id}');
          debugPrint(
            '✅ [OAuth] ProviderToken from event: ${data.session?.providerToken == null || data.session!.providerToken!.isEmpty ? 'NULL' : 'present'}, len=${data.session?.providerToken?.length ?? 0}',
          );

          if (data.session != null) {
            final session = data.session!;
            final newUserId = session.user.id;
            cacheGoogleImportTokenIfPresent(session, 'auth-listener');

            if (!hasOAuthResult(session)) {
              debugPrint(
                '⏳ [OAuth] Auth state change still reflects the original session, waiting...',
              );
              return;
            }

            debugPrint(
              '✅ [OAuth] Session recovered via auth state change: $newUserId',
            );
            scheduleRestorationIfNeeded(session);
            sessionRecovered = true;
            if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[OAuth] Auth stream error: $error');
        },
      );

      // Give listener time to trigger
      try {
        await completer.future.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        debugPrint(
          '⏱️ [OAuth] Auth state listener timeout (expected if already exchanged)',
        );
      }
    });

    // Approach 2: Aggressive polling to detect token update
    final pollFuture = Future<void>(() async {
      await Future.delayed(const Duration(milliseconds: 100));
      for (var i = 0; i < 40; i++) {
        try {
          final currentSession = Supabase.instance.client.auth.currentSession;
          if (currentSession != null) {
            if (!hasOAuthResult(currentSession)) {
              if (i % 10 == 0) {
                debugPrint(
                  '⏳ [OAuth] Polling attempt $i sees the original session only, continuing to wait...',
                );
              }
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }

            debugPrint(
              '✅ [OAuth] Session found via polling attempt $i: ${currentSession.user.id}',
            );
            debugPrint(
              '✅ [OAuth] ProviderToken from polling: ${currentSession.providerToken == null || currentSession.providerToken!.isEmpty ? 'NULL' : 'present'}, len=${currentSession.providerToken?.length ?? 0}',
            );

            scheduleRestorationIfNeeded(currentSession);
            sessionRecovered = true;
            break;
          }
          if (i % 10 == 0) {
            debugPrint(
              '🔓 [OAuth] Polling attempt $i (checking for updated session)...',
            );
          }
          await Future.delayed(const Duration(milliseconds: 250));
        } catch (e) {
          if (i == 0) debugPrint('⚠️ [OAuth] Polling error: $e');
        }
      }
    });

    // Run both approaches in parallel
    await Future.wait([authFuture, pollFuture]);

    // CRITICAL: Wait for restoration to complete before doing final verification
    if (restorationFuture != null) {
      debugPrint('🔓 [OAuth] Waiting for restoration to complete...');
      try {
        await restorationFuture!.timeout(const Duration(seconds: 6));
        debugPrint('✅ [OAuth] Restoration completed');
      } on TimeoutException {
        debugPrint('⚠️ [OAuth] Restoration timed out, but continuing...');
      } catch (e) {
        debugPrint('⚠️ [OAuth] Error during restoration wait: $e');
      }
    }

    // NOTE: Session restoration now happens as soon as we detect a user change.
    // We waited for it above before doing the final verification pass.

    // Final verification
    debugPrint('🔓 [OAuth] Recovery complete, checking final state...');
    final finalSession = Supabase.instance.client.auth.currentSession;
    final finalUser = Supabase.instance.client.auth.currentUser;
    final cachedGooglePayload =
        await CalendarSyncService.getCachedGoogleImportPayload();
    if (finalSession != null && sessionRecovered) {
      debugPrint(
        '✅ [OAuth] FINAL SUCCESS: Session confirmed: ${finalSession.user.id}',
      );
      debugPrint(
        '✅ [OAuth] Access token: ${finalSession.accessToken.isEmpty ? 'EMPTY' : 'present'}, len=${finalSession.accessToken.length}',
      );
      final hasUsableGoogleToken =
          finalSession.providerToken?.isNotEmpty == true ||
          cachedGooglePayload != null;
      debugPrint(
        '✅ [OAuth] ProviderToken available: ${hasUsableGoogleToken ? 'YES' : 'NO - WILL CAUSE TIMEOUT'}',
      );

      _lastHandledOAuthCode = code;
      await prefs.setString(_prefsLastHandledOAuthCodeKey, code);
      if (switchAccountFlowActive) {
        final flowId = prefs.getString(_prefsGoogleSwitchFlowIdKey);
        if (flowId != null && flowId.isNotEmpty) {
          await prefs.setString(_prefsGoogleSwitchCompletedFlowIdKey, flowId);
          debugPrint('[OAuth] Marked Google switch flow complete: $flowId');
        }
      }

      // Check identities array (where Supabase stores OAuth provider tokens)
      debugPrint('🔓 [OAuth] Checking identities array...');
      if (finalUser?.identities != null && finalUser!.identities!.isNotEmpty) {
        for (final identity in finalUser.identities!) {
          debugPrint('🔓 [OAuth] Identity: provider=${identity.provider}');
          if (identity.provider == 'google' && identity.identityData != null) {
            final data = identity.identityData as Map<String, dynamic>;
            final providerToken = data['access_token'] as String?;
            if (providerToken != null && providerToken.isNotEmpty) {
              debugPrint('✅ [OAuth] FOUND Google access token in identities!');
              debugPrint(
                '✅ [OAuth] Token in identities: present, len=${providerToken.length}',
              );
            } else {
              debugPrint(
                'ℹ️ [OAuth] No access_token in Google identity data (session providerToken/cache is being used instead)',
              );
            }
          }
        }
      } else {
        debugPrint('⚠️ [OAuth] No identities array or empty');
      }

      // CRITICAL: If providerToken is null, we need to force Supabase to refresh
      // This ensures the calendar sync service can access the provider token
      if ((finalSession.providerToken == null ||
              finalSession.providerToken!.isEmpty) &&
          cachedGooglePayload == null) {
        debugPrint(
          '⚠️ [OAuth] ProviderToken is empty! Attempting to refresh session...',
        );
        try {
          // Try to refresh to populate providerToken
          await Supabase.instance.client.auth.refreshSession();
          final refreshedSession = Supabase.instance.client.auth.currentSession;
          final token = refreshedSession?.providerToken;
          final tokenLength = token?.length ?? 0;
          debugPrint(
            '✅ [OAuth] After refresh - ProviderToken: ${token == null ? 'STILL NULL' : 'present'}, len=$tokenLength',
          );
        } catch (e) {
          debugPrint('⚠️ [OAuth] Refresh failed: $e');
        }
      }
    } else if (finalSession != null) {
      debugPrint(
        '⚠️ [OAuth] Session exists but recovery flag not set: ${finalSession.user.id}',
      );
    } else {
      debugPrint(
        '❌ [OAuth] ERROR: No session found after OAuth callback processing',
      );
      debugPrint(
        '❌ [OAuth] This means Supabase backend did not exchange the OAuth code for a token',
      );
    }

    // CLEANUP: Clear the saved session from secure store since we either restored it or didn't need it
    try {
      await SensitiveSessionStore.instance.clearOAuthSession();
      debugPrint('🧹 [OAuth] Cleared saved session from secure store');
    } catch (e) {
      debugPrint('⚠️ [OAuth] Error clearing secure store: $e');
    }

    authListener?.cancel();
  } catch (e, st) {
    debugPrint('❌ [OAuth] Error processing deep link: $e\n$st');
    _reportNonFatal(e, st);
  } finally {
    if (callbackCode != null && callbackCode.isNotEmpty) {
      _oauthCodesInFlight.remove(callbackCode);
    }
  }
}

void _traceBootstrap(String checkpoint) {
  print(
    '[STARTUP_DIAG] bootstrap=$checkpoint '
    'at=${DateTime.now().millisecondsSinceEpoch}',
  );
}

/// True when this launch was triggered by an OAuth callback that still needs
/// its code exchanged before the widget tree may build.
///
/// Web: the callback lands as `?code=&state=` (or an error param) in
/// [Uri.base]. Mobile: the OAuth redirect arrives as a deep link; on a
/// cold start via deep link, [PlatformDispatcher.defaultRouteName] carries
/// the callback URL (code+state). A normal icon launch sets it to `/`.
/// This is synchronous and immune to the stale `pending_oauth_provider`
/// prefs key that used to force the sequential path on every launch.
bool _isOAuthCallbackInFlight() {
  if (kIsWeb) {
    final uri = Uri.base;
    final fragment = uri.fragment;
    final queryParams = uri.queryParameters;
    if (queryParams.containsKey('error')) return true;
    return (queryParams.containsKey('code') &&
            queryParams.containsKey('state')) ||
        (fragment.contains('code=') && fragment.contains('state='));
  }
  // Mobile / desktop: check the launch route for an OAuth callback URL.
  try {
    final initialRoute =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (initialRoute.isEmpty || initialRoute == '/') return false;
    final uri = Uri.parse(initialRoute);
    final fragment = uri.fragment;
    final queryParams = uri.queryParameters;
    if (queryParams.containsKey('error')) return true;
    return (queryParams.containsKey('code') &&
            queryParams.containsKey('state')) ||
        (fragment.contains('code=') && fragment.contains('state='));
  } catch (_) {
    return false;
  }
}

Future<void> _processWebOAuthCodeDuringBootstrap() async {
  if (!kIsWeb) return;
  // Clear any stale OAuth error from a prior session so it doesn't persist
  // across app launches when no OAuth flow is actually in progress.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('oauth_bootstrap_error');
  } catch (_) {}

  // Must be called after Supabase.initialize() but BEFORE the widget tree
  // builds, because supabase_flutter's SupabaseAuth widget auto-registers a
  // deep-link listener (_handleDeeplink) that also calls getSessionFromUrl.
  // We process the code here, capture any error, and clear the URL so the
  // SDK listener has nothing to fail on.

  final uri = Uri.base;
  final fragment = uri.fragment;
  final queryParams = uri.queryParameters;

  // Handle OAuth error URLs (e.g. provider denied access).
  // The popup must close so the main window's signInWithOAuth() can proceed.
  final errorParam = queryParams['error']?.trim();
  if (errorParam != null && errorParam.isNotEmpty) {
    debugPrint('[BOOTSTRAP] [OAuth] OAuth error in URL: $errorParam');
    final errorDescription = queryParams['error_description']?.trim() ?? '';
    try {
      final prefs = await SharedPreferences.getInstance();
      final providerName = prefs.getString('pending_oauth_provider') ?? '';
      await prefs.remove('pending_oauth_provider');
      final effectiveError = errorDescription.isNotEmpty
          ? errorDescription
          : errorParam;
      final key = effectiveError.toLowerCase().contains('cancel')
          ? 'authOAuthCancelled'
          : 'authOAuthProviderFailed';
      final errorMsg = '$key|||$effectiveError|||$providerName';
      await prefs.setString('oauth_bootstrap_error', errorMsg);
    } catch (_) {}
    // Close popup if we're in one so opener's signInWithOAuth() rejects
    try {
      if (html.window.opener != null) {
        html.window.close();
      }
    } catch (_) {}
    return;
  }

  final hasCode =
      (queryParams.containsKey('code') && queryParams.containsKey('state')) ||
      (fragment.contains('code=') && fragment.contains('state='));

  if (!hasCode) return;

  debugPrint(
    '🔐 [BOOTSTRAP] Detected OAuth callback code in URL — processing during bootstrap',
  );

  // Read the pending provider BEFORE getSessionFromUrl so we can include it
  // in the error message if exchange fails.
  String providerName = '';
  try {
    final prefs = await SharedPreferences.getInstance();
    providerName = prefs.getString('pending_oauth_provider') ?? '';
    // Don't remove it yet — our appOnGenerateRoute may also try to read it
  } catch (_) {}

  try {
    await Supabase.instance.client.auth.getSessionFromUrl(Uri.base);
    // Success — code exchanged. The auth state listener will handle navigation.
    debugPrint('✅ [BOOTSTRAP] OAuth code exchanged successfully');
  } catch (error) {
    debugPrint('❌ [BOOTSTRAP] OAuth code exchange failed: $error');
    // Store the error in SharedPreferences so AuthScreen can pick it up.
    try {
      final prefs = await SharedPreferences.getInstance();
      final msg = 'authOAuthProviderFailed|||$error|||$providerName';
      await prefs.setString('oauth_bootstrap_error', msg);
    } catch (_) {}
  }

  // CRITICAL: Clear the URL so neither supabase_flutter's own handler nor
  // appOnGenerateRoute will try to process this stale code a second time.
  try {
    if (kIsWeb) {
      final cleaned = Uri.base.replace(path: '/', query: '', fragment: '');
      html.window.history.replaceState('', cleaned.toString());
      debugPrint('🔐 [BOOTSTRAP] Cleared OAuth code from URL');
    }
  } catch (_) {}
}

Future<_BootstrapInitResult> _bootstrapInitialize(
  ProviderContainer container,
) async {
  void traceBootstrap(String checkpoint) => _traceBootstrap(checkpoint);

  traceBootstrap('start');
  // Yield immediately so main() can call runApp and the first frame (loading indicator) paints before heavy work.
  await Future.delayed(Duration.zero);
  try {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (e, st) {
    _reportNonFatal(e, st);
  }

  Future<void> ensurePluginsReady() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    Object? lastError;
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await SharedPreferences.getInstance();
        return;
      } on MissingPluginException catch (e) {
        lastError = e;
        final backoffMs = min(300, 80 * (1 << min(attempt, 4)));
        await Future.delayed(Duration(milliseconds: backoffMs));
      } catch (e, st) {
        print(
          '[STARTUP_DIAG] shared_prefs_init_failed '
          'type=${e.runtimeType} error=$e',
        );
        if (e is PlatformException) {
          print(
            '[STARTUP_DIAG] shared_prefs_init_failed code=${e.code} '
            'message=${e.message} details=${e.details}',
          );
        }
        print('[STARTUP_DIAG] shared_prefs_init_failed stack=$st');
        rethrow;
      }
    }
    if (lastError != null) throw lastError;
  }

  await ensurePluginsReady();
  traceBootstrap('plugins_ready');

  // Apply an initial system-bar style that matches the user's saved theme so
  // the startup frames never flash a light status bar in dark mode. The runtime
  // theme builder re-applies the same style on every rebuild.
  try {
    var isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    var amoledEnabled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      amoledEnabled = prefs.getBool(AmoledThemeNotifier.prefsKey) ?? false;
      final savedThemeMode = prefs.getString('theme_mode');
      if (savedThemeMode == 'dark') {
        isDark = true;
      } else if (savedThemeMode == 'light') {
        isDark = false;
      }
    } catch (_) {}
    final barColor = isDark
        ? (amoledEnabled
              ? AppThemeTokens.amoledSurface
              : AppThemeTokens.darkSurface)
        : AppThemeTokens.lightSurface;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: barColor,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: barColor,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  } catch (e, st) {
    _reportNonFatal(e, st);
  }

  await initializeAppConfigCache();
  traceBootstrap('app_config_cache_ready');

  // Warm relaunch: preload the persisted localization cache (supported
  // languages + translations) straight from SharedPreferences, in parallel
  // with Hive/DotEnv/Supabase. The first Localization.build then paints real
  // strings on frame one and the router's localization gate (isLoading &&
  // supportedLanguages.isEmpty) never trips — previously it held the
  // pulsating loader for ~0.6-0.8s after the first frame on every online
  // warm relaunch. Best-effort; never fails startup.
  final l10nPreloadFuture = Localization.preloadForWarmLaunch();

  // NOTE: there is deliberately no connectivity/internet pre-check here.
  // The app's online/offline status is Supabase reachability and nothing else
  // (see `supabase_reachability.dart`): working internet with an unreachable
  // Supabase is still offline, so a transport or generate_204 probe could only
  // ever reach the wrong verdict. The single decision point is the deferred
  // reachability gate below, which never blocks the first paint.

  Future<void> initHive() async {
    Object? lastError;
    final maxAttempts = kIsWeb ? 3 : 12;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await Hive.initFlutter();
        return;
      } on MissingPluginException catch (e) {
        lastError = e;
        final backoffMs = min(500, 80 * (1 << min(attempt, 5)));
        await Future.delayed(Duration(milliseconds: backoffMs));
      }
    }
    if (lastError != null) throw lastError;
  }

  // Start Hive and DotEnv in parallel
  debugPrint(
    '⏱️ [BOOTSTRAP] Starting parallel init (Hive + DotEnv) at ${DateTime.now().millisecondsSinceEpoch}',
  );
  final hiveInitFuture = initHive();

  // Open the encrypted OfflineImageCache box the moment Hive is ready —
  // chained directly off hiveInitFuture, NOT behind the later l10n/config
  // awaits. The first SignedImage read on Home used to trigger this box-open
  // itself at the first frame; every avatar read queues behind the multi-MB
  // encrypted box decode (~1.4-1.8s) and all avatars pop in together. Purely
  // local I/O; fire-and-forget, best-effort, never blocks bootstrap.
  unawaited(
    hiveInitFuture
        .then((_) => OfflineImageCache.instance.warmup())
        .then(
          (_) => debugPrint(
            '⏱️ [BOOTSTRAP] OfflineImageCache box opened at ${DateTime.now().millisecondsSinceEpoch}',
          ),
        )
        .catchError((e, st) {
          _reportNonFatal(e, st);
        }),
  );

  final dotenvFuture = dotenv.load(fileName: 'assets/.env').catchError((e, st) {
    _reportNonFatal(e, st);
  });

  // Wait for DotEnv to load BEFORE resolving config, as config accesses dotenv.env
  await dotenvFuture;
  debugPrint(
    '⏱️ [BOOTSTRAP] DotEnv loaded at ${DateTime.now().millisecondsSinceEpoch}',
  );

  final configFuture = _resolveSupabaseRuntimeConfig();

  // Wait for config to be ready before starting Supabase
  final config = await configFuture;
  debugPrint(
    '⏱️ [BOOTSTRAP] Config resolved at ${DateTime.now().millisecondsSinceEpoch}',
  );
  final supabaseUrl = config.url;
  final supabaseAnonKey = config.anonKey;

  if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
    return _BootstrapInitResult(
      errorApp: ProviderScope(
        child: MissingSupabaseKeyApp(
          missingUrl: supabaseUrl.isEmpty,
          missingKey: supabaseAnonKey.isEmpty,
        ),
      ),
    );
  }

  // Supabase reachability is the one and only online/offline signal, so the
  // bootstrap gate below replaces the old generate_204 "dead carrier/wifi"
  // probe and the 3× rapid RPC loop. One `health_check` round trip with a
  // budget larger than Supabase's own gateway timeout decides it, and a
  // genuine outage is entered in one shot instead of three doomed requests.

  // Start Supabase init in parallel with the remaining Hive init.
  debugPrint(
    '⏱️ [BOOTSTRAP] Starting Supabase.initialize at ${DateTime.now().millisecondsSinceEpoch}',
  );

  // Single init attempt with a short timeout (client is created synchronously;
  // the await is only for recoverSession). Relaxed to 5s for mobile release
  // cold starts (2s caused spurious timeouts on slow TLS).
  const supabaseInitTimeout = Duration(seconds: 5);

  // NOTE: the call's synchronous prologue (_init) creates the client and marks
  // the Supabase singleton initialized before its first await — so merely
  // CALLING initialize here (without awaiting) makes every supabase.auth
  // access in the app safe. Only currentSession/currentUser stay null until
  // session recovery lands.
  Future<Supabase>? supabaseInitFuture;
  var forceSequentialPath = false;
  try {
    supabaseInitFuture =
        Supabase.initialize(
          url: supabaseUrl,
          publishableKey: supabaseAnonKey,
          // Security: persist the SDK session (access + refresh tokens) in secure
          // storage (Keychain / EncryptedSharedPreferences) instead of the default
          // plaintext SharedPreferences / localStorage.
          authOptions: FlutterAuthClientOptions(
            localStorage: SecureLocalStorage(
              persistSessionKey: SecureLocalStorage.buildSessionKey(
                supabaseUrl,
              ),
            ),
          ),
          realtimeClientOptions: RealtimeClientOptions(
            transport: (url, headers) =>
                WebSocketChannel.connect(Uri.parse(url)),
          ),
        ).timeout(
          supabaseInitTimeout,
          onTimeout: () {
            debugPrint(
              '⚠️ [BOOTSTRAP] Supabase initialization timed out after ${supabaseInitTimeout.inSeconds}s',
            );
            throw TimeoutException(
              'Supabase initialization timeout',
              supabaseInitTimeout,
            );
          },
        );
  } catch (e) {
    // Synchronous construction failure (malformed URL etc.): no client
    // exists, so the fast path cannot seed a session — take the sequential
    // path so this surfaces through its existing error handling.
    debugPrint('⚠️ [BOOTSTRAP] Supabase client construction failed: $e');
    forceSequentialPath = true;
    supabaseInitFuture = Future<Supabase>.error(e);
  }

  // OAuth callbacks must keep the sequential path: the code exchange has to
  // complete BEFORE the widget tree builds (supabase_flutter's deep-link
  // handler races us for the code otherwise). Warm relaunches — the common
  // case — take the fast path below.
  if (!forceSequentialPath) {
    forceSequentialPath = _isOAuthCallbackInFlight();
  }

  // FAST-PATH SEED: start the local session seed immediately so it runs in
  // parallel with Hive — a warm relaunch then routes on the seeded session
  // without ever awaiting Supabase.initialize (whose secure-storage reads +
  // deep-link platform channels cost 1.4-2.3s on cold Keychain/Keystore).
  Future<bool>? sessionSeedFuture;
  if (!forceSequentialPath) {
    sessionSeedFuture = SessionService.seedSessionFromLocalStorage();
  }

  // Wait for Hive to be ready before starting LocalDb
  await hiveInitFuture;
  debugPrint(
    '⏱️ [BOOTSTRAP] Hive initialized at ${DateTime.now().millisecondsSinceEpoch}',
  );

  // The l10n preload is a pure SharedPreferences read started above; by now
  // (Hive open takes far longer) it is certainly done, but await it so the
  // first Localization.build is guaranteed to find the warm-launch snapshot.
  // Still fully parallel with the pending Supabase.initialize below.
  await l10nPreloadFuture;

  // Start LocalDb init (depends on Hive)
  // We do NOT await this here, so the UI can load while Hive opens boxes.
  unawaited(
    LocalDbService.instance
        .catchError((e, st) {
          _reportNonFatal(e, st);
          throw e;
        })
        .then(
          (_) => debugPrint(
            '⏱️ [BOOTSTRAP] LocalDbService initialized at ${DateTime.now().millisecondsSinceEpoch}',
          ),
        ),
  );

  // Initialize OfflineMutationQueue (depends on Hive)
  unawaited(
    OfflineMutationQueue.instance
        .initialize()
        .catchError((e, st) {
          _reportNonFatal(e, st);
          // Don't throw - mutation queue is not critical for app startup
        })
        .then(
          (_) => debugPrint(
            '⏱️ [BOOTSTRAP] OfflineMutationQueue initialized at ${DateTime.now().millisecondsSinceEpoch}',
          ),
        ),
  );

  // Warm signed-photo-URL memory from local storage so matched-user photos
  // resolve instantly on UI startup (memory + disk, no network wait).
  // Fire-and-forget: SharedPreferences read, never blocks first paint.
  unawaited(
    StorageHelper.warmUpPersistedUrlCache().catchError((e, st) {
      _reportNonFatal(e, st);
    }),
  );

  if (forceSequentialPath) {
    // SLOW PATH (OAuth callback in flight, or client construction failed):
    // preserve the pre-existing sequential behavior — the OAuth code exchange
    // must complete BEFORE the widget tree builds, and construction failures
    // surface through the hard error screen.
    final supabaseError = await _runPostSupabaseInitBackground(
      container,
      supabaseUrl,
      supabaseAnonKey,
      supabaseInitFuture,
    );
    if (supabaseError != null) {
      throw Exception(supabaseError);
    }
    ResumeDiagnostics.log('Bootstrap initialization completed');
    traceBootstrap('returning_success_sequential');
    return _BootstrapInitResult(
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: supabaseAnonKey,
    );
  }

  // FAST PATH (warm relaunch / normal cold start): never await
  // Supabase.initialize. The local session seed started above (in parallel
  // with Hive) has bounded internal timeouts; this outer timeout guarantees
  // bootstrap returns even if a secure-storage platform channel stalls —
  // authStateProvider's 1s fallback timer then owns the routing.
  traceBootstrap('fast_path_awaiting_session_seed');
  var sessionSeeded = false;
  try {
    sessionSeeded = await (sessionSeedFuture ?? Future<bool>.value(false))
        .timeout(
      const Duration(milliseconds: 3000),
      onTimeout: () => false,
    );
  } catch (_) {}
  traceBootstrap('fast_path_session_seed_done seeded=$sessionSeeded');

  // Providers read the runtime config at first build — set it before
  // returning. Idempotent; the background chain sets it again after init.
  setRuntimeSupabaseConfig(url: supabaseUrl, anonKey: supabaseAnonKey);
  traceBootstrap('runtime_config_set');

  // Everything that previously ran after `await supabaseInitFuture` now
  // completes in the background: OAuth processing, deep-link handler,
  // reachability gate, session validation, bootstrapUser resolution,
  // BGSESSION, chat keys, and the cache warmer.
  unawaited(() async {
    try {
      final supabaseError = await _runPostSupabaseInitBackground(
        container,
        supabaseUrl,
        supabaseAnonKey,
        supabaseInitFuture!,
      );
      if (supabaseError != null) {
        // Non-network init failure. The UI is already running from cache —
        // continue offline instead of surfacing the hard error screen
        // (offline-first policy). Missing URL/key config errors were caught
        // before this point and still show the error app.
        debugPrint(
          '❌ [BOOTSTRAP] Background Supabase init failed (continuing offline): $supabaseError',
        );
        try {
          setRuntimeSupabaseConfig(url: supabaseUrl, anonKey: supabaseAnonKey);
        } catch (_) {}
        offlineCacheManager.setSupabaseAvailability(false, force: true);
      }
    } catch (e, st) {
      _reportNonFatal(e, st);
    }
  }());

  ResumeDiagnostics.log('Bootstrap initialization completed');
  traceBootstrap('returning_success_fast');

  return _BootstrapInitResult(
    supabaseUrl: supabaseUrl,
    supabaseAnonKey: supabaseAnonKey,
  );
}

/// Runs everything that used to sit on the critical path AFTER
/// `await supabaseInitFuture` inside [_bootstrapInitialize]. Called either
/// sequentially (slow path — OAuth callbacks) or fire-and-forget (fast path).
///
/// Returns the non-network init error message (for the slow path to throw),
/// or null on success / handled network failure (offline mode already
/// applied). Never throws — network errors are absorbed into offline mode.
Future<String?> _runPostSupabaseInitBackground(
  ProviderContainer container,
  String supabaseUrl,
  String supabaseAnonKey,
  Future<Supabase> supabaseInitFuture,
) async {
  String? supabaseError;
  User? bootstrapUser;
  // NOTE: session policy — bootstrap must never clear the cached session.
  // (Previously a `bootstrapSessionCleared` flag was set when JWT validation
  // failed; removed so expired tokens keep the user logged in. Only
  // auth.forced_sign_out_days or an explicit UI logout may sign out.)
  try {
    final supabaseInstance = await supabaseInitFuture;
    _traceBootstrap('post_init_supabase_initialized');
    debugPrint(
      '⏱️ [BOOTSTRAP] Supabase initialized at ${DateTime.now().millisecondsSinceEpoch}',
    );

    // Yield so the UI thread can paint before we kick off any further work.
    await Future.delayed(Duration.zero);

    // Process any OAuth callback code in the URL BEFORE the widget tree builds.
    // supabase_flutter's SupabaseAuth widget auto-registers a deep-link handler
    // that calls getSessionFromUrl — if we don't consume the code and clear the
    // URL first, the SDK handler will throw an unhandled DartError on failure.
    // (Web-only no-op elsewhere; on the fast path there is no code to consume.)
    await _processWebOAuthCodeDuringBootstrap();

    // Clear stale pending_oauth_provider: if the launch route was not an
    // OAuth callback (fast path already ruled that out), any leftover key
    // from an abandoned flow is noise — remove it so it never forces the
    // sequential path again.
    if (!kIsWeb) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final pending =
            prefs.getString('pending_oauth_provider')?.trim() ?? '';
        if (pending.isNotEmpty) {
          await prefs.remove('pending_oauth_provider');
          debugPrint(
            '🧹 [BOOTSTRAP] Cleared stale pending_oauth_provider="$pending"',
          );
        }
      } catch (_) {}
    }

    // Setup deep link handler for OAuth callbacks (CRITICAL for calendar sync)
    // Must be done after Supabase is initialized
    unawaited(_setupDeepLinkHandler());

    // Windows WNS push channel (MSIX): fire-and-forget so bootstrap is never
    // gated on the native call. collectSessionInfo() picks the cached URI up
    // on the next session registration.
    unawaited(_registerWindowsWnsChannel());

    // Verify global instance matches
    if (supabaseInstance.client != Supabase.instance.client) {
      debugPrint(
        '⚠️ [BOOTSTRAP] WARNING: Returned client != Supabase.instance.client',
      );
    }

    // The single online/offline decision point of the whole bootstrap. One
    // `health_check` round trip decides it: the budget is larger than Supabase's
    // own gateway timeout, so a database stall reads as "the server answered
    // but cannot serve us" and is reported as such instead of being confused
    // with a dead network. No confirming attempt here — the runtime monitor
    // re-probes within seconds and restores the online state automatically, so
    // a false negative only costs a cached-data splash, not a stuck app.
    //
    // COLD-START SPEED: the gate is NEVER awaited on the critical path. On a
    // warm relaunch we start optimistic-online — `isSupabaseAvailable` already
    // defaults to true — and the cached home paints immediately. On a first
    // login the cold-cache hold in ProfileCheckScreen owns the waiting while
    // this probe runs in the background and flips the app offline within its
    // budget if the server is unreachable; the initial home sync then fails
    // fast and the escape hatch enters the app with the offline banner.
    _traceBootstrap('reachability_gate_deferred');
    unawaited(_runPostReachabilityGate());

    // Validate recovered session on all platforms immediately after Supabase init.
    // If the restored session has an invalid/expired JWT, clear it and force re-login.
    // Previously this was Web-only — moved to universal so mobile also catches stale JWTs.
    //
    // COLD-START SPEED: the same refresh + getUser + provider-invalidation work now
    // runs in the background ([_runBackgroundSessionValidation]) once the first frame
    // has painted, so a warm relaunch reveals the cached home without waiting on up to
    // three 1.2s network round trips. The permissive session policy is unchanged —
    // this never signs the user out; it only proactively refreshes an expiring token
    // and invalidates the token-scoped providers so they re-init with the fresh token.
    final recoveredSession = Supabase.instance.client.auth.currentSession;
    _traceBootstrap('session_check hasSession=${recoveredSession != null}');
    if (recoveredSession != null) {
      debugPrint('⏱️ [BOOTSTRAP] Session recovered, deferring JWT validation off the startup path');
      unawaited(_runBackgroundSessionValidation(recoveredSession, container));
    }

    // Never auto-clear: keep whatever session the SDK recovered, even if
    // its JWT failed validation above (it may just be expired; a later
    // refresh will renew it).
    bootstrapUser = Supabase.instance.client.auth.currentUser;
    _traceBootstrap('current_user_resolved hasUser=${bootstrapUser != null}');

    if (bootstrapUser == null &&
        Supabase.instance.client.auth.currentSession != null) {
      if (!offlineCacheManager.isSupabaseAvailable) {
        debugPrint(
          '⏱️ [BOOTSTRAP] Skipping bootstrapUser getUser fallback (offline)',
        );
      } else {
        try {
          final refreshed = await Supabase.instance.client.auth
              .getUser()
              .timeout(const Duration(milliseconds: 1200));
          bootstrapUser = refreshed.user;
        } catch (e) {
          final isNetwork =
              e is TimeoutException || isExpectedOfflineFailure(e);
          if (isNetwork) {
            debugPrint(
              '⚠️ [BOOTSTRAP] bootstrapUser getUser timeout/network -> confirming offline',
            );
            await _applySupabaseUnreachable('bootstrapUser getUser failed');
          } else {
            debugPrint('⚠️ [BOOTSTRAP] bootstrapUser getUser error: $e');
          }
        }
      }
    }

    setRuntimeSupabaseConfig(url: supabaseUrl, anonKey: supabaseAnonKey);
    _traceBootstrap('runtime_config_set');

    // Schedule BGSESSION after the first frame so the cold-start paint is not
    // further delayed. The coordinator coalesces and debounces these calls.
    if (bootstrapUser != null) {
      final url = runtimeSupabaseUrl;
      debugPrint(
        '[BGSESSION] bootstrap: scheduling registerSession userId=${bootstrapUser.id} url=$url',
      );
      if (kIsWeb) {
        try {
          WebNotificationService.setServiceWorkerUserId(bootstrapUser.id);
        } catch (_) {}
      }
      final platformText = kIsWeb
          ? 'web'
          : defaultTargetPlatform == TargetPlatform.android
          ? 'android'
          : defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'unknown';
      final capturedUserId = bootstrapUser.id;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          if (!BootstrapDeferral.isAppReady) return;
          SessionRegistrationCoordinator.instance.schedule(
            userId: capturedUserId,
            platform: platformText,
            source: 'bootstrap',
          );
        }),
      );
    }
  } catch (e) {
    final errorMessage = e.toString();
    final isTimeout =
        e is TimeoutException ||
        errorMessage.toLowerCase().contains('timeout') ||
        errorMessage.contains('TimeoutException');
    final isNetwork = isTimeout || isExpectedOfflineFailure(e);

    if (isNetwork) {
      debugPrint(
        '⚠️ [BOOTSTRAP] Supabase initialization failed (network/timeout) - will use offline mode with cached data: $e',
      );
      // Supabase never came up, so it cannot be reached: offline, and the gate
      // below is skipped because there is nothing left to confirm.
      offlineCacheManager.setSupabaseAvailability(false, force: true);
      // Ensure runtime config is still set so providers can read cached data paths
      try {
        setRuntimeSupabaseConfig(url: supabaseUrl, anonKey: supabaseAnonKey);
      } catch (_) {}
      // Try to recover persisted session so authProvider can show cached user immediately
      try {
        await SessionService.recoverPersistedSupabaseSession(
          timeout: const Duration(seconds: 1),
        );
      } catch (_) {}
    } else {
      debugPrint(
        '❌ [BOOTSTRAP] Supabase initialization error (not timeout/network): $e',
      );
      supabaseError = errorMessage;
    }
  }

  if (supabaseError != null) {
    return supabaseError;
  }

  // Note: We deliberately do NOT await localDbInitFuture here.
  // This allows the UI to render "Loading..." states instead of blocking on splash screen.

  try {
    container.read(outboxSyncProvider);
  } catch (e, st) {
    _reportNonFatal(e, st);
  }

  // Initialize encrypted cache and chat key provider for current user.
  // These touch local storage + crypto and were previously awaited on the
  // critical startup path. The chat UI gates on chatKeyProvider via its own
  // loading state, so deferring past the first frame keeps the initial paint
  // snappy without affecting correctness.
  final currentUser =
      bootstrapUser ?? Supabase.instance.client.auth.currentUser;
  if (currentUser != null) {
    final capturedUserId = currentUser.id;
    unawaited(_runPostFrameChatKeyInit(capturedUserId));
    // Fault the local home snapshot into the OS page cache (after the first
    // frames, so it never competes with the initial paint) — the Home
    // streams then decode already-warm pages on a relaunch.
    unawaited(() async {
      while (!BootstrapDeferral.isAppReady) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
      await StartupCacheWarmer.warmHomeCaches(capturedUserId);
    }());
  }

  ResumeDiagnostics.log('Bootstrap initialization completed');
  _traceBootstrap('post_init_complete');

  return null;
}

/// Lightweight coordinator that signals when the first real app frame has
/// rendered, so other bootstrap tasks can be safely unblocked without
/// re-introducing the cold-start jank they used to cause.
class BootstrapDeferral {
  BootstrapDeferral._();
  static bool _appReady = false;
  static bool get isAppReady => _appReady;
  static void markAppReady() {
    if (_appReady) return;
    _appReady = true;
  }
}

Future<void> _runPostFrameChatKeyInit(String userId) async {
  // Wait until the first real frame has rendered, then yield once more so
  // frame production has a chance to recover from the bootstrap load.
  while (!BootstrapDeferral.isAppReady) {
    await Future.delayed(const Duration(milliseconds: 30));
  }
  await Future.delayed(Duration.zero);
  try {
    await EncryptedCacheService.instance.initialize(userId);
    debugPrint('⏱️ [BOOTSTRAP] EncryptedCacheService initialized');
  } catch (e, st) {
    _reportNonFatal(e, st);
  }
  try {
    container.read(chatKeyProvider);
    final chatKeyNotifier = container.read(chatKeyProvider.notifier);
    await chatKeyNotifier.initializationComplete;
    final keyState = container.read(chatKeyProvider);
    debugPrint(
      '⏱️ [BOOTSTRAP] ChatKeyProvider loaded: isLoaded=${keyState.isLoaded} activeKey=${keyState.activeKey?.id} isLocked=${keyState.isLocked} hasLocalKey=${keyState.privateKeyBytes != null} hasRecoveryKey=${keyState.hasRecoveryKey} hasPasswordWrapper=${keyState.hasPasswordWrapper}',
    );
    // Key rotation removed: Keys are never automatically replaced to ensure all messages remain readable
    if (keyState.isLoaded && keyState.activeKey == null) {
      // Only set up encryption if no key exists at all (new user)
      await chatKeyNotifier.setupEncryption();
      debugPrint('⏱️ [BOOTSTRAP] Chat encryption set up for new user');
    }
    debugPrint('⏱️ [BOOTSTRAP] ChatKeyProvider initialized');
  } catch (e, st) {
    // Best-effort bootstrap: a rejected/expired token, a rate-limited backend
    // or a DB error must not surface as a framework error. The provider keeps
    // local-only state and retries (30s timer / resume refresh).
    debugPrint('⏱️ [BOOTSTRAP] ChatKeyProvider setup deferred: $e');
    debugPrintStack(stackTrace: st, label: 'ChatKeyProvider setup deferred');
  }
}

/// Runs the Supabase reachability gate off the startup critical path.
///
/// Waits for the first real frame to render, then runs
/// [_applySupabaseReachabilityGate]. Bootstrap starts optimistic-online
/// (`isSupabaseAvailable` defaults to true) on every path — warm relaunch
/// and first login alike — and the runtime connectivity monitor keeps
/// re-probing, so deferring this does not change the final online/offline
/// verdict — it only stops the health-check round trip from delaying the
/// first paint. On a first login the cold-cache hold in ProfileCheckScreen
/// owns the waiting while this probe flips the app offline within its
/// budget if the server is unreachable.
Future<void> _runPostReachabilityGate() async {
  while (!BootstrapDeferral.isAppReady) {
    await Future.delayed(const Duration(milliseconds: 30));
  }
  await Future.delayed(Duration.zero);
  try {
    final reachable = await _applySupabaseReachabilityGate();
    if (!reachable) {
      debugPrint(
        '⏱️ [BOOTSTRAP] Forced offline after the (deferred) Supabase reachability gate failed',
      );
    }
  } catch (e) {
    debugPrint('⏱️ [BOOTSTRAP] Deferred reachability gate error: $e');
  }
}

/// Validates + proactively refreshes the recovered session off the startup
/// critical path.
///
/// This is the exact work that used to block the splash (up to three 1.2s
/// network round trips): refresh an expiring token, call getUser to confirm the
/// JWT, clear stale OAuth errors, and invalidate the token-scoped providers so
/// they re-init with the fresh token. It runs after the first frame has painted
/// so a warm relaunch reveals the cached home instantly while the session is
/// validated in the background.
///
/// POLICY (unchanged): this NEVER signs the user out. A failed/invalid JWT or a
/// refresh race only keeps the cached session so the user stays logged in; a
/// later refresh renews it. Only `auth.forced_sign_out_days` or an explicit UI
/// logout may clear the session.
Future<void> _runBackgroundSessionValidation(
  Session recoveredSession,
  ProviderContainer container,
) async {
  while (!BootstrapDeferral.isAppReady) {
    await Future.delayed(const Duration(milliseconds: 30));
  }
  await Future.delayed(Duration.zero);

  void invalidateTokenProviders() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      container.invalidate(recentChatsProvider(userId));
      container.invalidate(recentMatchesProvider(userId));
      container.invalidate(matchNotificationProvider);
    } catch (e) {
      debugPrint(
        '⚠️ [BOOTSTRAP] Provider invalidation after refresh failed: $e',
      );
    }
  }

  try {
    // Skip network-dependent session validation when offline to avoid hanging
    // on network timeouts.
    if (!offlineCacheManager.isSupabaseAvailable) {
      debugPrint('⏱️ [BOOTSTRAP] Skipping JWT validation (offline)');
      return;
    }

    // Proactively check token expiry and attempt refresh before calling getUser().
    // This avoids a 403 error from the server for an expired access token.
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final expiresAt = recoveredSession.expiresAt;
    if (expiresAt != null && expiresAt <= now + 30) {
      debugPrint(
        '⏱️ [BOOTSTRAP] Token expired or expiring soon (exp=$expiresAt), attempting refresh...',
      );
      bool refreshSucceeded = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          // 4s per attempt: the old 1.2s budget times out on a healthy but
          // loaded backend during cold start (DNS + TLS + a slow first
          // response), which produced false "network/timeout" failures from
          // background validation that runs in parallel with the monitor.
          await SessionService.safeRefreshSession(
            timeout: const Duration(milliseconds: 4000),
          ).timeout(const Duration(milliseconds: 4000));
          debugPrint('✅ [BOOTSTRAP] Token refreshed successfully');
          refreshSucceeded = true;
          // Invalidate critical providers so they re-init with the fresh token.
          invalidateTokenProviders();
          break;
        } catch (refreshError) {
          final isNetwork =
              refreshError is TimeoutException ||
              isExpectedOfflineFailure(refreshError) ||
              refreshError.toString().toLowerCase().contains(
                'socketexception',
              ) ||
              refreshError.toString().toLowerCase().contains('timeout');
          if (isNetwork) {
            debugPrint(
              '⚠️ [BOOTSTRAP] Token refresh attempt $attempt failed (network/timeout): $refreshError',
            );
            if (attempt < 3) {
              await Future.delayed(const Duration(milliseconds: 200));
              continue;
            }
            debugPrint(
              '⚠️ [BOOTSTRAP] Token refresh failed after 3 attempts -> confirming offline with Supabase',
            );
            await _applySupabaseUnreachable('token refresh failed');
            break;
          } else {
            final lower = refreshError.toString().toLowerCase();
            if (lower.contains('refresh_token_already_used') ||
                lower.contains('already used')) {
              debugPrint(
                '⚠️ [BOOTSTRAP] Token refresh race (already_used) - native may have refreshed, continuing with current session',
              );
              if (Supabase.instance.client.auth.currentSession != null) {
                refreshSucceeded = true;
                invalidateTokenProviders();
              }
            } else {
              debugPrint(
                '⏱️ [BOOTSTRAP] Token refresh failed (expected if refresh token also expired): $refreshError',
              );
            }
            break;
          }
        }
      }
      if (!refreshSucceeded && !offlineCacheManager.isSupabaseAvailable) {
        debugPrint('⏱️ [BOOTSTRAP] Skipping getUser due to offline after refresh');
        return;
      }
    }

    if (!offlineCacheManager.isSupabaseAvailable) {
      debugPrint('⏱️ [BOOTSTRAP] Skipping getUser (already offline)');
      return;
    }

    bool validationDone = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        // 4s per attempt: 1.2s is below the round-trip time of a healthy but
        // loaded backend during cold start, so getUser timed out against a
        // server that was actually reachable and forced an unnecessary
        // offline confirmation.
        await Supabase.instance.client.auth.getUser().timeout(
          const Duration(milliseconds: 4000),
        );
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('oauth_bootstrap_error');
        } catch (_) {}
        debugPrint('✅ [BOOTSTRAP] Session JWT is valid');
        validationDone = true;
        break;
      } catch (e) {
        final isNetwork =
            e is TimeoutException || isExpectedOfflineFailure(e);
        if (isNetwork) {
          debugPrint(
            '⚠️ [BOOTSTRAP] getUser attempt $attempt failed (network/timeout): $e',
          );
          if (attempt < 3) {
            await Future.delayed(const Duration(milliseconds: 200));
            continue;
          }
          debugPrint(
            '⚠️ [BOOTSTRAP] getUser failed after 3 attempts -> confirming offline, using cached session',
          );
          await _applySupabaseUnreachable('getUser failed');
          break;
        }
        // POLICY: never auto-sign-out here — keep the cached session.
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('invalid jwt') ||
            errorMsg.contains('jwt expired') ||
            errorMsg.contains('token is expired') ||
            errorMsg.contains('unauthorized') ||
            errorMsg.contains('403') ||
            errorMsg.contains('401')) {
          debugPrint(
            '⏱️ [BOOTSTRAP] Session JWT validation failed ($e) — keeping cached session, NOT signing out (permissive session policy)',
          );
          unawaited(
            SessionService.persistSignOutReason(
              reason: e.toString(),
              source: 'bootstrapGetUser-kept-session',
            ),
          );
        } else {
          debugPrint('⚠️ [BOOTSTRAP] Session validation error (non-auth): $e');
        }
        validationDone = true;
        break;
      }
    }
    if (!validationDone) {
      debugPrint('⚠️ [BOOTSTRAP] Validation loop ended without result');
    }
  } catch (e, st) {
    debugPrint('⏱️ [BOOTSTRAP] Background session validation error: $e');
    debugPrintStack(
      stackTrace: st,
      label: 'Background session validation error',
    );
  }
}

/// The single online/offline decision point of the bootstrap.
///
/// Runs deferred, after the first frame has painted (see
/// [_runPostReachabilityGate]), so it is no longer racing the splash and uses
/// the same generous budget as the runtime monitor. A 1.5s gate budget used to
/// expire while a cold-start probe was still healthy in flight (DNS + TLS plus
/// a loaded backend routinely exceed it), flipping the app offline until the
/// monitor restored it seconds later. The request is cancelled when the budget
/// expires instead of being left to run.
///
/// One attempt, no confirming attempt: a false negative only costs cached
/// mode briefly, because the runtime monitor keeps the full budget, confirms
/// within seconds and restores the online state by itself.
///
/// Goes offline with `force: true` so the app is not additionally delayed by
/// OfflineCacheManager's grace period. Returns true when the app may talk to
/// Supabase.
Future<bool> _applySupabaseReachabilityGate() async {
  final stopwatch = Stopwatch()..start();
  final result = await probeSupabaseReachability(
    timeout: platformProbeTimeout(kSupabaseProbeTimeout),
    log: (message) => debugPrint('⏱️ [BOOTSTRAP] $message'),
  );
  stopwatch.stop();
  if (result.isReachable) {
    debugPrint(
      '✅ [BOOTSTRAP] Supabase reachable -> online (${stopwatch.elapsedMilliseconds}ms)',
    );
    return true;
  }
  debugPrint(
    '⏱️ [BOOTSTRAP] Supabase unreachable after ${stopwatch.elapsedMilliseconds}ms '
    '($result) -> offline, serving cached data. The connectivity monitor will '
    'keep probing and will restore online mode as soon as Supabase answers.',
  );
  offlineCacheManager.setSupabaseAvailability(false, force: true);
  return false;
}

/// Confirms a Supabase round trip before the app is forced offline.
///
/// A single failed auth/REST call is not evidence of being offline: cold-start
/// DNS + TLS on mobile routinely exceeds a second or two, and forcing offline
/// here also clears `forceOnline`, which disables background matching and stops
/// GPS for every user on a merely slow network. So the confirmation is a real
/// `health_check` round trip with a larger budget — never a transport hint and
/// never a generic internet probe, because a working internet with an
/// unreachable Supabase is offline for this app. Returns true when offline mode
/// was applied.
Future<bool> _applySupabaseUnreachable(String reason) async {
  final result = await probeSupabaseReachability(
    confirm: true,
    log: (message) => debugPrint('⏱️ [BOOTSTRAP] $message'),
  );
  if (result.isReachable) {
    debugPrint(
      '⏱️ [BOOTSTRAP] $reason -> Supabase reachable, staying online (slow response, not offline)',
    );
    return false;
  }
  debugPrint(
    '⏱️ [BOOTSTRAP] $reason -> Supabase unreachable ($result), forcing offline mode',
  );
  offlineCacheManager.setSupabaseAvailability(false, force: true);
  return true;
}

/// Validates the cached Supabase session best-effort.
///
/// POLICY: this must NEVER sign the user out. An expired/invalid JWT,
/// a failed refresh, or a `refresh_token_already_used` race must keep the
/// cached session so the user stays logged in (offline-capable). The only
/// automatic logout allowed app-wide is `auth.forced_sign_out_days` (see
/// `checkForcedSignOut` in auth_provider.dart); every other logout must be
/// an explicit user action via the UI.
Future<bool> _ensureValidSupabaseSessionOrSignOut() async {
  final session = supabase.auth.currentSession;
  if (session == null) return false;

  if (session.accessToken.trim().isEmpty) {
    // Keep the session object; a later refresh may still succeed once the
    // refresh token is retried. Signing out here would log the user out
    // for a transient malformed cache entry.
    debugPrint(
      '⚠️ [_ensureValidSession] access token empty — keeping cached session, NOT signing out',
    );
    unawaited(
      SessionService.persistSignOutReason(
        reason: 'Access token is empty (kept session)',
        source: 'ensureValidSession',
      ),
    );
    return true;
  }

  // Proactively refresh if token is expired or about to expire.
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  final exp = session.expiresAt;
  if (exp != null && exp <= now + 30) {
    try {
      await SessionService.safeRefreshSession(
        timeout: const Duration(seconds: 5),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      final lower = e.toString().toLowerCase();
      if (lower.contains('refresh_token_already_used') ||
          lower.contains('already used')) {
        debugPrint(
          '⚠️ [_ensureValidSession] refresh race already_used - keeping cached session',
        );
        // Native may have refreshed concurrently; either way keep the user
        // logged in with whatever session is cached now.
        return true;
      }
      if (e is TimeoutException || isExpectedOfflineFailure(e)) {
        debugPrint(
          '⚠️ [_ensureValidSession] refresh timeout/network - using cached session',
        );
        await _applySupabaseUnreachable('auth refresh timeout/network');
        return true;
      }
      // Refresh failed for any other reason: keep the cached session and
      // fall through to the getUser() probe below (which itself never
      // signs out anymore).
      debugPrint(
        '⚠️ [_ensureValidSession] refresh failed (${e.runtimeType}) — keeping cached session',
      );
    }
    final refreshedSession = supabase.auth.currentSession;
    if (refreshedSession == null) {
      // The SDK cleared the in-memory session during a failed refresh.
      // Do NOT propagate this as a logout: the persisted snapshot (if any)
      // will be recovered by auth_provider's non-explicit sign-out guard.
      // Report "ok" so deferred tasks (background service, profile sync)
      // don't treat this as logged-out; the auth stream remains the single
      // source of truth for routing.
      debugPrint(
        '⚠️ [_ensureValidSession] refresh left no in-memory session — keeping login state, NOT signing out',
      );
      unawaited(
        SessionService.persistSignOutReason(
          reason: 'Session refresh failed - no session returned (kept login)',
          source: 'ensureValidSession',
        ),
      );
      return true;
    }
    // A refresh that returns the same access token is not a failure that
    // warrants a logout or a web reload — just keep using it.
  }

  try {
    // auth.getUser() is a full network round trip. 1.5s was far too tight for a
    // cold mobile connection and turned every slow start into a forced-offline
    // event that also cleared forceOnline.
    await supabase.auth.getUser().timeout(const Duration(seconds: 5));
    return true;
  } catch (e) {
    if (e is TimeoutException || isExpectedOfflineFailure(e)) {
      debugPrint(
        '⚠️ [_ensureValidSession] getUser timeout/network - using cached session',
      );
      await _applySupabaseUnreachable('getUser timeout/network');
      return true;
    }
    // Any auth error here (invalid/expired JWT, 401/403, refresh-token
    // errors, unauthorized, ...) must NOT sign out. Persist for
    // diagnostics and keep the cached session.
    debugPrint(
      '⚠️ [_ensureValidSession] getUser failed ($e) — keeping cached session, NOT signing out',
    );
    unawaited(
      SessionService.persistSignOutReason(
        reason: '${e.toString()} (kept session)',
        source: 'ensureValidSession',
      ),
    );
    return true;
  }
}

Future<void> _runDeferredTasks({
  required ProviderContainer container,
  required String supabaseUrl,
  required String supabaseAnonKey,
}) async {
  try {
    // Wait for auth state provider to emit its initial event before checking user.
    // This ensures the expired-session cleanup from bootstrap has propagated into
    // the Riverpod layer, so we never start user-specific tasks with a stale JWT.
    // Bounded: a stalled auth stream must not park these tasks forever.
    final authWaitDeadline = DateTime.now().add(const Duration(seconds: 5));
    var authValue = container.read(authStateProvider);
    while (authValue.isLoading && DateTime.now().isBefore(authWaitDeadline)) {
      await Future.delayed(const Duration(milliseconds: 30));
      authValue = container.read(authStateProvider);
    }
    final user = authValue.asData?.value.session?.user;

    // Use default translations directly instead of reading the provider synchronously.
    // The provider might be in a loading state where strings are empty (e.g., during setLocale).
    // Default translations are always available and cover critical keys like bgNotificationTitle.
    final bgTitle = LocalizationState.defaultTranslation('bgNotificationTitle');
    final bgText = LocalizationState.defaultTranslation('bgNotificationText');

    unawaited(
      BackgroundService.initialize(
        supabaseUrl: supabaseUrl,
        supabaseKey: supabaseAnonKey,
        notificationTitle: bgTitle,
        notificationText: bgText,
      ),
    );

    unawaited(
      Future.delayed(const Duration(milliseconds: 500), () {
        unawaited(_initializeFcmForCurrentUser());
      }),
    );

    // Notification reliability: if the app cold-started offline, the FCM
    // token fetch and session registration were skipped — the user would be
    // unreachable by push until the next app start. Re-attempt whenever
    // Supabase connectivity is restored. Registration is idempotent and
    // deduped (SessionRegistrationCoordinator cooldown + server upsert).
    onSupabaseResume(() {
      unawaited(
        Future.delayed(const Duration(seconds: 2), () {
          unawaited(_initializeFcmForCurrentUser());
        }),
      );
    });
    if (user != null) {
      // Warm the dashboard online/nearby stats now (cold start with a
      // persisted session) so the home screen can paint the correct online
      // count immediately instead of showing a placeholder while its own
      // fetch completes.
      unawaited(warmDashboardStatsForUser(user.id));
      var ok = false;
      if (offlineCacheManager.isSupabaseAvailable) {
        ok = await _ensureValidSupabaseSessionOrSignOut();
      } else {
        ok = true;
        debugPrint('⏱️ [BOOTSTRAP] Skipping session validation (offline)');
      }
      if (ok) {
        debugPrint('🔍 [BG] bootstrap: session ok, deferring native start');
        // Wait for visibility provider to initialize and calculate effective visibility
        // This prevents starting the background service with incorrect visibility state
        final visibilityNotifier = container.read(isVisibleProvider.notifier);
        await visibilityNotifier.waitForInitialization();
        debugPrint(
          '🔍 [BG] bootstrap: visibility initialized, scheduling start',
        );

        // Defer BackgroundService.start() past the first frame. The
        // background FlutterEngine init + Vulkan backend bring-up shows
        // up on the logcat as `Skipped 41 frames!` + a 1.4 s Davey on
        // the second frame on the moto g54 5G. The BGSESSION coordinator
        // already debounces the first registerSession by 1.2 s, so
        // pushing the start by 2 s doesn't delay map visibility by more
        // than ~0.8 s beyond that.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 2000), () {
            if (!BootstrapDeferral.isAppReady) return;
            BackgroundService.start();
          }),
        );

        // Dump the native service's in-memory event log once per process
        // start, shortly after BackgroundService.start() above has run. The
        // flutter console only shows log tags containing "flutter", so the
        // native Log.i lines never appear there — this dump surfaces what the
        // service actually did (ACTION_START, foreground promotion, GPS
        // polling, fixes, blockers) even after the activity was destroyed
        // and recreated (swipe-away + reopen), when the lifecycle observer's
        // `resumed` transition never fires.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 2600), () async {
            try {
              final diag = await BackgroundService.getDiagnostics();
              debugPrint(
                '🔍 Native background service diagnostics (post-start):',
              );
              if (diag.isEmpty) {
                debugPrint('🔍   (empty buffer)');
              } else {
                for (final line in diag) {
                  debugPrint('🔍   $line');
                }
              }
            } catch (e) {
              debugPrint('🔍 Failed to fetch diagnostics (post-start): $e');
            }
          }),
        );

        // Defer the bootstrap profile sync until well past the first frame.
        // The first Davey on cold start is ~3.6 s and the post-frame
        // "Skipped 88 frames" is dominated by this sync's response
        // processing (RPC parse + Hive write + provider invalidation).
        // The UI shows the cached profile from the local DB the whole
        // time, so pushing the sync out to 4 s after init-complete moves
        // the jank out of the first ~5 s window without any user-visible
        // regression.
        unawaited(
          Future.delayed(const Duration(milliseconds: 4000), () async {
            try {
              await container
                  .read(profileSyncProvider)
                  .syncProfile(user.id, source: 'app-bootstrap-startup');
            } catch (e, st) {
              _reportNonFatal(e, st);
            }
          }),
        );

        unawaited(
          Future.delayed(const Duration(milliseconds: 1300), () async {
            await container
                .read(isVisibleProvider.notifier)
                .ensureServiceStarted();
          }),
        );

        final pending = AppShortcuts.consumePendingTabIndex();
        if (pending != null) {
          container.read(navigationIndexProvider.notifier).setIndex(pending);
        }
      }
    }
  } catch (e, st) {
    _reportNonFatal(e, st);
  }

  unawaited(
    Future.delayed(const Duration(milliseconds: 800), () {
      unawaited(() async {
        try {
          await appConfigService.initialize();
        } catch (e, st) {
          _reportNonFatal(e, st);
        }
        try {
          await Future.wait([
            TimeOfDayRanges.loadFromConfig(),
            UserProfile.loadMatchRadiusConfig(),
            ProfileSyncService.loadConfig(),
          ]);
        } catch (e, st) {
          _reportNonFatal(e, st);
        }
      }());
    }),
  );

  // Defer the Supabase health check past the first frame. It's a 1-RPC
  // call (health_check), the response processing is light, but the
  // method-channel round-trip lands on the Android UI thread, so doing
  // it during the first-frame jank window is wasted work.
  unawaited(
    Future.delayed(const Duration(milliseconds: 4000), () {
      unawaited(
        _performSupabaseHealthCheck().catchError(
          (e, st) => _reportNonFatal(e as Object, st as StackTrace),
        ),
      );
    }),
  );

  // Pre-warm map tiles for every cached match minimap snapshot so match
  // location maps render offline. Online-only, budgeted, de-duplicated per
  // session; re-run after syncs (GlobalHomeSyncManager) picks up new matches.
  unawaited(
    Future.delayed(const Duration(milliseconds: 6000), () {
      // print(), not debugPrint(): the global debugPrint filter in _mainSync
      // drops anything without a whitelisted keyword.
      print('[MapTiles] deferred minimap warm firing (+6s)');
      unawaited(
        MapTileCacheService.instance
            .warmCachedMatchMinimaps()
            .catchError((_) {}),
      );
    }),
  );

  // Merge any offline places the native background service recorded while
  // the UI was closed into the encrypted trail and upload them (no-ops when
  // offline or when Retro Matching is not enabled).
  unawaited(
    Future.delayed(const Duration(milliseconds: 9000), () {
      unawaited(
        OfflineTrailService.instance
            .uploadPendingTrail()
            .catchError((_) => 0),
      );
    }),
  );

  if (kIsWeb) {
    unawaited(
      _deferredBackgroundInit(
        container: container,
        supabaseUrl: supabaseUrl,
        supabaseKey: supabaseAnonKey,
      ),
    );
  } else {
    // Defer the deferred background init past the first frame. It
    // includes MobileLocalNotificationService.initialize() (a method-
    // channel call that lands on the Android UI thread) and
    // SharedPreferences reads, all of which would otherwise pile onto
    // the first ~3.6 s of jank.
    unawaited(
      Future.delayed(const Duration(milliseconds: 4000), () {
        unawaited(
          _deferredBackgroundInit(
            container: container,
            supabaseUrl: supabaseUrl,
            supabaseKey: supabaseAnonKey,
          ),
        );
      }),
    );
  }

  // Watch auth state changes to initialize chat keys on login
  // (handles web and other flows where user logs in after bootstrap).
  // Tracks which user the chatKeyProvider was initialized for: after a
  // logout/login with a different user on the same device the provider
  // must be re-initialized (and its in-memory decryption caches purged),
  // otherwise it keeps serving the previous user's private key and the
  // new user's messages/previews stay undecryptable.
  String? authKeyInitializedUserId;
  unawaited(() async {
    debugPrint('⏱️ [AUTH] Subscribing to auth state stream');
    await for (final authState
        in Supabase.instance.client.auth.onAuthStateChange) {
      final session = authState.session;
      final userId = session?.user.id;

      // While a non-login OAuth exchange is in flight (a calendar import
      // borrowing the social sign-in flow to get a provider access token), the
      // only account this loop should act on is the anchor - the one already
      // signed in. Acting on the transient provider session would reset the
      // chat key provider, invalidate the dashboard/chat-count providers and
      // force the tab back to Home, yanking the user out of the screen they
      // started the import from. This listener is on the raw auth stream, so
      // the auth *router* guard does not cover it.
      if (AuthTransitionGuard.shouldDeferAuthEvent(userId)) {
        debugPrint(
          '⏱️ [AUTH] deferring auth handling for $userId — calendar OAuth in '
          'flight (anchor ${AuthTransitionGuard.anchorUserId})',
        );
        continue;
      }

      if (userId == null) {
        debugPrint('⏱️ [AUTH] Signed out — resetting chat key provider');
        var signedOutUserId = authKeyInitializedUserId;
        authKeyInitializedUserId = null;
        if (signedOutUserId == null || signedOutUserId.isEmpty) {
          try {
            signedOutUserId = (await SharedPreferences.getInstance())
                .getString('user_id');
          } catch (error) {
            debugPrint('[AUTH] Could not read cached outgoing user ID: $error');
          }
        }
        clearUserScopedHomeMemoryCaches();
        clearUserScopedChatMemoryCaches();
        if (signedOutUserId != null && signedOutUserId.isNotEmpty) {
          clearUserScopedProfileMemoryCaches(signedOutUserId);
          try {
            await OfflineCacheManager.instance.clearAllOfflineCache(
              userId: signedOutUserId,
            );
          } catch (error) {
            debugPrint(
              '[AUTH] Failed to clear signed-out user cache '
              '$signedOutUserId: $error',
            );
          }
        }
        try {
          container.invalidate(chatKeyProvider);
          ChatKeyService.instance.clearMemoryCaches();
        } catch (_) {}
        // Drop the outgoing user's home-screen providers and the shared
        // dashboard/unread/tab state so the next account on this device
        // rebuilds them from scratch (cold-start loading gate) instead of
        // reusing the previous account's resolved values. Covers sign-out
        // paths that bypass MainNavigationScreen._handleLogout.
        try {
          if (signedOutUserId != null && signedOutUserId.isNotEmpty) {
            container.invalidate(recentMatchesProvider(signedOutUserId));
            container.invalidate(recentChatsProvider(signedOutUserId));
            container.invalidate(userChatIdsProvider(signedOutUserId));
            container.invalidate(userProfileProvider(signedOutUserId));
            container.invalidate(initialHomeSyncProvider(signedOutUserId));
            try {
              container
                  .read(profileSyncStateProvider(signedOutUserId).notifier)
                  .reset();
              container
                  .read(profileSyncProvider)
                  .invalidateUser(signedOutUserId);
            } catch (_) {}
          }
          container.invalidate(dashboardStatsProvider);
          container.invalidate(totalUnreadChatCountProvider);
          container.invalidate(matchChatStartExpiryWarningProvider);
          try {
            container.read(navigationIndexProvider.notifier).setIndex(0);
          } catch (_) {}
        } catch (_) {}
        continue;
      }
      if (authState.event == AuthChangeEvent.signedIn ||
          authState.event == AuthChangeEvent.initialSession) {
        try {
          unawaited(
            container
                .read(userPreferencesProvider.notifier)
                .refresh()
                .catchError((error) {
                  debugPrint(
                    '[AUTH] Failed to refresh cached user preferences: $error',
                  );
                }),
          );
        } catch (error) {
          debugPrint('[AUTH] Could not start user-preference refresh: $error');
        }
      }
      try {
        await EncryptedCacheService.instance.initialize(userId);
        // Per-user cache key is ready: re-encrypt any legacy plaintext
        // chat-translation prefs left by older builds (privacy at rest).
        unawaited(migrateLegacyTranslationPrefs());
      } catch (_) {}
      try {
        container.read(chatKeyProvider);
        final chatKeyNotifier = container.read(chatKeyProvider.notifier);
        if (authKeyInitializedUserId != userId) {
          final previousUserId = authKeyInitializedUserId;
          if (previousUserId != null && previousUserId.isNotEmpty) {
            // Direct account switch (signedIn for a different user with no
            // signedOut interlude): wipe the outgoing user's on-device cache
            // (matches/chats/messages/profile/minimap snapshots) so the new
            // account's device holds only its own data — same privacy rules
            // as an explicit logout.
            clearUserScopedHomeMemoryCaches();
            clearUserScopedChatMemoryCaches();
            clearUserScopedProfileMemoryCaches(previousUserId);
            try {
              await OfflineCacheManager.instance.clearAllOfflineCache(
                userId: previousUserId,
              );
            } catch (error) {
              debugPrint(
                '[AUTH] Failed to clear switched-from user cache '
                '$previousUserId: $error',
              );
            }
            try {
              container
                  .read(profileSyncStateProvider(previousUserId).notifier)
                  .reset();
              container
                  .read(profileSyncProvider)
                  .invalidateUser(previousUserId);
            } catch (_) {}
          }
          authKeyInitializedUserId = userId;
          debugPrint(
            '⏱️ [AUTH] User changed to $userId — re-initializing chat key provider',
          );
          // Direct account switch (signedIn for a different user with no
          // signedOut interlude): reset the shared home-screen state so the
          // new account waits for its own data like a cold start instead of
          // reusing the previous account's dashboard counts, badges or tab.
          try {
            container.invalidate(dashboardStatsProvider);
            container.invalidate(totalUnreadChatCountProvider);
            container.invalidate(matchChatStartExpiryWarningProvider);
            try {
              container.read(navigationIndexProvider.notifier).setIndex(0);
            } catch (_) {}
          } catch (_) {}
          await chatKeyNotifier.refresh();
        } else {
          await chatKeyNotifier.initializationComplete;
        }
        final keyState = container.read(chatKeyProvider);
        debugPrint(
          '⏱️ [AUTH] ChatKeyProvider re-check: isLoaded=${keyState.isLoaded} activeKey=${keyState.activeKey?.id} isLocked=${keyState.isLocked} hasLocalKey=${keyState.privateKeyBytes != null} hasRecoveryKey=${keyState.hasRecoveryKey} hasPasswordWrapper=${keyState.hasPasswordWrapper}',
        );
        // Key rotation removed: Keys are never automatically replaced to ensure all messages remain readable
        if (keyState.isLoaded && keyState.activeKey == null) {
          // Only set up encryption if no key exists at all (new user)
          await chatKeyNotifier.setupEncryption();
          debugPrint('⏱️ [AUTH] Chat encryption set up for new user');
        }
      } catch (e, st) {
        // Same as the cold-start path: this extra setup attempt is a
        // convenience, not a gate. A rejected token or rate-limited backend
        // leaves chat encryption unconfigured until the provider's retry
        // succeeds, which is preferable to a framework-level error.
        debugPrint('⏱️ [AUTH] ChatKeyProvider setup deferred: $e');
        debugPrintStack(
          stackTrace: st,
          label: 'ChatKeyProvider setup deferred',
        );
      }
    }
  }());
}

/// Simple sanity check that the Supabase client can talk to your backend.
/// Uses a lightweight RPC `health_check()` (SECURITY DEFINER) so anonymous clients
/// do not need direct table access to perform the check.
Future<void> _performSupabaseHealthCheck() async {
  try {
    debugPrint('⏱️ [BOOTSTRAP] Performing Supabase health check...');

    // The transport hint is never a reason to skip this: connectivity_plus is
    // unreliable (it reports [none] on a healthy Windows network) and says
    // nothing about upstream reachability. The RPC's own timeout and failure
    // handling is the real signal. The budget is platform-scaled (5s desktop,
    // 10s mobile) so a slow cold start is not mistaken for an outage.
    final timeout = platformProbeTimeout(const Duration(seconds: 5));
    await supabase
        .rpc('health_check')
        .maybeSingle()
        .timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException(
              'Health check timeout after ${timeout.inSeconds} seconds',
            );
          },
        );
    debugPrint('✅ [BOOTSTRAP] Supabase health check passed.');
  } catch (e) {
    debugPrint('⏭️ [BOOTSTRAP] Supabase health check failed (non-fatal): $e');
    // We don't rethrow because it's non-fatal for bootstrap,
    // but useful to know.
  }
}

Future<void> _deferredBackgroundInit({
  required ProviderContainer container,
  required String supabaseUrl,
  required String supabaseKey,
}) async {
  try {
    await WebNotificationService.initialize();

    await MobileLocalNotificationService.initialize();

    // Best-effort: if we were launched from an Android static shortcut, capture the requested tab
    // early to avoid races during auth/profile gating.
    try {
      final initial = await BackgroundService.getInitialRoute();
      final raw = initial?['tabIndex'];
      final parsed = raw is int
          ? raw
          : raw is String
          ? int.tryParse(raw.trim())
          : null;
      if (parsed != null && parsed >= 0 && parsed <= 4) {
        AppShortcuts.setPendingTabIndex(parsed);
        try {
          container.read(navigationIndexProvider.notifier).setIndex(parsed);
        } catch (_) {}
      }
    } catch (_) {}

    // Listen for sign-in / sign-out / token-refresh events during the session.
    // Cold-start initialSession is already handled by bootstrap + _runDeferredTasks,
    // so only `signedIn` is processed here to avoid duplicate work.
    supabase.auth.onAuthStateChange.listen(
      (event) async {
        if (event.event == AuthChangeEvent.signedIn) {
          final ok = await _ensureValidSupabaseSessionOrSignOut();
          if (!ok) return;
          final userId = supabase.auth.currentUser?.id;
          if (userId != null && userId.isNotEmpty) {
            // Warm the dashboard online/nearby stats now (before the home
            // screen builds) so the online count is displayed immediately
            // when the dashboard first renders.
            unawaited(warmDashboardStatsForUser(userId));
            // Visibility-independent heartbeat: keeps the user counted online
            // even when invisible (GPS — the normal heartbeat — is stopped
            // then). Server-side, is_online requires an active session row,
            // which registerSession below creates.
            UserActivityService.instance.startHeartbeat(userId);
            if (kIsWeb) {
              try {
                WebNotificationService.setServiceWorkerUserId(userId);
              } catch (_) {}
            }
            final platformText = kIsWeb
                ? 'web'
                : defaultTargetPlatform == TargetPlatform.android
                ? 'android'
                : defaultTargetPlatform == TargetPlatform.iOS
                ? 'ios'
                : 'unknown';
            final url = runtimeSupabaseUrl;
            debugPrint(
              '[BGSESSION] authListener: scheduling registerSession userId=$userId url=$url event=${event.event.name}',
            );
            SessionRegistrationCoordinator.instance.schedule(
              userId: userId,
              platform: platformText,
              source: 'auth-signed-in',
            );

            unawaited(_clearStaleProfilesForUser(userId));

            // Process any pending referral
            // 1. Check local storage (Deep Link)
            unawaited(
              container
                  .read(referralServiceProvider)
                  .processPendingReferral(userId),
            );

            // 2. If no referral processed, check fingerdebugPrint (Deferred Deep Link)
            unawaited(
              _hasReferral(userId).then((hasReferral) async {
                if (!hasReferral) {
                  final code = await container
                      .read(referralServiceProvider)
                      .checkPendingReferralFromFingerprint();
                  if (code != null) {
                    await container
                        .read(referralServiceProvider)
                        .handleIncomingReferralCode(code);
                    await container
                        .read(referralServiceProvider)
                        .processPendingReferral(userId);
                  }
                }
              }),
            );
          }
          unawaited(_initializeFcmForCurrentUser());
        }
        if (event.event == AuthChangeEvent.signedOut) {
          UserActivityService.instance.stopHeartbeat();
          try {
            await BackgroundService.updateToken(null, refreshToken: null);
          } catch (_) {}
          try {
            await BackgroundService.stop();
          } catch (_) {}
          if (kIsWeb) {
            try {
              WebNotificationService.clearServiceWorkerUserId();
            } catch (_) {}
          }
        }
        if (event.event == AuthChangeEvent.tokenRefreshed) {
          final session = supabase.auth.currentSession;
          if (session?.accessToken != null) {
            BackgroundService.updateToken(
              session!.accessToken,
              refreshToken: session.refreshToken,
            );
          }
        }
      },
      onError: (error) {
        // Handle stream errors (e.g. Invalid Refresh Token) to prevent app crash
      },
    );
  } catch (_) {}
}

/// App shown when Supabase keys are missing
class MissingSupabaseKeyApp extends StatelessWidget {
  final bool missingUrl;
  final bool missingKey;
  const MissingSupabaseKeyApp({
    super.key,
    required this.missingUrl,
    required this.missingKey,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    if (missingUrl) {
      lines.add(LocalizationState.defaultTranslation('supabaseUrlMissing'));
    }
    if (missingKey) {
      lines.add(LocalizationState.defaultTranslation('supabaseAnonKeyMissing'));
    }

    if (kIsWeb && (missingUrl || missingKey)) {
      lines.add(LocalizationState.defaultTranslation('supabaseWebQueryTip'));
      lines.add(
        LocalizationState.defaultTranslation('supabaseWebQueryExample'),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: ShrinkText(LocalizationState.defaultTranslation('configRequired')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              LocalizationState.defaultTranslation('supabaseConfigMissing'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...lines.map((l) => Text(l)),
          ],
        ),
      ),
    );
  }
}

/// App shown when Supabase initialization fails
class SupabaseInitErrorApp extends StatelessWidget {
  final String error;
  final VoidCallback? onRetry;
  const SupabaseInitErrorApp({super.key, required this.error, this.onRetry});
  @override
  Widget build(BuildContext context) {
    final title = LocalizationState.defaultTranslation('supabaseInitFailed');
    final body = LocalizationState.defaultTranslation('supabaseInitFailedBody');
    return Scaffold(
      appBar: AppBar(title: ShrinkText(title)),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: kDebugMode
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            LocalizationState.defaultTranslation(
                              'generalDetails',
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(error),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onRetry,
                  child: Text(
                    LocalizationState.defaultTranslation('generalRetry'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Smooth scroll behavior (mouse wheel smoothing)
class _SmoothScrollBehavior extends ScrollBehavior {
  const _SmoothScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics().applyTo(const BouncingScrollPhysics());
  }
}

class MatchMeApp extends ConsumerStatefulWidget {
  const MatchMeApp({super.key});

  @override
  ConsumerState<MatchMeApp> createState() => _MatchMeAppState();
}

class _MatchMeAppState extends ConsumerState<MatchMeApp>
    with WidgetsBindingObserver {
  QuickActions? _quickActions;
  String? _lastQuickActionsLang;
  bool _quickActionsListenerRegistered = false;
  bool _quickActionsDisabled = false;
  bool _deferredTasksStarted = false;
  bool _translationSyncRunning = false;
  bool _initialBadgeSyncDone = false;
  DateTime? _lastTranslationSyncAt;
  DateTime? _lastResumeSyncAt;
  void Function()? _realtimeRestoreUnregister;

  /// The account the auth router is currently rendering. Retained so a
  /// transient provider session (see [AuthTransitionGuard]) can be ignored
  /// without tearing this user's screen down.
  User? _lastRenderedAuthUser;
  ProviderSubscription<AsyncValue<ConnectivityHealth>>?
  _connectivityUiStatusSub;

  void _maybeUpdateQuickActions(LocalizationState l10n) {
    if (_quickActions == null) return;
    if (_quickActionsDisabled) return;
    if (l10n.isLoading && l10n.supportedLanguages.isEmpty) return;

    final lang = l10n.currentLocale.languageCode.toLowerCase();
    if (_lastQuickActionsLang == lang) return;
    _lastQuickActionsLang = lang;

    unawaited(() async {
      try {
        await _quickActions!.setShortcutItems(<ShortcutItem>[
          ShortcutItem(
            type: 'matchme_home',
            localizedTitle: l10n.getString('navHome'),
            icon: 'home',
          ),
          ShortcutItem(
            type: 'matchme_matches',
            localizedTitle: l10n.getString('navMatches'),
            icon: 'favorite',
          ),
          ShortcutItem(
            type: 'matchme_chats',
            localizedTitle: l10n.getString('navChats'),
            icon: 'message',
          ),
          ShortcutItem(
            type: 'matchme_profile',
            localizedTitle: l10n.getString('navProfile'),
            icon: 'contact',
          ),
        ]);
      } on PlatformException {
        _quickActionsDisabled = true;
      } catch (_) {
        _quickActionsDisabled = true;
      }
    }());
  }

  int? _parseTabIndex(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// Web only: disconnect Realtime when tab is hidden or closed to stay under connection limits.
  /// Also marks user as offline when the page is closed.
  void _installWebRealtimeVisibilityDisconnect() {
    if (!kIsWeb) return;
    final listenerInstalledAt = DateTime.now();
    // When the tab was last hidden. Used to skip the re-sync round-trip on
    // quick focus switches (Alt-Tab back and forth, minimize/maximize): those
    // fire hidden->visible within a second or two, and re-syncing +
    // invalidating providers on every one of them makes the home screen flash
    // (providers go back to loading, ads rebuild, impressions re-fire).
    DateTime? lastHiddenAt;
    try {
      html.document.addEventListener('visibilitychange', (_) {
        try {
          if (html.document.visibilityState == 'hidden' ||
              html.document.hidden == true) {
            lastHiddenAt = DateTime.now();
            debugPrint('🔌 [Web] Disconnecting Supabase Realtime (tab hidden)');
            Supabase.instance.client.realtime.disconnect();
          } else {
            // Skip rapid hidden->visible bounces (window focus switches,
            // minimize/maximize). The socket reconnect alone is enough to
            // resume realtime; a full re-sync is only worthwhile after the
            // tab was actually hidden for a while.
            final hiddenFor = lastHiddenAt == null
                ? Duration.zero
                : DateTime.now().difference(lastHiddenAt!);
            lastHiddenAt = null;
            if (hiddenFor < const Duration(seconds: 10)) {
              debugPrint(
                '🔌 [Web] Tab visible after brief hide '
                '(${hiddenFor.inMilliseconds}ms) - reconnecting socket only, '
                'skipping re-sync to avoid UI flicker',
              );
              // ignore: invalid_use_of_internal_member
              if (!_shouldConnectRealtime()) return;
              // ignore: invalid_use_of_internal_member
              Supabase.instance.client.realtime.connect();
              return;
            }
            debugPrint('🔌 [Web] Reconnecting Supabase Realtime (tab visible)');
            // ignore: invalid_use_of_internal_member
            if (!_shouldConnectRealtime()) {
              debugPrint(
                'ðŸ”Œ [Web] Skipping Supabase Realtime reconnect (tab visible, no authenticated user)',
              );
              return;
            }
            // ignore: invalid_use_of_internal_member
            Supabase.instance.client.realtime.connect();

            // Re-sync profile and settings when tab becomes visible
            // This ensures gender/age preferences, radius, and other settings are current
            // Use addPostFrameCallback to ensure we're not inside a frame callback,
            // avoiding Flutter web engine assertion from IndexedDB microtask re-entrancy.
            // Suppress for the first 30s after install — the browser fires a spurious
            // 'visible' event during initial page load that would otherwise re-run the
            // cold-start sync (ProfileSyncService + visibility re-sync) on top of the
            // bootstrap that just finished.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Future.delayed(const Duration(milliseconds: 200), () {
                try {
                  if (DateTime.now().difference(listenerInstalledAt) <
                      const Duration(seconds: 30)) {
                    return;
                  }
                  final userId = Supabase.instance.client.auth.currentUser?.id;
                  if (userId != null && mounted) {
                    debugPrint(
                      '🔄 [Web] Re-syncing profile after tab visibility restored',
                    );
                    ref
                        .read(profileSyncProvider)
                        .syncProfile(userId, source: 'web-tab-visible');

                    // Force a full chats re-sync so any translation-toggle
                    // changes (or other `public.chats` row updates) made on
                    // other devices while this tab was hidden are reflected
                    // immediately. The sync writes into the local DB, so the
                    // existing `recentChatsProvider` stream emits the update
                    // WITHOUT going through a loading state (no UI flash).
                    //
                    // NOTE: do NOT `ref.invalidate(recentChatsProvider)` here.
                    // Invalidating disposes the provider, flips every watcher
                    // back to loading (the home screen shows spinners / a
                    // full-screen loader), tears down healthy realtime
                    // channels and re-creates them — on every tab switch that
                    // reads as a visible "twitch". Channels are only recreated
                    // when realtime was actually torn down by a real offline
                    // (SupabaseRealtimeManager.pauseAll), mirroring the mobile
                    // app-resume path below.
                    try {
                      debugPrint(
                        '🔄 [Web] Re-syncing chats after tab visibility restored',
                      );
                      // Fire-and-forget; do not block the visibility handler
                      unawaited(
                        ref
                            .read(globalSyncManagerProvider)
                            .syncChatsNow(userId, force: true),
                      );
                      if (SupabaseRealtimeManager.instance.isPaused) {
                        ref.invalidate(recentChatsProvider(userId));
                      }
                      // Note: We do NOT increment translation version here to avoid
                      // flashing of translated text when the web tab is hidden/shown.
                      // The chat sync already refreshes message data, and translation
                      // providers will naturally re-evaluate if the data changes.
                    } catch (e) {
                      debugPrint(
                        '⚠️ [Web] Failed to sync chats on visibility change: $e',
                      );
                    }
                  }
                } catch (e) {
                  debugPrint(
                    '⚠️ [Web] Failed to sync profile on visibility change: $e',
                  );
                }
              });
            });
          }
        } catch (e) {
          debugPrint('🔌 [Web] Realtime visibility handler error: $e');
        }
      });
      void disconnectOnUnload(_) {
        try {
          Supabase.instance.client.realtime.disconnect();
        } catch (_) {}
      }

      // Mark user as offline when page is closed (beforeunload for modern browsers)
      void markOfflineOnClose(_) {
        final userId = supabase.auth.currentUser?.id;
        if (userId != null) {
          debugPrint('🔌 [Web] Page closing - marking user as offline');
          // Use sendBeacon for reliable delivery during page unload
          final offlineData = jsonEncode({'p_user_id': userId});
          final supabaseUrl = runtimeSupabaseUrl!;
          final beaconUrl = '$supabaseUrl/rest/v1/rpc/set_user_offline';
          final beaconSent = html.sendOfflineBeacon(beaconUrl, offlineData);

          if (beaconSent) {
            debugPrint('✅ [Web] Offline beacon sent successfully');
          } else {
            debugPrint('⚠️ [Web] Beacon failed, falling back to RPC');
            // Fall back to regular RPC call
            supabase
                .rpc('set_user_offline', params: {'p_user_id': userId})
                .catchError((e) {
                  debugPrint(
                    '⚠️ [Web] Failed to set user offline on close: $e',
                  );
                });
          }
        }
      }

      html.window.addEventListener('beforeunload', markOfflineOnClose);
      html.window.addEventListener('pagehide', markOfflineOnClose);
      html.window.addEventListener('unload', disconnectOnUnload);
    } catch (_) {}
  }

  @override
  void initState() {
    print(
      '⏱️ [MatchMeApp] initState at ${DateTime.now().millisecondsSinceEpoch}',
    );
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // A network flap that starts and ends entirely while the app is
    // foregrounded never triggers a lifecycle resume, so the lifecycle path
    // below can't recreate the dead stream subscriptions. Connectivity
    // restore is the catch-all: rebuild them whenever Supabase becomes
    // reachable again. Invalidating is cheap and safe even if the lifecycle
    // path also fires.
    _realtimeRestoreUnregister = onSupabaseResume(() {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) return;
      if (!mounted) return;
      if (shouldSkipSupabaseCalls()) return;
      _recreateStreamRealtimeProviders(userId);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _installWebRealtimeVisibilityDisconnect();
    });

    ref.listenManual(authStateProvider, (prev, next) {
      final session = next.asData?.value.session;
      if (session == null) return;
      unawaited(AdminBroadcastService.replayPendingBlueNotifications());
      _translatePendingMessages();
    });
    _connectivityUiStatusSub = ref.listenManual<AsyncValue<ConnectivityHealth>>(
      connectivityHealthProvider,
      (previous, next) {
        final previousStatus = previous?.asData?.value;
        final nextStatus = next.asData?.value;
        if (nextStatus == null) return;
        final traceMessage =
            '[CONNECTIVITY_TRACE] ui_state_change '
            'ts=${DateTime.now().toIso8601String()} '
            'from=${previousStatus?.describe() ?? 'none'} '
            'to=${nextStatus.describe()}';
        debugPrint(traceMessage);
        unawaited(
          PlatformTraceLogger.trace('MatchMeConnectivityUI', traceMessage),
        );
      },
      fireImmediately: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      print(
        '[STARTUP_DIAG] match_me_first_frame '
        'at ${DateTime.now().millisecondsSinceEpoch}',
      );
      print(
        '⏱️ [MatchMeApp] First Frame Rendered at ${DateTime.now().millisecondsSinceEpoch}',
      );

      if (_deferredTasksStarted) return;
      _deferredTasksStarted = true;

      final url = runtimeSupabaseUrl;
      final key = runtimeSupabaseAnonKey;
      if (url != null && url.isNotEmpty && key != null && key.isNotEmpty) {
        unawaited(
          _runDeferredTasks(
            container: container,
            supabaseUrl: url,
            supabaseAnonKey: key,
          ),
        );
      }
    });

    // On cold start, Flutter may already be in the "resumed" state and
    // didChangeAppLifecycleState won't fire. Tell Android native code immediately
    // that the UI is in foreground so it can hide the persistent service notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        BackgroundService.updateAppForeground(true);
      } catch (_) {}
      AdminBroadcastService.setAppInForeground(true);
      unawaited(AdminBroadcastService.replayPendingBlueNotifications());
    });

    // "Best effort" home-screen quick actions (long-press app icon).
    // Note: iOS has no "pin shortcut" prompt; Android pinning is handled separately.
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android) {
        _quickActions = const QuickActions();
        _quickActions!.initialize((shortcutType) {
          int? tab;
          switch (shortcutType) {
            case 'matchme_home':
              tab = 0;
              break;
            case 'matchme_matches':
              tab = 1;
              break;
            case 'matchme_chats':
              tab = 2;
              break;
            case 'matchme_profile':
              tab = 4;
              break;
            default:
              return;
          }

          AppShortcuts.setPendingTabIndex(tab);

          // Best-effort immediate navigation for warm starts.
          try {
            container.read(navigationIndexProvider.notifier).setIndex(tab);
          } catch (_) {
            // If providers aren't ready yet, MainNavigationScreen will consume the pending tab.
          }
        });

        // Initial set (may be overridden once localization finishes loading).
        _maybeUpdateQuickActions(ref.read(localizationProvider));

        // Keep titles up-to-date with runtime locale changes.
        // Listener is registered once in build() to avoid ref.listen calls outside of a build context.
      }
    } catch (_) {}

    // Handle notification taps delivered from native (Android singleTop onNewIntent).
    // This complements cold-start deep links (initialRoute) and the BackgroundService getInitialRoute flow.
    try {
      const mainActivityChannel = MethodChannel('matchme/main_activity');
      mainActivityChannel.setMethodCallHandler((call) async {
        if (call.method == 'onSharedIntent') {
          final args = call.arguments;
          if (args is! Map) return;
          final map = Map<String, dynamic>.from(args);
          final sharedText = (map['sharedText'] as String?)?.trim();
          final sharedFilePath = (map['sharedFilePath'] as String?)?.trim();
          if ((sharedText == null || sharedText.isEmpty) &&
              (sharedFilePath == null || sharedFilePath.isEmpty)) {
            return;
          }

          final payload = <String, dynamic>{
            if (sharedText != null && sharedText.isNotEmpty)
              'sharedText': sharedText,
            if (sharedFilePath != null && sharedFilePath.isNotEmpty)
              'sharedFilePath': sharedFilePath,
          };

          try {
            container
                .read(pendingAddEventShareProvider.notifier)
                .setPayload(payload);
          } catch (_) {}

          AppShortcuts.setPendingTabIndex(3);
          try {
            container.read(navigationIndexProvider.notifier).setIndex(3);
          } catch (_) {}
          return;
        }

        if (call.method != 'onNotificationRoute') return;

        final args = call.arguments;
        if (args is! Map) return;
        final map = Map<String, dynamic>.from(args);

        final matchId = (map['matchId'] as String?)?.trim();
        final routeFromNative = (map['route'] as String?)?.trim();
        final tabIndex = _parseTabIndex(map['tabIndex']);

        final effectiveRoute =
            (routeFromNative != null && routeFromNative.isNotEmpty)
            ? routeFromNative
            : (matchId != null && matchId.isNotEmpty)
            ? '/chat/$matchId'
            : null;

        if (tabIndex != null && tabIndex >= 0 && tabIndex <= 4) {
          AppShortcuts.setPendingTabIndex(tabIndex);
          try {
            container.read(navigationIndexProvider.notifier).setIndex(tabIndex);
          } catch (_) {}
          return;
        }

        if (effectiveRoute == null || !effectiveRoute.startsWith('/chat/')) {
          return;
        }

        final nav = navigatorKey.currentState;
        if (nav == null) {
          _pendingNotificationRoute = effectiveRoute;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final pending = _pendingNotificationRoute;
            final nav2 = navigatorKey.currentState;
            if (pending != null && nav2 != null) {
              _pendingNotificationRoute = null;
              nav2.pushNamed(pending);
            }
          });
          return;
        }

        nav.pushNamed(effectiveRoute);
      });
    } catch (_) {}

    // Re-apply system UI overlay styles at runtime to handle OEM quirks (e.g., Moto Android 15)
    void applyOverlays() {
      try {
        // Force both top and bottom system overlays visible (manual) and apply style
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
        );
        // Keep the retried overlay styles in sync with the active theme mode,
        // otherwise a delayed retry would repaint light bars over a dark UI.
        ThemeMode mode;
        try {
          mode = container.read(themeModeProvider);
        } catch (_) {
          mode = ThemeMode.system;
        }
        var amoledEnabled = false;
        try {
          amoledEnabled = container.read(amoledThemeProvider);
        } catch (_) {}
        final platformDark =
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
        final isDark =
            mode == ThemeMode.dark ||
            (mode == ThemeMode.system && platformDark);
        final barColor = isDark
            ? (amoledEnabled
                  ? AppThemeTokens.amoledSurface
                  : AppThemeTokens.darkSurface)
            : AppThemeTokens.lightSurface;
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: barColor,
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarColor: barColor,
            systemNavigationBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
          ),
        );
      } catch (_) {}
    }

    // Apply immediately and retry after short delays to handle OEM resets
    applyOverlays();

    // Avoid scheduling delayed retries during widget tests (which treat pending timers as failures)
    // Use a runtime-safe check on the binding's runtimeType name to avoid referencing test-only types
    final bindingTypeName = WidgetsBinding.instance.runtimeType.toString();
    if (!bindingTypeName.contains('TestWidgets')) {
      Future.delayed(const Duration(milliseconds: 250), applyOverlays);
      Future.delayed(const Duration(milliseconds: 1000), applyOverlays);
      Future.delayed(const Duration(milliseconds: 3000), applyOverlays);

      // Defer notification permission request until after first frame to avoid blocking startup and
      // to prevent plugin channel timing issues on some devices.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          PermissionHelper.requestNotificationPermission().catchError((_) {}),
        );
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivityUiStatusSub?.close();
    _realtimeRestoreUnregister?.call();
    super.dispose();
  }

  /// Recreate the stream-based realtime subscriptions (supabase .stream()).
  /// The vendored realtime client does not rejoin their channels after a
  /// socket disconnect, so after a real offline they must be rebuilt.
  /// recentChatsProvider is included because its chat/match/chats channels
  /// are not registered when the provider happens to rebuild while offline.
  void _recreateStreamRealtimeProviders(String userId) {
    ref.invalidate(recentChatsProvider(userId));
    ref.invalidate(currentUserUsersTableProvider);
    ref.invalidate(translationsRealtimeProvider);
    ref.invalidate(subscriptionTiersRealtimeProvider);
    ref.invalidate(subscriptionPlansRealtimeProvider);
    ref.invalidate(intentsRealtimeProvider);
    ref.invalidate(profileOptionsRealtimeProvider);
    ref.invalidate(interestsRealtimeProvider);
    ref.invalidate(basicFieldAdminReviewsProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    ResumeDiagnostics.logThrottled(
      'Root app lifecycle changed: $state',
      category: 'root-lifecycle-$state',
      minIntervalMs: 250,
    );

    if (state == AppLifecycleState.paused) {
      // Hand live-location broadcasting to the native service
      try {
        unawaited(
          ref.read(locationShareProvider.notifier).handleAppBackgrounded(),
        );
      } catch (_) {}

      // Keep Realtime connected even when screen is off - messages should still arrive
      debugPrint(
        '🔌 App paused (screen off) - keeping Realtime connected for message delivery',
      );
      BackgroundService.updateAppForeground(false);
      AdminBroadcastService.setAppInForeground(false);
    } else if (state == AppLifecycleState.hidden) {
      try {
        unawaited(
          ref.read(locationShareProvider.notifier).handleAppBackgrounded(),
        );
      } catch (_) {}

      debugPrint(
        '🔌 App hidden - keeping Realtime connected for message delivery',
      );
      BackgroundService.updateAppForeground(false);
      AdminBroadcastService.setAppInForeground(false);
    } else if (state == AppLifecycleState.detached) {
      try {
        unawaited(
          ref.read(locationShareProvider.notifier).handleAppBackgrounded(),
        );
      } catch (_) {}
      debugPrint('🔌 App detached - cleanup');
      BackgroundService.updateAppForeground(false);
      AdminBroadcastService.setAppInForeground(false);
    } else if (state == AppLifecycleState.resumed) {
      unawaited(ResumeRouteRestore.clearPendingRoute());

      // Re-assert the icon badge from local truth. iOS applies `aps.badge`
      // from pushes that arrived while backgrounded/killed, and that server
      // count can drift from what the app actually shows (e.g. matches the
      // user already viewed). Without this, a stale badge could survive a
      // plain app open — the exact bug where the red dot never went away.
      final currentBadge = ref.read(iconBadgeCountProvider);
      if (currentBadge != null) {
        unawaited(AppBadgeService.setCount(currentBadge));
      }
      // Dump the native background service's event log BEFORE telling it the
      // UI is foreground again, so the snapshot reflects the background period.
      () async {
        final diag = await BackgroundService.getDiagnostics();
        debugPrint('🔍 Native background service diagnostics (resumed):');
        if (diag.isEmpty) {
          debugPrint('🔍   (empty buffer)');
        } else {
          for (final line in diag) {
            debugPrint('🔍   $line');
          }
        }
      }();

      // Realtime stays connected, no need to reconnect
      debugPrint('🔌 App resumed - Realtime already connected');

      BackgroundService.updateAppForeground(true);
      AdminBroadcastService.setAppInForeground(true);
      unawaited(AdminBroadcastService.replayPendingBlueNotifications());

      // Take back live-location broadcasting from the native service and
      // rejoin position/control channels + reconcile missed signals against
      // the DB. Channels stay alive across short screen off/on; only a real
      // offline (SupabaseRealtimeManager.pauseAll() → realtime.disconnect())
      // drops them, and resumeAll() + provider reconnect paths re-create them.
      try {
        unawaited(ref.read(locationShareProvider.notifier).handleAppResumed());
      } catch (_) {}

      // When app resumes from background, translate any pending messages that arrived while closed
      // This ensures all messages show translated versions in the chat history
      _translatePendingMessages();

      // Reconcile missed DB changes via REST. Realtime channels stay subscribed
      // across short screen off/on (paused/hidden no longer disconnect), so do
      // NOT invalidate recentChatsProvider on every resume — that disposes
      // healthy chat + location-signal channels and forces the duplicate
      // "Subscribed successfully" / "Signal channel subscribed" logs.
      // Only recreate the provider when realtime was actually torn down
      // (real offline → SupabaseRealtimeManager.pauseAll()).
      //
      // Note: We do NOT increment the translation version here. The chat messages
      // provider sync already refreshes message data, and translation providers
      // will naturally re-evaluate if the underlying message data changes.
      // Incrementing the translation version would cause all translation providers
      // to re-evaluate even when nothing changed, causing visible flashing of
      // translated text when the screen turns back on.
      final resumedUserId = supabase.auth.currentUser?.id;
      if (resumedUserId != null && mounted) {
        try {
          // Coalesce rapid duplicate resumed events (inactive → resumed plus
          // visibility/connectivity observers firing together on screen-on).
          final now = DateTime.now();
          if (_lastResumeSyncAt != null &&
              now.difference(_lastResumeSyncAt!) < const Duration(seconds: 5)) {
            debugPrint('🔄 App resume sync skipped (coalesced)');
          } else {
            _lastResumeSyncAt = now;
            final hadRealtimeDisconnect =
                SupabaseRealtimeManager.instance.isPaused;
            debugPrint(
              '🔄 Re-syncing chats after app resumed (hadDisconnect=$hadRealtimeDisconnect)',
            );
            unawaited(
              ref
                  .read(globalSyncManagerProvider)
                  .syncChatsNow(resumedUserId, force: true),
            );
            // Recreate realtime channels only if they were actually paused.
            // resumeAll() (via ConnectivityRestoreCoordinator) re-creates
            // manager-owned channels; invalidating here re-creates the
            // recentChatsProvider-owned chat channels after a real offline.
            if (hadRealtimeDisconnect) {
              _recreateStreamRealtimeProviders(resumedUserId);
            }
          }
        } catch (e) {
          debugPrint('⚠️ Failed to sync chats on app resume: $e');
        }
      }

      // NOTE: no forced setState() here on purpose. Locale and text
      // direction are driven by providers (localizationProvider), so every
      // resume used to rebuild the entire widget tree — remounting ad
      // widgets, re-firing impressions and making the home screen visibly
      // "twitch" on web whenever the window lost/regained focus. Provider
      // emissions already rebuild exactly the widgets that need it.
    }
  }

  /// Translate any messages that have content_translated as NULL
  /// These are messages that arrived while the app was closed
  void _translatePendingMessages() {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return;
    }

    if (_translationSyncRunning) {
      return;
    }

    final now = DateTime.now();
    if (_lastTranslationSyncAt != null &&
        now.difference(_lastTranslationSyncAt!) < const Duration(seconds: 20)) {
      return;
    }

    _translationSyncRunning = true;
    _lastTranslationSyncAt = now;
    unawaited(() async {
      try {
        // Let first resumed frame settle before doing translation-related network/db work.
        await Future.delayed(const Duration(milliseconds: 1200));
        await ref.read(pendingMessageTranslationProvider.future);
      } catch (e) {
        debugPrint('⚠️ Startup translation sync trigger failed: $e');
      } finally {
        _translationSyncRunning = false;
      }
    }());
  }

  static TextTheme _normalizeTextTheme(
    TextTheme src,
    List<String> fallbackFonts,
  ) {
    TextStyle? normalizeStyle(TextStyle? s) {
      if (s == null) return null;
      return s.copyWith(
        inherit: true,
        fontFamilyFallback: <String>[
          ...?s.fontFamilyFallback,
          ...fallbackFonts,
        ],
      );
    }

    return TextTheme(
      displayLarge: normalizeStyle(src.displayLarge),
      displayMedium: normalizeStyle(src.displayMedium),
      displaySmall: normalizeStyle(src.displaySmall),
      headlineLarge: normalizeStyle(src.headlineLarge),
      headlineMedium: normalizeStyle(src.headlineMedium),
      headlineSmall: normalizeStyle(src.headlineSmall),
      titleLarge: normalizeStyle(src.titleLarge),
      titleMedium: normalizeStyle(src.titleMedium),
      titleSmall: normalizeStyle(src.titleSmall),
      bodyLarge: normalizeStyle(src.bodyLarge),
      bodyMedium: normalizeStyle(src.bodyMedium),
      bodySmall: normalizeStyle(src.bodySmall),
      labelLarge: normalizeStyle(src.labelLarge),
      labelMedium: normalizeStyle(src.labelMedium),
      labelSmall: normalizeStyle(src.labelSmall),
    );
  }

  @override
  Widget build(BuildContext context) {
    print(
      '⏱️ [MatchMeApp] build at ${DateTime.now().millisecondsSinceEpoch}',
    );
    final localization = ref.watch(localizationProvider);
    final authState = ref.watch(authStateProvider);

    // Keep the OS app-icon badge in lockstep with the in-app unread state
    // (match banners + unread chats + notification inbox). Previously the
    // badge was only cleared by tapping a push notification, so opening the
    // app from the home-screen icon left a stale red badge forever.
    ref.listen<int?>(iconBadgeCountProvider, (previous, next) {
      if (next == null) return;
      unawaited(AppBadgeService.setCount(next));
    });
    // One-shot: a listener only fires on *changes*, so if chat data is
    // already cached at first build (value never transitions through null)
    // the stale OS badge would otherwise survive this cold start.
    if (!_initialBadgeSyncDone) {
      _initialBadgeSyncDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final initialBadge = ref.read(iconBadgeCountProvider);
        if (initialBadge != null) {
          unawaited(AppBadgeService.setCount(initialBadge));
        }
      });
    }

    // Register quick actions localization listener once, when quick actions are available.
    if (!_quickActionsListenerRegistered && _quickActions != null) {
      ref.listen<LocalizationState>(localizationProvider, (previous, next) {
        _maybeUpdateQuickActions(next);
      });
      _quickActionsListenerRegistered = true;
    }

    Route<dynamic>? appOnGenerateRoute(RouteSettings settings) {
      if (settings.name == null) return null;

      final uri = Uri.parse(settings.name!);

      Map<String, String> parseFragmentParams(String fragment) {
        final f = fragment.trim();
        if (f.isEmpty) return <String, String>{};
        final normalized = f.startsWith('?') ? f.substring(1) : f;
        try {
          return Uri.splitQueryString(normalized);
        } catch (_) {
          return <String, String>{};
        }
      }

      String oauthErrorKey(String? description) {
        final d = (description ?? '').trim();
        final lower = d.toLowerCase();
        if (lower.contains('already registered') ||
            lower.contains('already exists') ||
            lower.contains('user already registered')) {
          return 'authOAuthAccountExists';
        }
        if (lower.contains('cancel') || lower.contains('canceled')) {
          return 'authOAuthCancelled';
        }
        return 'authOAuthFailed';
      }

      final fragmentParams = parseFragmentParams(uri.fragment);
      final allParams = <String, String>{
        ...uri.queryParameters,
        ...fragmentParams,
      };

      final isSupabaseOAuthCallback =
          kIsWeb &&
          (uri.path == '/auth/callback' ||
              uri.path.startsWith('/auth/callback'));
      final hasOAuthError =
          allParams.containsKey('error') ||
          allParams.containsKey('error_description');
      final hasOAuthCode =
          allParams.containsKey('code') || uri.fragment.contains('code=');

      if (isSupabaseOAuthCallback && (hasOAuthCode || hasOAuthError)) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            if (hasOAuthError) {
              final key = oauthErrorKey(
                allParams['error_description'] ?? allParams['error'],
              );
              final rawError =
                  allParams['error_description'] ?? allParams['error'] ?? '';
              String pendingProvider = '';
              try {
                final prefs = await SharedPreferences.getInstance();
                pendingProvider =
                    prefs.getString('pending_oauth_provider') ?? '';
                await prefs.remove('pending_oauth_provider');
              } catch (_) {}
              container
                  .read(authUiMessageProvider.notifier)
                  .setMessage('$key|||$rawError|||$pendingProvider');
            } else {
              await Supabase.instance.client.auth.getSessionFromUrl(Uri.base);
            }
          } catch (error) {
            try {
              // Detect which OAuth provider was being used
              String providerName = '';
              try {
                final prefs = await SharedPreferences.getInstance();
                providerName = prefs.getString('pending_oauth_provider') ?? '';
                await prefs.remove('pending_oauth_provider');
              } catch (_) {}
              // Format the message as key|||rawError|||providerName for auth_screen.dart
              final msg = 'authOAuthProviderFailed|||$error|||$providerName';
              container.read(authUiMessageProvider.notifier).setMessage(msg);
            } catch (_) {}
          } finally {
            try {
              if (kIsWeb) {
                final cleaned = Uri.base.replace(
                  path: '/',
                  query: '',
                  fragment: '',
                );
                html.window.history.replaceState('', cleaned.toString());
              }
            } catch (_) {}
          }
        });
        return null;
      }

      // Check if this is an OAuth redirect (has code in fragment or query)
      final hasCodeInFragment = uri.fragment.contains('code=');
      final hasCodeInQuery =
          uri.queryParameters.containsKey('code') ||
          uri.query.contains('code=');
      if (kIsWeb && (hasCodeInFragment || hasCodeInQuery)) {
        // Handle async OAuth processing
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            // Initialize MSAL first if not already initialized
            var clientId = const String.fromEnvironment(
              'OUTLOOK_CLIENT_ID',
              defaultValue: '',
            ).trim();
            var tenantId = const String.fromEnvironment(
              'OUTLOOK_TENANT_ID',
              defaultValue: '',
            ).trim();
            var redirectUri = const String.fromEnvironment(
              'OUTLOOK_REDIRECT_URI',
              defaultValue: '',
            ).trim();
            if (clientId.isEmpty) {
              clientId = (dotenv.env['OUTLOOK_CLIENT_ID'] ?? '').trim();
            }
            if (tenantId.isEmpty) {
              tenantId = (dotenv.env['OUTLOOK_TENANT_ID'] ?? '').trim();
            }
            if (redirectUri.isEmpty) {
              redirectUri = (dotenv.env['OUTLOOK_REDIRECT_URI'] ?? '').trim();
            }
            if (redirectUri.isEmpty) {
              redirectUri = 'http://localhost:5000';
            }

            if (clientId.isNotEmpty && tenantId.isNotEmpty) {
              if (!OutlookWebAuth.instance.isInitialized) {
                await OutlookWebAuth.instance.initialize(
                  clientId: clientId,
                  tenantId: tenantId,
                  redirectUri: redirectUri,
                );
              }

              // Now handle the redirect callback
              final token = await OutlookWebAuth.instance
                  .handleRedirectCallback();
              if (token != null) {
                // Automatically sync Outlook calendars
                try {
                  final calendarService = CalendarSyncService();
                  await calendarService.retrieveOutlookCalendars();

                  // Navigate to calendar sync screen
                  if (navigatorKey.currentState != null) {
                    navigatorKey.currentState!.pushNamedAndRemoveUntil(
                      '/calendar-sync',
                      (route) => false,
                    );
                  }
                } catch (_) {}
              } else {}
            }
          } catch (_) {
          } finally {
            try {
              final cleaned = Uri.base.replace(
                path: '/',
                query: '',
                fragment: '',
              );
              html.window.history.replaceState('', cleaned.toString());
            } catch (_) {}
          }
        });

        // Return null to show home screen while processing
        return null;
      }

      // Android/iOS deliver custom-scheme OAuth callbacks (e.g.
      // com.example.matchme://login-callback?code=...) to the navigator as
      // "/?code=...". The app_links listener in _setupDeepLinkHandler has
      // already processed the URI, so swallow this route instead of crashing
      // the navigator with an unknown-route exception.
      if (!kIsWeb &&
          (uri.path.isEmpty || uri.path == '/') &&
          uri.queryParameters.containsKey('code')) {
        return MaterialPageRoute(
          settings: settings,
          builder: (context) => const _OAuthCallbackSplash(),
        );
      }

      // Handle /invite?code=XYZ
      if (uri.pathSegments.isNotEmpty && uri.pathSegments[0] == 'invite') {
        final code = uri.queryParameters['code'];
        if (code != null && code.isNotEmpty) {
          return MaterialPageRoute(
            builder: (context) => _ReferralHandler(code: code),
          );
        }
      }

      // Handle /chat/UUID
      if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'chat') {
        final matchId = uri.pathSegments[1];

        if (matchId.isNotEmpty) {
          return MaterialPageRoute(
            builder: (context) => _DeepLinkChatHandler(matchId: matchId),
          );
        }
      }

      return null;
    }

    final appRoutes = <String, WidgetBuilder>{
      ResumeRouteRestore.settingsRoute: (context) => const SettingsScreen(),
      ResumeRouteRestore.notificationsSettingsRoute: (context) =>
          const NotificationsSettingsScreen(),
      ResumeRouteRestore.notificationInboxRoute: (context) =>
          const NotificationInboxScreen(),
      ResumeRouteRestore.securityCenterRoute: (context) =>
          const SecurityCenterScreen(),
      '/subscription-payment': (context) {
        final args =
            ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
        return SubscriptionPaymentScreen(
          tier: args?['tier'] ?? 'gold',
          duration: args?['duration'] ?? 'monthly',
          priceInCents: args?['priceInCents'] ?? 2999,
        );
      },
      '/chat': (context) {
        // This route exists for legacy navigation; notification deep-links should use /chat/<matchId>.
        final rawArgs = ModalRoute.of(context)?.settings.arguments;
        if (rawArgs is Map) {
          final args = Map<String, dynamic>.from(rawArgs);
          final otherNameRaw = (args['otherUserName'] ?? '').toString();
          return ChatScreen(
            matchId: args['matchId'],
            otherUserName: otherNameRaw.trim().isEmpty
                ? 'Chat'
                : otherNameRaw.formatAsFirstNameLastInitial(),
            otherUserId: args['otherUserId'] ?? '',
          );
        }

        // If we somehow landed here from a notification tap, try to recover using native intent extras.
        return const _ChatRouteRecovery();
      },
    };

    // Theme mode controlled by provider. Watched here (before the startup
    // loading gate below) so the very first MaterialApp already renders with
    // the user's saved theme instead of flashing light.
    final themeMode = ref.watch(themeModeProvider);

    // Skip localization loading screen when offline - we have all local data
    // needed to show the app immediately. The authState check below handles
    // the real startup gate.
    final isOffline = !offlineCacheManager.isSupabaseAvailable;
    if (!isOffline &&
        localization.isLoading &&
        localization.supportedLanguages.isEmpty) {
      // Keep routing enabled even while localization is still loading so cold-start deep links
      // like /chat/<matchId> don't get rejected as an unknown initialRoute.
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        onGenerateRoute: appOnGenerateRoute,
        routes: appRoutes,
        theme: AppThemeTokens.lightThemeData(
          textTheme: ThemeData.light().textTheme,
        ),
        darkTheme: AppThemeTokens.darkThemeData(
          textTheme: ThemeData.dark().textTheme,
        ),
        themeMode: themeMode,
        home: const StartupLoaderScaffold(),
      );
    }

    final String lang = localization.currentLocale.languageCode.toLowerCase();
    final TextTheme baseTextTheme = ThemeData.light().textTheme;

    TextTheme selectedTextTheme;
    if (lang == 'he') {
      // For Hebrew UI we prefer the Latin Noto Sans as the primary font so that
      // digit glyphs come from a Latin font (normal, non-spaced digits).
      // Hebrew glyphs will be provided by the Hebrew font via fallbacks.
      selectedTextTheme = baseTextTheme.apply(fontFamily: 'Noto Sans');
    } else if (lang == 'ar') {
      selectedTextTheme = baseTextTheme.apply(fontFamily: 'Noto Sans Arabic');
    } else {
      selectedTextTheme = baseTextTheme.apply(fontFamily: 'Noto Sans');
    }

    // Emoji and CJK glyphs intentionally do NOT ship with the app: every
    // supported target provides them itself. Android, iOS and Windows each
    // install a colour emoji font, so the fallbacks below are enough and the
    // build stays ~10-24 MB smaller than bundling NotoColorEmoji.ttf.
    //
    // Naming the platform fonts is required, not optional. Flutter resolves a
    // missing glyph by walking `fontFamily` then `fontFamilyFallback`; a
    // platform font that is not named is never consulted, so an unnamed
    // "Noto Color Emoji" meant Android could silently fall through to a
    // monochrome symbol font and draw every emoji as a flat outline.
    //
    // Colour fonts come before the monochrome symbol fonts on purpose.
    // Noto Sans Symbols / Symbols2 have no colour glyphs, so if they are
    // reached first the emoji are already drawn flat. Bundling a font would
    // also be a downgrade: it is a hard override, so iOS would lose Apple
    // Color Emoji, which renders better than any alternative.
    //
    // Two separate paths, and they are often confused:
    //   * lib/widgets/emoji_widget.dart renders twemoji PNG images. It is
    //     used only for the reaction picker, displayed reactions, and the
    //     composer's emoji button — a curated set of 22 images.
    //   * Everything else, including any emoji a user TYPES into a message,
    //     bio, event name or search field, is ordinary text and resolves
    //     through the font fallbacks above. This is why the fonts matter and
    //     why the image set cannot replace them: it is a fixed list, and user
    //     input is not.
    //
    // Verified on: Android, iOS, Windows. The web build renders with
    // CanvasKit, which maintains its own font collection and does not inherit
    // the browser's DOM font fallback, so web emoji resolution is worth
    // confirming in Chrome, Safari, Firefox and Edge before release.
    final List<String> emojiFallbacks = [
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Noto Color Emoji',
      'Twemoji Mozilla',
      'EmojiOne Color',
      'Noto Sans Symbols',
      'Noto Sans Symbols2',
      'Noto Serif',
      'Noto Sans Hebrew',
      'Noto Sans Arabic',
    ];

    // Make a local copy of the fallbacks and ensure for Hebrew locales the
    // Hebrew font is available early in the fallback list so script glyphs
    // render correctly while digits will come from the primary (Latin) font.
    final List<String> themeFallbacks = List<String>.from(emojiFallbacks);
    if (lang == 'he') {
      themeFallbacks.insert(0, 'Noto Sans Hebrew');
    }

    final TextTheme finalTextTheme = _normalizeTextTheme(
      selectedTextTheme,
      themeFallbacks,
    );

    final currentUserId = authState.asData?.value.session?.user.id;
    // Watch only the two profile fields the birthday overlay needs. Watching
    // the whole profile rebuilt MatchMeApp (MaterialApp + two ThemeData
    // objects) on every unrelated field that trickled in during profile sync.
    final (DateTime?, String?) birthdayInputs = currentUserId == null
        ? (null, null)
        : ref.watch(
            userProfileProvider(currentUserId).select(
              (profile) => (
                profile.asData?.value?.dateOfBirth,
                profile.asData?.value?.userTimezone,
              ),
            ),
          );
    final isBirthdayToday = _isUsersBirthdayToday(
      dateOfBirth: birthdayInputs.$1,
      userTimezone: birthdayInputs.$2,
    );

    final amoledEnabled = ref.watch(amoledThemeProvider);
    final darkTheme = amoledEnabled
        ? AppThemeTokens.amoledDarkThemeData(textTheme: finalTextTheme)
        : AppThemeTokens.darkThemeData(textTheme: finalTextTheme);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: localization.getString('appName'),
      navigatorObservers: [ChatViewStateService.routeObserver],
      locale: localization.currentLocale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: localization.supportedLanguages
          .map((lang) => Locale(lang.code))
          .toList(),
      localeResolutionCallback: (locale, supportedLocales) {
        // Always return the current app locale to prevent system locale override
        return localization.currentLocale;
      },
      // Light theme defined inline below
      darkTheme: darkTheme,
      themeMode: themeMode,
      builder: (context, child) {
        // Keep system UI overlays in sync with the current theme (updates on rebuild)
        try {
          final currentTheme = Theme.of(context);
          final bool isDark = currentTheme.brightness == Brightness.dark;
          final Color statusBarColor =
              currentTheme.appBarTheme.backgroundColor ??
              currentTheme.colorScheme.surface;
          final Color navBarColor = currentTheme.scaffoldBackgroundColor;
          SystemChrome.setSystemUIOverlayStyle(
            SystemUiOverlayStyle(
              statusBarColor: statusBarColor,
              statusBarIconBrightness: isDark
                  ? Brightness.light
                  : Brightness.dark,
              systemNavigationBarColor: navBarColor,
              systemNavigationBarIconBrightness: isDark
                  ? Brightness.light
                  : Brightness.dark,
            ),
          );
        } catch (_) {}
        // NO-TRUNCATION POLICY (global safety net):
        // 1. Clamp ambient text scaling so a 200% OS font cannot blow up
        //    fixed chrome (AppBar, tabs, badges, buttons) beyond what any
        //    finite phone can lay out. Body content still wraps/scrolls and
        //    shows 100% of its string; only the *scale factor* is bounded.
        // 2. Per-widget, `SafeText` (wrap) and `ShrinkText` (auto-shrink)
        //    in lib/widgets/safe_text.dart guarantee no ellipsis/clip.
        // ✅ Mouse wheel smoothing applied app-wide
        // Always wrap the app content in a SafeArea so all screens respect Android status/navigation bars
        // Additionally add a visual fallback overlay for Android devices that ignore status/nav bar color
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.35,
          child: ScrollConfiguration(
            behavior: const _SmoothScrollBehavior(),
            child: Builder(
              builder: (context) {
                final bool isAndroid =
                    defaultTargetPlatform == TargetPlatform.android;
                final EdgeInsets padding = MediaQuery.of(context).padding;
                final Color barColor = Theme.of(
                  context,
                ).scaffoldBackgroundColor;
                // Text scaler is already clamped by the ancestor above.
                // Bold-text is intentionally preserved (accessibility):
                // wrapping + clamp absorbs its extra width.
                final Widget content = child ?? const SizedBox.shrink();

                return Stack(
                  children: [
                    if (isAndroid) SafeArea(child: content) else content,
                    if (isAndroid && padding.top > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: Container(height: padding.top, color: barColor),
                      ),
                    if (isAndroid && padding.bottom > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: padding.bottom,
                          color: barColor,
                        ),
                      ),
                    if (isAndroid && padding.left > 0)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        child: Container(width: padding.left, color: barColor),
                      ),
                    if (isAndroid && padding.right > 0)
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: Container(width: padding.right, color: barColor),
                      ),
                    Positioned.fill(
                      child: BirthdayOverlay(isBirthdayToday: isBirthdayToday),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
      theme: AppThemeTokens.lightThemeData(textTheme: finalTextTheme),
      home: Directionality(
        textDirection: localization.textDirection,
        child: authState.when(
          data: (state) {
            final user = state.session?.user;
            print(
              '[STARTUP_DIAG] auth_route_state '
              'hasUser=${user != null} '
              'loading=${authState.isLoading} error=${authState.hasError}',
            );
            if (user == null) {
              print('[STARTUP_DIAG] selecting_auth_screen');
              return const AuthScreen();
            }
            // A calendar import borrows the social sign-in flow to obtain a
            // provider access token, which transiently creates a session for
            // the *provider* account. Honouring it would swap the entire widget
            // tree to that account and dump the user on its home screen, so
            // keep rendering the account they are actually signed in as until
            // the original session is restored.
            if (AuthTransitionGuard.shouldIgnoreSessionFor(user.id)) {
              debugPrint(
                '[Auth] ignoring transient provider session for ${user.id} '
                '(calendar OAuth in flight, anchor '
                '${AuthTransitionGuard.anchorUserId})',
              );
              final anchor = _lastRenderedAuthUser;
              if (anchor != null &&
                  anchor.id == AuthTransitionGuard.anchorUserId) {
                // Keep showing the account the user is really signed in as.
                return ProfileCheckScreen(
                  key: ValueKey(anchor.id),
                  user: anchor,
                );
              }
              // No usable anchor (cold start mid-transition): hold a neutral
              // screen rather than switching to the provider account.
              return const StartupLoaderScaffold();
            }
            _lastRenderedAuthUser = user;
            // Key by user id so a different account signing in on the same
            // device gets a fresh ProfileCheckScreen state (loading gate,
            // cached profile future) instead of reusing the previous user's
            // already-resolved home screen — same sequence as a cold start.
            return ProfileCheckScreen(key: ValueKey(user.id), user: user);
          },
          loading: () {
            return const StartupLoaderScaffold();
          },
          error: (err, stack) {
            return Scaffold(
              body: Center(
                child: Text(
                  LocalizationState.defaultTranslation('authStreamError'),
                ),
              ),
            );
          },
        ),
      ),
      navigatorKey: navigatorKey,
      onGenerateRoute: appOnGenerateRoute,
      routes: appRoutes,
    );
  }
}

class _ChatRouteRecovery extends StatefulWidget {
  const _ChatRouteRecovery();

  @override
  State<_ChatRouteRecovery> createState() => _ChatRouteRecoveryState();
}

class _ChatRouteRecoveryState extends State<_ChatRouteRecovery> {
  @override
  void initState() {
    super.initState();
    _recover();
  }

  Future<void> _recover() async {
    try {
      final initial = await BackgroundService.getInitialRoute();
      final matchId = (initial?['matchId'] as String?)?.trim();
      if (!mounted) return;

      if (matchId != null && matchId.isNotEmpty) {
        Navigator.of(context).pushReplacementNamed('/chat/$matchId');
        return;
      }
    } catch (_) {
      // fall through to error UI
    }

    if (!mounted) return;
    // If we landed on the legacy /chat route without arguments (common as an
    // intermediate segment when cold-starting on /chat/<matchId>), do not leave
    // a loading screen on the back stack. Redirect to home instead.
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    // Keep this screen visually neutral; it should redirect immediately.
    return const Scaffold(body: SizedBox.shrink());
  }
}

/// Neutral route shown when a custom-scheme OAuth callback deep link
/// (e.g. com.example.matchme://login-callback?code=...) is delivered to the
/// navigator as "/?code=...". The app_links listener has already handled the
/// code, so we simply pop back to the screen below instead of crashing the
/// navigator with an unknown-route exception.
class _OAuthCallbackSplash extends StatefulWidget {
  const _OAuthCallbackSplash();

  @override
  State<_OAuthCallbackSplash> createState() => _OAuthCallbackSplashState();
}

class _OAuthCallbackSplashState extends State<_OAuthCallbackSplash> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context, rootNavigator: true);
      if (navigator.canPop()) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep this screen visually neutral; it should be popped immediately.
    return const Scaffold(body: SizedBox.shrink());
  }
}

class _DeepLinkChatHandler extends ConsumerStatefulWidget {
  final String matchId;
  const _DeepLinkChatHandler({required this.matchId});

  @override
  ConsumerState<_DeepLinkChatHandler> createState() =>
      _DeepLinkChatHandlerState();
}

class _DeepLinkChatHandlerState extends ConsumerState<_DeepLinkChatHandler>
    with WidgetsBindingObserver {
  static const Duration _resolveTimeout = Duration(seconds: 4);

  bool _resolutionStarted = false;
  bool _resolutionFinished = false;
  bool _didRouteFromHere = false;
  Timer? _resolveSafetyTimer;

  @override
  void dispose() {
    _resolveSafetyTimer?.cancel();
    _resolveSafetyTimer = null;
    super.dispose();
  }

  void _routeOffSplash() {
    if (_didRouteFromHere || !mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!navigator.canPop()) return;
    _didRouteFromHere = true;
    navigator.pop();
  }

  String _wrapLtrIsolateIfNeeded(String text) {
    final t = text.trim();
    if (t.isEmpty) return text;

    // If the name is Latin-only (no strong RTL chars), force it to render as an LTR
    // segment even inside RTL UI, so punctuation like '.' doesn't flip to the front.
    final hasRtl = RegExp(r'[\u0590-\u08FF]').hasMatch(t);
    final hasLatin = RegExp(r'[A-Za-z]').hasMatch(t);
    if (hasLatin && !hasRtl) {
      return '\u2066$t\u2069'; // LRI ... PDI
    }
    return text;
  }

  String _capNameWord(String word) {
    if (word.isEmpty) return word;
    final hyphenParts = word.split('-');
    return hyphenParts
        .map((h) {
          if (h.isEmpty) return h;
          return h
              .split("'")
              .map((s) {
                if (s.isEmpty) return s;
                final lower = s.toLowerCase();
                return '${lower[0].toUpperCase()}${lower.substring(1)}';
              })
              .join("'");
        })
        .join('-');
  }

  String _maskDisplayName(String? fullName) {
    final raw = (fullName ?? '')
        .replaceAll(RegExp('[\u200E\u200F\u202A-\u202E]'), '')
        .trim();
    if (raw.isEmpty) return 'Unknown User';
    final parts = raw.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'Unknown User';
    if (parts.length == 1) return _capNameWord(parts.first);
    final first = _capNameWord(parts.first);
    final last = parts.last;
    final lastInitial = last.isNotEmpty ? last[0].toUpperCase() : '';
    final masked = lastInitial.isEmpty ? first : '$first $lastInitial.';
    return _wrapLtrIsolateIfNeeded(masked);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser == null) return;
      PermissionCoordinator.syncNativePermissionStrings(ref);
      unawaited(() async {
        try {
          await PermissionManager.requestAllMissingPermissionsSequentially(
            context: context,
            ref: ref,
            requestLocation: true,
          );
        } catch (_) {}
      }());
      unawaited(() async {
        try {
          await PermissionCoordinator.checkAndPromptIfNeeded(context, ref);
        } catch (_) {}
      }());
      PermissionCoordinator.handleOnResume(context, ref);
    });
    _kickResolve();
    // Safety net: never leave the user stuck on the splash. If we still
    // haven't routed away after the timeout, pop ourselves off the stack so
    // the user is sent back to the previous screen.
    _resolveSafetyTimer = Timer(_resolveTimeout, () {
      if (!mounted || _resolutionFinished) return;
      debugPrint(
        '⏱️ [DeepLinkChat] Resolve timed out after '
        '${_resolveTimeout.inSeconds}s — popping splash',
      );
      _routeOffSplash();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    ResumeDiagnostics.logThrottled(
      'Permission-aware lifecycle changed: $state',
      category: 'permission-lifecycle-$state',
      minIntervalMs: 250,
    );
    if (state != AppLifecycleState.resumed) return;
    unawaited(ResumeRouteRestore.clearPendingRoute());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser == null) return;
      PermissionCoordinator.syncNativePermissionStrings(ref);
      PermissionCoordinator.handleOnResume(context, ref);
    });
  }

  void _kickResolve() {
    if (_resolutionStarted) return;
    _resolutionStarted = true;
    // Fire-and-forget; _resolveChat manages its own errors and finalisation.
    unawaited(_resolveChat());
  }

  void _markResolved() {
    _resolutionFinished = true;
    _resolveSafetyTimer?.cancel();
    _resolveSafetyTimer = null;
  }

  Future<void> _resolveChat() async {
    try {
      final supabase = Supabase.instance.client;
      var currentUserId = supabase.auth.currentUser?.id;

      // If the auth state isn't ready yet (cold start before the persisted
      // session is restored, or a transient gap right after sign-in), wait
      // briefly for it instead of silently giving up — otherwise the user
      // gets stuck on the splash with no ChatScreen to navigate to.
      if (currentUserId == null) {
        currentUserId = await _awaitSignedInUser();
        if (currentUserId == null) {
          // No signed-in user at all. Pop ourselves so we don't strand the
          // user on a permanent splash.
          _routeOffSplash();
          return;
        }
      }

      // Use maybeSingle() to handle potential duplicates or missing rows gracefully
      final matchData = await supabase
          .from('matches')
          .select('user1_id, user2_id')
          .eq('id', widget.matchId)
          .limit(1)
          .maybeSingle();

      if (matchData == null) {
        _markResolved();
        _routeOffSplash();
        return;
      }

      final otherUserId = matchData['user1_id'] == currentUserId
          ? matchData['user2_id']
          : matchData['user1_id'];

      String resolvedName = '';

      // Prefer users.name as a reliable fallback (matches server-side notification logic).
      try {
        final userRow = await supabase
            .from('users')
            .select('name')
            .eq('id', otherUserId)
            .limit(1)
            .maybeSingle();
        final n = userRow?['name']?.toString().trim();
        if (n != null && n.isNotEmpty) {
          resolvedName = n;
        }
      } catch (_) {}

      // Then try user_profiles (can have multiple intent rows; pick one that has fullName).
      if (resolvedName.isEmpty) {
        try {
          final List profiles = await supabase
              .from('user_profiles')
              .select('profile_data')
              .eq('user_id', otherUserId);

          for (final row in profiles) {
            final pd = (row as Map<String, dynamic>)['profile_data'];
            if (pd is Map && pd['fullName'] != null) {
              final n = pd['fullName']?.toString().trim();
              if (n != null && n.isNotEmpty) {
                resolvedName = n;
                break;
              }
            }
          }
        } catch (_) {}
      }

      final otherUserName = _maskDisplayName(resolvedName);

      if (mounted) {
        _markResolved();
        _didRouteFromHere = true;
        Navigator.of(context, rootNavigator: true).pushReplacement(
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              matchId: widget.matchId,
              otherUserName: otherUserName,
              otherUserId: otherUserId,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ [DeepLinkChat] Resolve failed: $e');
      if (mounted) {
        _markResolved();
        _routeOffSplash();
      }
    }
  }

  /// Waits up to [timeout] for a signed-in user to become available, polling
  /// `supabase.auth.currentUser`. Returns the user id, or `null` if the
  /// timeout elapses / the user is genuinely not signed in.
  Future<String?> _awaitSignedInUser({
    Duration timeout = const Duration(seconds: 3),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    final supabase = Supabase.instance.client;
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      if (!mounted) return null;
      final id = supabase.auth.currentUser?.id;
      if (id != null && id.isNotEmpty) return id;
      // If the auth provider has reported a definitive signed-out state we
      // can stop early — there's no point waiting.
      final authAsync = ref.read(authStateProvider);
      if (authAsync.hasValue) {
        final session = authAsync.value?.session;
        if (session == null) return null;
      }
      await Future.delayed(pollInterval);
    }
    return supabase.auth.currentUser?.id;
  }

  @override
  Widget build(BuildContext context) {
    // Re-attempt resolution if the auth state arrives after our initial
    // attempt found no signed-in user. This handles the cold-start / deep-
    // link case where the session is still being restored.
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      if (_resolutionFinished) return;
      next.whenData((state) {
        final userId = state.session?.user.id;
        if (userId != null && userId.isNotEmpty) {
          _kickResolve();
        } else if (state.session == null) {
          _markResolved();
          _routeOffSplash();
        }
      });
    });
    return const StartupLoaderScaffold();
  }
}

class _ReferralHandler extends ConsumerStatefulWidget {
  final String code;
  const _ReferralHandler({required this.code});
  @override
  ConsumerState<_ReferralHandler> createState() => _ReferralHandlerState();
}

class _ReferralHandlerState extends ConsumerState<_ReferralHandler> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      () async {
        await ref
            .read(referralServiceProvider)
            .handleIncomingReferralCode(widget.code);
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null) {
          final hasReferral = await _hasReferral(user.id);
          if (!hasReferral) {
            await ref
                .read(referralServiceProvider)
                .processPendingReferral(user.id);
          }
        }
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/');
        }
      }();
    });
  }

  @override
  Widget build(BuildContext context) => const StartupLoaderScaffold();
}

/// Pre-cache all translations during bootstrap to ensure offline support

Future<void> _clearStaleProfilesForUser(String userId) async {
  try {
    final db = await LocalDbService.instance;
    await db.clearStaleLocalProfilesForUser(userId);
    UserActivityService.instance.reset();
  } catch (e) {
    debugPrint('[Profile] clearStaleLocalProfilesForUser failed: $e');
  }
}

Future<bool> _hasReferral(String userId) async {
  try {
    final res = await Supabase.instance.client
        .from('referrals')
        .select('id')
        .eq('referee_id', userId)
        .maybeSingle();
    return res != null;
  } catch (e) {
    return false;
  }
}
