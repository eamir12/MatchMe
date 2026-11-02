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
import 'package:matchme/utils/chat_notification_copy.dart';
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
import 'package:matchme/services/chat_route_observer.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/local_db_service.dart'; // Added for explicit init
import 'package:matchme/services/map_tile_cache_service.dart';
import 'package:matchme/services/offline_trail_service.dart';
import 'package:matchme/services/storage_helper.dart'; // Persisted photo URL warmup
import 'package:matchme/services/startup_cache_warmer.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/notification_avatar_service.dart';
import 'package:matchme/services/offline_api_cache.dart';
import 'package:matchme/services/offline_http_client.dart';
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
import 'package:matchme/utils/meetup_alert_card.dart';
import 'package:matchme/utils/resume_route_restore.dart';
import 'package:matchme/utils/time_of_day_ranges.dart';
import 'package:quick_actions/quick_actions.dart';
// (flutter/services.dart already imported above)

import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/screens/meetup/meetup_hub_screen.dart';
import 'package:matchme/screens/meetup/meetup_screen.dart';
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
import 'package:matchme/services/my_user_realtime_service.dart';
import 'package:matchme/widgets/startup_loader.dart';
import 'package:matchme/widgets/birthday_overlay.dart';
import 'package:matchme/widgets/meetup_alert_overlay.dart';
import 'package:matchme/widgets/system_notification_overlay.dart';
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

/// Watches the root navigator for chat deep links so a single notification
/// tap can never open the same conversation twice, and so a deep-link route
/// always replaces itself instead of whatever route happens to be on top of
/// the stack. See lib/services/chat_route_observer.dart for the details.
final ChatRouteObserver chatRouteObserver = ChatRouteObserver();

// MainActivity (Android) can deliver notification taps while the app is running.
// If we receive one before Navigator is ready, keep it here and replay post-frame.
String? _pendingNotificationRoute;
// One meet-up notification tap can arrive through several channels at once
// (FCM initial message, local-notification payload and the native launch
// intent); this keeps the hub from being pushed on top of itself.
String? _lastMeetupRoutePushed;
DateTime? _lastMeetupRoutePushedAt;
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
  final pushType =
      ((data['type'] ?? data['kind'] ?? data['notification_type']) as Object?)
          ?.toString()
          .trim()
          .toLowerCase();
  // Defense-in-depth: server now stamps match_expiry pushes with the target
  // user_id. Drop pushes meant for a different account sharing this device's
  // old FCM token (multi-account testing left stale user_session rows).
  try {
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
  final isMeetupPush = kMeetupAlertKinds.contains(pushType);
  // Proposal and place-change taps land on the planning screen, where the
  // accept/counter decision lives; the other kinds open the hub.
  final isMeetupDecision =
      pushType == kMeetupAlertProposal || pushType == kMeetupAlertPlaceChange;

  final effectiveRoute = (routeFromData != null && routeFromData.isNotEmpty)
      ? routeFromData
      : (matchId != null && matchId.isNotEmpty)
      ? (isMeetupPush
            ? (isMeetupDecision ? '/meetup/$matchId/plan' : '/meetup/$matchId')
            : '/chat/$matchId')
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

  if (effectiveRoute == null ||
      (!effectiveRoute.startsWith('/chat/') &&
          !effectiveRoute.startsWith('/meetup/'))) {
    return;
  }

  // The same meet-up tap can reach the app through several channels at once.
  if (effectiveRoute.startsWith('/meetup/')) {
    final now = DateTime.now();
    final duplicate =
        _lastMeetupRoutePushed == effectiveRoute &&
        _lastMeetupRoutePushedAt != null &&
        now.difference(_lastMeetupRoutePushedAt!) < const Duration(seconds: 2);
    if (duplicate) return;
    _lastMeetupRoutePushed = effectiveRoute;
    _lastMeetupRoutePushedAt = now;
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
}

/// Opens a route carried by a clicked local notification or web card
/// ('/chat/<id>', '/meetup/<id>', '/meetup/<id>/plan').
void _openNotificationRoute(String route) {
  final isMeetup = route.startsWith('/meetup/');
  if (!route.startsWith('/chat/') && !isMeetup) return;
  var rest = route.substring((isMeetup ? '/meetup/' : '/chat/').length).trim();
  // '/meetup/<matchId>/plan' carries the planning-screen suffix; the match id
  // is its first segment only.
  if (isMeetup) {
    final slash = rest.indexOf('/');
    if (slash >= 0) rest = rest.substring(0, slash);
  }
  final matchId = rest;
  if (matchId.isEmpty) return;
  _applyNavigationFromPushData({
    'matchId': matchId,
    'route': route,
  }, isUserInteraction: true);
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

/// The expiry card text: what the server composed in the recipient's language,
/// or the standing fallback when the push carried no copy at all (a data-only
/// delivery — which an alert the recipient's prefs muted becomes — or a channel
/// that cannot render a notification block).
({String title, String body}) _expiryPushCopy(
  String kind,
  RemoteMessage message, [
  Map<String, dynamic> data = const {},
]) {
  final title =
      (message.notification?.title ?? data['notification_title']?.toString())
          ?.trim() ??
      '';
  final body =
      (message.notification?.body ?? data['notification_body']?.toString())
          ?.trim() ??
      '';
  return (
    title: title.isNotEmpty
        ? title
        : kind == 'pinned_expiry'
        ? 'Pinned location expiring soon'
        : 'Match expiring soon',
    body: body.isNotEmpty ? body : 'Open the app to add more time.',
  );
}

/// An expiry push: exactly one card per (match, threshold, expiry window). The
/// in-app scan writes the same gate, so whichever path fired first wins; the
/// OS-scheduled alarm and any server card still in the shade for this exact
/// event are dropped in favor of the card posted here.
///
/// [silent] is the background-isolate case: the system already drew and played
/// the server's card for this event before handing the push to Dart, so the
/// replacement that carries the matched user's face must not announce it twice.
Future<void> _surfaceExpiryPushCard({
  required String kind,
  required Map<String, dynamic> data,
  required String title,
  required String body,
  bool silent = false,
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

    final avatarPhotoSource = matchId.isEmpty
        ? null
        : await _notificationAvatarSourceForMatch(
            matchId,
            otherUserId: (data['otherUserId'] ?? data['other_user_id'] ?? '')
                .toString(),
          );
    if (kIsWeb) {
      await WebNotificationService.showMatchNotification(
        matchId: matchId.isNotEmpty ? matchId : kind,
        matchName: title,
        matchPhotoUrl: avatarPhotoSource ?? '',
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
      silent: silent,
      // A pinned-location warning is keyed on the user, not a chat: only a
      // push that names a match gets the card's tap destination.
      tapRoute: matchId.isNotEmpty ? '/chat/$matchId' : null,
      avatarPhotoSource: avatarPhotoSource,
      beforeShow: serverTag.isEmpty
          ? null
          : () =>
                MobileLocalNotificationService.cancelServerCard(tag: serverTag),
    );
    // Then retire the server's card for this exact event. Two passes, because
    // the SDK builds its notification inside the receiver and can hand it to
    // the system after this handler already ran.
    await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
    await Future<void>.delayed(const Duration(seconds: 1));
    await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
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

Future<String?> _notificationAvatarSourceForMatch(
  String matchId, {
  String? otherUserId,
}) async {
  var profileId = (otherUserId ?? '').trim();
  final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? '';
  if (profileId == currentUserId || profileId.toLowerCase() == 'unknown') {
    profileId = '';
  }
  if (profileId.isEmpty &&
      currentUserId.isNotEmpty &&
      matchId.trim().isNotEmpty) {
    try {
      final chats = await container
          .read(recentChatsProvider(currentUserId).future)
          .timeout(const Duration(seconds: 2));
      for (final chat in chats) {
        if (chat.matchId == matchId &&
            chat.otherUserId.isNotEmpty &&
            chat.otherUserId != currentUserId) {
          profileId = chat.otherUserId;
          break;
        }
      }
    } catch (_) {}
  }
  if (profileId.isEmpty) return null;

  try {
    final profile = await container
        .read(otherUserProfileProvider(profileId).future)
        .timeout(const Duration(seconds: 2));
    final photo = profile?.photos
        .map((source) => source.trim())
        .where((source) => source.isNotEmpty)
        .firstOrNull;
    if (photo == null) return null;
    await NotificationAvatarService.instance
        .mirrorFor(matchId: matchId, photoSource: photo)
        .timeout(const Duration(milliseconds: 1500));
    return photo;
  } catch (_) {
    return null;
  }
}

/// Foreground match push: the native Realtime/poll path may have already
/// posted its own card for this match (or may post one later). Exactly one
/// card per match: whichever path fires first wins, the loser skips, and the
/// match is recorded as buzzed so the periodic poll cannot re-post it.
Future<void> _showForegroundMatchPush({
  required String matchId,
  required String title,
  required String body,
  required String otherUserId,
}) async {
  try {
    final alreadyNotified = await BackgroundService.wasMatchNotified(matchId);
    if (alreadyNotified &&
        !await MobileLocalNotificationService.isNewMatchNotificationActive(
          matchId,
        )) {
      return;
    }
    if (!alreadyNotified) {
      // Reserve the match before resolving its photo so the native poller
      // cannot independently alert. The Dart card shares its notification ID
      // with that poller, so an in-flight card is updated instead of doubled.
      await BackgroundService.markMatchNotified(matchId);
    }
    unawaited(BackgroundService.cancelServerCard('new_match_$matchId'));
    final avatarPhotoSource = await _notificationAvatarSourceForMatch(
      matchId,
      otherUserId: otherUserId,
    );
    await MobileLocalNotificationService.showNewMatchNotification(
      matchId: matchId,
      title: title,
      body: body,
      silent: alreadyNotified,
      dedupeAlreadyClaimed: true,
      avatarPhotoSource: avatarPhotoSource,
    );
  } catch (_) {}
}

/// The chat card fields push-message computed for this recipient.
///
/// Every platform entry point reads them so the card the app draws is the
/// server's copy - the same title, the same collapsed body, the same unread
/// count - instead of a locally invented "New message". `preview_lines` is a
/// JSON array because FCM data values are strings.
ChatPushCardModel _chatPushCardFrom(Map<String, dynamic> data) {
  return ChatPushCardModel.tryFromMap(data) ?? const ChatPushCardModel();
}

/// The card text for a meet-up push: the copy the server composed, else a
/// sentence that names the tool. The fallback matters because a push the OS
/// drew can reach us with the notification block stripped (data-only retries,
/// old queue rows), and a card that says nothing is worse than one that says
/// which tool fired.
({String title, String body}) _meetupPushCopy(
  String kind,
  RemoteMessage message,
  Map<String, dynamic> data,
) {
  final isBeacon = kind == kMeetupAlertBeacon;
  final isSpot = kind == kMeetupAlertSpot;
  final isProposal = kind == kMeetupAlertProposal;
  final fallbackTitle = isBeacon
      ? '📡 MatchMe'
      : isSpot
      ? '📸 MatchMe'
      : isProposal
      ? '📍 MatchMe'
      : '👋 MatchMe';
  final fallbackBody = isBeacon
      ? 'A beacon is on. Open to find each other.'
      : isSpot
      ? 'A Spot me card was shared.'
      : isProposal
      ? 'A meeting point was proposed. Open to review.'
      : kind == kMeetupAlertPlaceChange
      ? 'A new meeting point was suggested. Open to review.'
      : 'A gesture was sent. Open to see it.';
  final pushTitle =
      message.notification?.title ?? data['notification_title']?.toString();
  final pushBody =
      message.notification?.body ?? data['notification_body']?.toString();
  final title = pushTitle?.trim().isNotEmpty == true
      ? pushTitle!.trim()
      : fallbackTitle;
  final body = pushBody?.trim().isNotEmpty == true
      ? pushBody!.trim()
      : fallbackBody;
  return (title: title, body: body);
}

/// The app-owned card for [kind], used on Android's data-only push path and in
/// the foreground. The same key replaces realtime and push-driven updates.
Future<void> _postMeetupPushCard(
  String kind,
  Map<String, dynamic> data,
  RemoteMessage message, {
  bool silent = false,
  String? avatarPhotoSource,
}) async {
  final cardKey = meetupAlertCardKey(kind, data);
  if (cardKey.isEmpty) return;
  final copy = _meetupPushCopy(kind, message, data);
  final serverTag = meetupAlertServerTag(kind, data);
  try {
    await MobileLocalNotificationService.showMeetupNotification(
      notificationId: cardKey,
      title: copy.title,
      body: copy.body,
      matchId: (data['matchId'] ?? data['match_id'] ?? '').toString().trim(),
      kind: kind,
      expiresIn: kMeetupAlertDefaultTtl[kind],
      silent: silent,
      avatarPhotoSource: avatarPhotoSource,
      // Remove any legacy FCM-rendered card only after the avatar asset and
      // local notification details are ready, immediately before the
      // app-owned card is posted. This avoids showing both versions together.
      beforeShow: serverTag.isEmpty
          ? null
          : () =>
                MobileLocalNotificationService.cancelServerCard(tag: serverTag),
    );
  } catch (_) {
    return;
  }
  if (serverTag.isEmpty) return;
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
  await Future<void>.delayed(const Duration(seconds: 1));
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
}

/// The server's localized card copy, delivered as data when the app owns
/// Android/web rendering and as an alert when APNs owns iOS background display.
({String title, String body})? _pushCopyFrom(
  RemoteMessage message, [
  Map<String, dynamic> data = const {},
]) {
  final title =
      (message.notification?.title ?? data['notification_title']?.toString())
          ?.trim() ??
      '';
  final body =
      (message.notification?.body ?? data['notification_body']?.toString())
          ?.trim() ??
      '';
  if (title.isEmpty && body.isEmpty) return null;
  return (title: title, body: body);
}

/// Posts the server-composed chat card under the conversation's single local
/// notification identity. Android receives these as data-only pushes, so this
/// path is the only FCM renderer there.
Future<void> _postChatPushCard(
  Map<String, dynamic> data,
  RemoteMessage message,
) async {
  final chatId = (data['matchId'] ?? data['match_id'] ?? '').toString().trim();
  if (chatId.isEmpty) return;
  final serverTag = 'match_$chatId';
  var card = _chatPushCardFrom(data);
  if (card.title == null && card.body == null) {
    // A retry row with no copy in the card fields: use the transport copy.
    final copy = _pushCopyFrom(message, data);
    if (copy == null) return;
    card = ChatPushCardModel(title: copy.title, body: copy.body);
  }
  final senderName = (data['sender_name'] ?? data['senderName'] ?? 'Someone')
      .toString();
  final messageId = (data['messageId'] ?? data['message_id'])
      ?.toString()
      .trim();
  try {
    await MobileLocalNotificationService.showMessageNotification(
      chatId: chatId,
      matchId: chatId,
      senderName: senderName,
      messageContent: card.body ?? '',
      messageId: messageId,
      alreadyAggregated: true,
      shouldAlertOverride: data['should_alert'] == 'false' ? false : null,
      silent: data['silent'] == 'true',
      card: card,
      beforeShow: () =>
          MobileLocalNotificationService.cancelServerCard(tag: serverTag),
    );
  } catch (_) {
    return;
  }
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
  await Future<void>.delayed(const Duration(seconds: 1));
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
}

/// The same replace for a match-lifecycle push: new match (`new_match_<id>`)
/// and an extension (`match_extended_<id>`). The push carries no sender name in
/// its data block - the copy is the card - so this posts what the system drew,
/// with the matched user's face and the conversation group it belongs to.
///
/// Android uses data-only pushes so this local card is the only renderer.
Future<void> _postMatchPushCard(
  Map<String, dynamic> data,
  RemoteMessage message, {
  required bool extended,
}) async {
  final matchId = (data['matchId'] ?? data['match_id'] ?? '').toString().trim();
  if (matchId.isEmpty) return;
  final copy = _pushCopyFrom(message, data);
  if (copy == null) return;
  final serverTag = extended ? 'match_extended_$matchId' : 'new_match_$matchId';
  try {
    if (extended) {
      await MobileLocalNotificationService.showMatchExtendedNotification(
        matchId: matchId,
        title: copy.title,
        body: copy.body,
        silent: false,
        beforeShow: () =>
            MobileLocalNotificationService.cancelServerCard(tag: serverTag),
      );
    } else {
      await MobileLocalNotificationService.showNewMatchNotification(
        matchId: matchId,
        title: copy.title,
        body: copy.body,
        silent: false,
        beforeShow: () =>
            MobileLocalNotificationService.cancelServerCard(tag: serverTag),
      );
    }
  } catch (_) {
    return;
  }
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
  await Future<void>.delayed(const Duration(seconds: 1));
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
}

/// And for a live-location push (`location_share_<id>`), which the app already
/// draws with the sharer's face while the UI is up: the same card, the same
/// slot, silent, because the delivery the member heard was the system's.
Future<void> _postLocationSharePushCard(
  Map<String, dynamic> data,
  RemoteMessage message,
) async {
  final matchId = (data['matchId'] ?? data['match_id'] ?? '').toString().trim();
  final copy = _pushCopyFrom(message, data);
  if (matchId.isEmpty || copy == null) return;
  final serverTag = 'location_share_$matchId';
  try {
    await MobileLocalNotificationService.showLocationShareNotification(
      notificationId: 'location_share_$matchId',
      matchId: matchId,
      title: copy.title,
      body: copy.body,
      silent: false,
      beforeShow: () =>
          MobileLocalNotificationService.cancelServerCard(tag: serverTag),
    );
  } catch (_) {
    return;
  }
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
  await Future<void>.delayed(const Duration(seconds: 1));
  await MobileLocalNotificationService.cancelServerCard(tag: serverTag);
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
    // re-posting the tray entry the Android/FCM SDK drew for the message's
    // notification block.
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

      // Meet-up pushes carry senderId for routing, but they are not chat: the
      // chat pipeline would replace the card with a conversation card built
      // from an unrelated RPC. They get their own card here - the same one the
      // foreground posts, sender's face and all - so the tray looks the same
      // whatever state the UI was in when the push landed.
      if (kind != null && kMeetupAlertKinds.contains(kind)) {
        await _postMeetupPushCard(kind, data, message);
        return;
      }

      // Handle both current data-only and legacy notification+data payloads so
      // killed/background/reboot pushes still refresh the tray and history.
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

      // Silent retraction tick: the card this chat owns must go away. It is
      // cancelled from here because the retraction push is data-only - there is
      // no new card to replace the old one, and the retracted text stays on
      // screen otherwise. Either card can be the one the member is looking at:
      // the app's own slot, or a legacy SDK-tagged card. Remaining unreads are
      // re-posted by the native poll (or the next launch) through the shared
      // one-buzz-per-message keys.
      if (isRetraction && (matchId != null && matchId.isNotEmpty)) {
        try {
          await MobileLocalNotificationService.dismissChatNotification(matchId);
        } catch (_) {}
        return;
      }

      if (isChat && !isMatch && !isExpiry) {
        // Chat pushes: post the server-composed title, body, unread lines, and
        // count in the one conversation slot. Android/web now receive selected
        // events data-only; older payloads may still have an SDK-rendered card.
        if ((messageId != null && messageId.isNotEmpty) ||
            (matchId != null && matchId.isNotEmpty)) {
          await _postChatPushCard(data, message);
        }
      } else if (isMatch) {
        // Match lifecycle copy is rendered by the client on Android/web; the
        // local notification reuses the same event identity as native fallback.
        await _postMatchPushCard(
          data,
          message,
          extended: kind == 'match_extended',
        );
      } else if (isExpiry) {
        // Android/web render this data-only event locally; iOS still receives
        // an APNs alert. The shared expiry gate suppresses duplicate in-app
        // fallbacks, and the local card includes the matched user's cached face.
        final expiryKind = kind ?? 'match_expiry';
        final copy = _expiryPushCopy(expiryKind, message, data);
        await _surfaceExpiryPushCard(
          kind: expiryKind,
          data: data,
          title: copy.title,
          body: copy.body,
          silent: false,
        );
      } else if (kind == 'location_share') {
        await _postLocationSharePushCard(data, message);
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
        // The card is the server's: its title already carries the total and its
        // body already stands for the batch. The name travels separately,
        // because the title is a sentence and not a sender.
        final card = _chatPushCardFrom(data);
        await MobileLocalNotificationService.showMessageNotification(
          chatId: matchId,
          matchId: matchId,
          senderName: (data['sender_name'] ?? data['senderName'] ?? 'Someone')
              .toString(),
          messageContent: card.body ?? '',
          messageId: messageId,
          alreadyAggregated: true,
          shouldAlertOverride: false,
          card: card,
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

/// Prints the iOS push route for diagnostics.
///
/// The FID is delivered asynchronously through `onRegistered`, and the APNs
/// device token only exists once APNs registration succeeded — which is
/// exactly what fails when the app is signed without the `aps-environment`
/// entitlement. Both are polled for a short while so the log shows the
/// settled state rather than a premature "none".
Future<void> _reportIosPushRoute() async {
  String? apns;
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      final token = await FirebaseMessaging.instance.getAPNSToken();
      if (token != null && token.isNotEmpty) {
        apns = token;
      }
    } catch (_) {}
    if (apns != null && _lastFcmRegistrationId != null) break;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  try {
    debugPrint(
      '🔔 [FCM] iOS push route — FID: ${_lastFcmRegistrationId ?? '(none yet)'}, '
      'APNs token: ${apns == null ? '(none — push cannot be delivered)' : '${apns.substring(0, apns.length < 12 ? apns.length : 12)}…'}',
    );
  } catch (_) {}
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

      // Push diagnostics: the entitlement decides whether APNs registration
      // can succeed at all, and the registration result decides whether FCM
      // can deliver anything. Logging both here makes "no notifications"
      // diagnosable from a single device run.
      try {
        final pushDiag = await AppInfoService.getPushDiagnostics();
        if (pushDiag.isNotEmpty) {
          debugPrint('🔔 [FCM] iOS push diagnostics: $pushDiag');
        }
        final attempted = pushDiag['apnsRegistrationAttempted'] == true;
        final registered = pushDiag['apnsTokenRegistered'] == true;
        final error = pushDiag['apnsRegistrationError']?.toString();
        if (attempted && !registered) {
          debugPrint(
            '🔔 [FCM] APNs REJECTED the registration: ${error ?? 'unknown error'}. '
            'The app is signed without a usable push entitlement — check '
            'ios/Runner/Runner.sideload.entitlements (aps-environment) and '
            'ios/Flutter/Signing.xcconfig. Push cannot be delivered.',
          );
        } else if (!attempted) {
          debugPrint(
            '🔔 [FCM] APNs registration has not completed yet '
            '(normal on the first seconds after launch).',
          );
        }
      } catch (_) {}

      try {
        // Always ask: notification authorization is what local notifications
        // need too, and it is independent of the push entitlement. The
        // entitlement only decides whether APNs can deliver a *remote*
        // notification to this build, so gating the prompt on it used to
        // leave the app with no notification permission at all on builds
        // whose entitlement check failed.
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
        if (!hasApsEntitlement) {
          debugPrint(
            '🔔 [FCM] iOS app is NOT signed with the aps-environment '
            'entitlement — push notifications cannot be delivered. '
            'Check ios/Runner/Runner.sideload.entitlements and '
            'ios/Flutter/Signing.xcconfig.',
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
      MobileLocalNotificationService.onOpenRoute = _openNotificationRoute;
      WebNotificationService.onOpenRoute = _openNotificationRoute;
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
          final pushTitle =
              message.notification?.title ??
              data['notification_title']?.toString();
          final pushBody =
              message.notification?.body ??
              data['notification_body']?.toString();
          final title = pushTitle?.trim().isNotEmpty == true
              ? pushTitle!.trim()
              : 'New Match!';
          final body = pushBody?.trim().isNotEmpty == true
              ? pushBody!.trim()
              : 'You have a new match. Tap to view.';
          final otherUserId =
              (data['otherUserId'] ?? data['other_user_id'] ?? '')
                  .toString()
                  .trim();
          if (matchId.isNotEmpty && !kIsWeb) {
            unawaited(
              _showForegroundMatchPush(
                matchId: matchId,
                title: title,
                body: body,
                otherUserId: otherUserId,
              ),
            );
          } else if (kIsWeb) {
            unawaited(() async {
              final photo = await _notificationAvatarSourceForMatch(
                matchId,
                otherUserId: otherUserId,
              );
              await WebNotificationService.showMatchNotification(
                matchId: matchId.isNotEmpty ? matchId : 'unknown',
                matchName: otherUserId.isNotEmpty ? otherUserId : title,
                matchPhotoUrl: photo ?? '',
                // Same identity as the server push tag: a web card already
                // delivered for this match gets replaced, not duplicated.
                tag: matchId.isNotEmpty ? 'new_match_$matchId' : null,
              );
            }());
          }
        } else if (type == 'match_extended') {
          // Foreground extension push: the peer extended the chat window, so
          // surface it as its own notification rather than reusing the
          // new-match copy ("New Match!" would be wrong and confusing).
          final matchId =
              (data['matchId'] ?? data['match_id'])?.toString().trim() ?? '';
          final pushTitle =
              message.notification?.title ??
              data['notification_title']?.toString();
          final pushBody =
              message.notification?.body ??
              data['notification_body']?.toString();
          final title = pushTitle?.trim().isNotEmpty == true
              ? pushTitle!.trim()
              : 'You have more time';
          final body = pushBody?.trim().isNotEmpty == true
              ? pushBody!.trim()
              : 'Say hi before this match runs out.';
          final otherUserId =
              (data['otherUserId'] ?? data['other_user_id'] ?? '').toString();
          unawaited(() async {
            final photo = await _notificationAvatarSourceForMatch(
              matchId,
              otherUserId: otherUserId,
            );
            if (!kIsWeb && matchId.isNotEmpty) {
              await MobileLocalNotificationService.showMatchExtendedNotification(
                matchId: matchId,
                title: title,
                body: body,
                avatarPhotoSource: photo,
              );
            } else if (kIsWeb && matchId.isNotEmpty) {
              await WebNotificationService.showMatchExtendedNotification(
                matchId: matchId,
                title: title,
                body: body,
                photoSource: photo,
                tag: 'match_extended_$matchId',
              );
            }
          }());
        } else if (type == 'match_expiry' || type == 'pinned_expiry') {
          // Foreground expiry push: one card per (match, threshold, expiry
          // window) — shared gate with the in-app scan, late OS alarm and
          // stale server cards are dropped by the helper.
          final kind = type ?? 'match_expiry';
          final copy = _expiryPushCopy(kind, message, data);
          unawaited(
            _surfaceExpiryPushCard(
              kind: kind,
              data: data,
              title: copy.title,
              body: copy.body,
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
                broadcastId:
                    'ai_quota:${(data['metric'] ?? data['provider'] ?? 'alert').toString()}',
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
          final title =
              (message.notification?.title ??
                          data['notification_title']?.toString())
                      ?.trim()
                      .isNotEmpty ==
                  true
              ? (message.notification?.title ??
                        data['notification_title']?.toString())!
                    .trim()
              : '📍 Live location';
          final body =
              (message.notification?.body ??
                          data['notification_body']?.toString())
                      ?.trim()
                      .isNotEmpty ==
                  true
              ? (message.notification?.body ??
                        data['notification_body']?.toString())!
                    .trim()
              : 'is sharing their live location with you';
          if (matchId.isNotEmpty) {
            final otherUserId = (data['sharerId'] ?? data['sharer_id'] ?? '')
                .toString();
            unawaited(() async {
              final photo = await _notificationAvatarSourceForMatch(
                matchId,
                otherUserId: otherUserId,
              );
              if (kIsWeb) {
                await WebNotificationService.showLocationShareNotification(
                  title: title,
                  body: body,
                  matchId: matchId,
                  photoSource: photo,
                );
              } else {
                await MobileLocalNotificationService.showLocationShareNotification(
                  notificationId: 'location_share_$matchId',
                  matchId: matchId,
                  title: title,
                  body: body,
                  avatarPhotoSource: photo,
                );
              }
            }());
          }
        } else if (type != null && kMeetupAlertKinds.contains(type)) {
          // Foreground meet-up push: Android/iOS do not auto-present FCM
          // alerts, so post the card ourselves. The same event also wrote the
          // inbox row server-side. The tap route opens the meet-up hub, where
          // the incoming card and the coordination tools are.
          //
          // A resend replaces the sender's live row server-side, so this card
          // must replace the old one rather than stack under it: the shared key
          // derivation is the one the alert sweep cancels the card by, and it
          // mirrors the collapse tag the server push carries.
          if (meetupAlertCardKey(type, data).isNotEmpty) {
            final copy = _meetupPushCopy(type, message, data);
            final matchId = (data['matchId'] ?? data['match_id'] ?? '')
                .toString()
                .trim();
            final otherUserId = (data['senderId'] ?? data['sender_id'] ?? '')
                .toString();
            unawaited(() async {
              final photo = await _notificationAvatarSourceForMatch(
                matchId,
                otherUserId: otherUserId,
              );
              if (kIsWeb) {
                await WebNotificationService.showMeetupNotification(
                  notificationId: meetupAlertCardKey(type, data),
                  title: copy.title,
                  body: copy.body,
                  matchId: matchId,
                  kind: type,
                  tag: meetupAlertServerTag(type, data),
                  photoSource: photo,
                );
              } else {
                await _postMeetupPushCard(
                  type,
                  data,
                  message,
                  avatarPhotoSource: photo,
                );
              }
            }());
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
          final card = _chatPushCardFrom(data);
          // The sender's name and nothing else. A push title is a sentence
          // ("3 messages from John S."), and reading it as a name put that
          // sentence in the slot a name belongs.
          final sender =
              (data['senderName'] ?? data['sender_name'] ?? 'Someone')
                  .toString();
          final senderId = (data['senderId'] ?? data['sender_id'] ?? '')
              .toString();
          // The body the server composed, else the notification block it sent
          // with it, else nothing - and "nothing" is a card that states its
          // count, never a canned "New message".
          final text =
              card.body ??
              (message.notification?.body ??
                      data['notification_body']?.toString() ??
                      '')
                  .trim();
          final alreadyAggregated = data['aggregated_messages'] == 'true';
          final alertValue = data['should_alert']?.toString();
          final bool? shouldAlert = alertValue == 'true'
              ? true
              : alertValue == 'false'
              ? false
              : null;
          if (matchId.isNotEmpty) {
            unawaited(() async {
              final photo = await _notificationAvatarSourceForMatch(
                matchId,
                otherUserId: senderId,
              );
              if (kIsWeb) {
                await WebNotificationService.showMessageNotification(
                  chatId: matchId,
                  senderName: sender,
                  messageContent: text,
                  matchId: matchId,
                  alreadyAggregated: alreadyAggregated,
                  shouldAlertOverride: shouldAlert,
                  card: card,
                  photoSource: photo,
                );
              } else if (defaultTargetPlatform == TargetPlatform.android) {
                // Same contract as the background isolate: the server's card,
                // drawn by the native service over the FCM SDK's plain one.
                await BackgroundService.triggerNotificationCheck(
                  matchId: matchId,
                  messageId: messageId.isNotEmpty ? messageId : null,
                  translatedContent: text,
                  originalContent: text,
                  senderName: sender,
                  shouldAlert: shouldAlert,
                  title: card.title,
                  previewLines: card.previewLines,
                  unreadCount: card.unreadCount,
                  previewsEnabled: card.previewsEnabled,
                );
              } else {
                await MobileLocalNotificationService.showMessageNotification(
                  chatId: matchId,
                  senderName: sender,
                  messageContent: text,
                  matchId: matchId,
                  messageId: messageId.isNotEmpty ? messageId : null,
                  alreadyAggregated: alreadyAggregated,
                  shouldAlertOverride: shouldAlert,
                  card: card,
                  avatarPhotoSource: photo,
                );
              }
            }());
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
    try {
      // Diagnostic only: the raw APNs device token proves that APNs has a
      // route to this device. Without it FCM cannot deliver anything to
      // iOS, no matter how correct the FID is.
      //
      // The deprecated `onTokenRefresh` stream is deliberately NOT used:
      // Google warns against mixing the Installation ID APIs with the
      // deprecated registration-token APIs, and the FID above is the push
      // target.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(_reportIosPushRoute());
      }
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
      debugPrint(
        '[BOOTSTRAP] [WNS] Channel fetched before auth; session '
        'registration will attach it',
      );
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
        final windowsLaunch =
            await WindowsPushChannelService.getInitialLaunchPayload();
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

  // Arm the dead-session gate before any screen can render cached data: a
  // known-dead refresh-token family must never paint a signed-in UI, not even
  // for the first frame.
  await SessionService.restoreDeadSessionLatch();
  traceBootstrap('dead_session_latch_restored');

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
            '?? [BOOTSTRAP] OfflineImageCache box opened at ${DateTime.now().millisecondsSinceEpoch}',
          ),
        )
        .catchError((e, st) {
          _reportNonFatal(e, st);
        }),
  );

  // Open the encrypted REST response cache in parallel for the same reason:
  // the first offline read should not pay the Hive box-open cost.
  unawaited(
    hiveInitFuture.then((_) => OfflineApiCache.instance.warmup()).catchError((
      e,
      st,
    ) {
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

  // The SDK spends its own persisted refresh token during initialize's
  // recovery. On Android the background service may have rotated it in
  // another process, leaving the SDK's copy one generation behind — a replay
  // there revokes the whole family. Give the SDK the freshest copy first.
  await SessionService.alignSdkPersistedSessionBeforeInit(
    supabaseUrl: supabaseUrl,
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
          // Read-through encrypted cache for every GET /rest/v1 request:
          // online responses refresh it, offline reads are served from disk.
          httpClient: OfflineSupabaseHttpClient(),
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
  //
  // Publish the runtime config first: the seed's candidate list prefers the
  // SDK's own persisted session, whose storage key is derived from this URL.
  setRuntimeSupabaseConfig(url: supabaseUrl, anonKey: supabaseAnonKey);
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
        .timeout(const Duration(milliseconds: 3000), onTimeout: () => false);
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
        final pending = prefs.getString('pending_oauth_provider')?.trim() ?? '';
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
      debugPrint(
        '⏱️ [BOOTSTRAP] Session recovered, deferring JWT validation off the startup path',
      );
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
      final platformText = SessionService.detectPlatform();
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
        '⏱️ [BOOTSTRAP] Supabase initialization did not settle within budget ($e) — staying optimistic-online, reachability gate decides',
      );
      // DO NOT force the app offline here. The initialize future only awaits
      // the SDK's session recovery — a network round trip that regularly
      // exceeds 5s on a cold, slow connection when the stored session is
      // expired — while the client itself is already constructed (its sync
      // prologue ran before the first await). A slow-but-alive network
      // (probe answered 4.5s into the 5s budget) used to get punished with a
      // forced-offline start: every provider skipped its server fetch, the
      // startup avatar warm silently skipped, and the once-per-process warm
      // guard kept it that way after the online flip — the home screen then
      // painted from a nearly empty cache. Supabase reachability has exactly
      // one owner (the reachability gate + runtime monitor), so run the
      // gate: a genuinely dead network flips the app offline within its
      // budget anyway.
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
      // Same deferred gate + session validation the success path runs.
      _traceBootstrap('reachability_gate_deferred');
      unawaited(_runPostReachabilityGate());
      final recoveredSession = Supabase.instance.client.auth.currentSession;
      if (recoveredSession != null) {
        unawaited(_runBackgroundSessionValidation(recoveredSession, container));
      }
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
      if (Supabase.instance.client.auth.currentSession == null) {
        // No session means setupEncryption would throw "Not authenticated"
        // and log a misleading deferred exception. The resume-refresh or the
        // next successful token renewal will run setup when a session exists.
        debugPrint(
          '⏱️ [BOOTSTRAP] Chat key setup deferred — no active session',
        );
      } else {
        // Only set up encryption if no key exists at all (new user)
        await chatKeyNotifier.setupEncryption();
        debugPrint('⏱️ [BOOTSTRAP] Chat encryption set up for new user');
      }
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

    // Re-read the session instead of trusting the captured one:
    // `Supabase.initialize` fires its own unawaited `recoverSession()` refresh
    // for an expired persisted session, and that refresh may land while the
    // first frame paints. Refreshing on the captured (already stale) session
    // would rotate a token that was just rotated.
    final liveSession =
        Supabase.instance.client.auth.currentSession ?? recoveredSession;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final expiresAt = liveSession.expiresAt;
    if (expiresAt != null && expiresAt <= now + 30) {
      debugPrint(
        '⏱️ [BOOTSTRAP] Token expired or expiring soon (exp=$expiresAt), attempting refresh...',
      );
      // SINGLE REFRESH OWNER: give the SDK's startup recovery first refusal.
      // Two refreshers spending the same single-use token produce
      // already_used responses, and a replay outside GoTrue's reuse window
      // revokes the whole session family.
      final sdkRenewed = await SessionService.awaitSdkStartupRecovery(
        staleExpiresAt: expiresAt,
      );
      if (sdkRenewed != null && !sdkRenewed.isExpired) {
        debugPrint(
          '✅ [BOOTSTRAP] Session renewed by the SDK startup recovery (no second refresh)',
        );
        // This rotation happened inside the SDK, possibly before the auth
        // listener was attached; mirror it so the native background service
        // never holds the pre-rotation token.
        await SessionService.mirrorCurrentSessionToStores();
        invalidateTokenProviders();
        return;
      }
      // Before spending the single-use rotating refresh token (which races
      // the native background service), adopt the service's fresh token pair
      // from the native store — no network, no spend, no race.
      await SessionService.adoptFresherNativeTokensIfExpired();
      final adoptedSession = Supabase.instance.client.auth.currentSession;
      if (adoptedSession != null && !adoptedSession.isExpired) {
        debugPrint(
          '✅ [BOOTSTRAP] Session renewed from the native token store (no refresh needed)',
        );
        invalidateTokenProviders();
        return;
      }
      // A dead family cannot be renewed from this device. Refreshing here
      // would only replay a revoked token — the gate already owns recovery.
      if (SessionService.deadSessionDetected.value) {
        debugPrint(
          '⛔ [BOOTSTRAP] Dead-session latch is armed — skipping token refresh attempts',
        );
        return;
      }
      bool refreshSucceeded = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          // 4s per attempt: the old 1.2s budget times out on a healthy but
          // loaded backend during cold start (DNS + TLS + a slow first
          // response), which produced false "network/timeout" failures from
          // background validation that runs in parallel with the monitor.
          final refreshed = await SessionService.safeRefreshSession(
            timeout: const Duration(milliseconds: 4000),
          ).timeout(const Duration(milliseconds: 4000));
          if (!refreshed) {
            debugPrint(
              '⚠️ [BOOTSTRAP] Token refresh skipped or did not renew the session',
            );
            break;
          }
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
              if (SessionService.deadSessionDetected.value) {
                // Every stored copy was rejected: the family is revoked. The
                // re-login gate is armed, and re-seeding the dead session
                // would only spend another rejected getUser round trip.
                debugPrint(
                  '⛔ [BOOTSTRAP] Refresh family proven dead — gate armed, skipping offline restore/validation',
                );
                return;
              }
              debugPrint(
                '⚠️ [BOOTSTRAP] Token refresh race (already_used) - native may have refreshed, continuing with current session',
              );
              if (Supabase.instance.client.auth.currentSession == null) {
                // The SDK clears its in-memory session when a refresh fails,
                // so this is the normal state after already_used. Put the
                // persisted session back BEFORE the getUser() validation
                // below: validating with no session is a guaranteed
                // AuthSessionMissingException round-trip, and the offline
                // restore may pick up a newer token the native background
                // service rotated in the meantime (no network spend).
                try {
                  final restored =
                      await SessionService.restorePersistedSessionOfflineOnly();
                  debugPrint(
                    '⏱️ [BOOTSTRAP] Post-already-used session restore: restored=$restored',
                  );
                } catch (_) {}
              }
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
        debugPrint(
          '⏱️ [BOOTSTRAP] Skipping getUser due to offline after refresh',
        );
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
        final isNetwork = e is TimeoutException || isExpectedOfflineFailure(e);
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
            errorMsg.contains('auth session missing') ||
            errorMsg.contains('authsessionmissing') ||
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

    // SAFETY NET: the Supabase SDK drops its in-memory session whenever a
    // refresh fails on an expired session (that is what gotrue does for
    // `refresh_token_already_used`). Put the persisted session back so the
    // app keeps a usable (cached) session instead of drifting into a
    // "logged in but no token" state — and never into the login screen.
    try {
      if (Supabase.instance.client.auth.currentSession == null) {
        final restored =
            await SessionService.restorePersistedSessionOfflineOnly();
        debugPrint(
          '⏱️ [BOOTSTRAP] Post-validation session restore: restored=$restored',
        );
      }
    } catch (_) {}
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

  // A proven-dead family cannot be renewed. Probing it again burns a rejected
  // round trip and keeps the refresh storm alive under the re-login gate.
  if (SessionService.deadSessionDetected.value) return true;

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

  // No separate health check here: _applySupabaseReachabilityGate already
  // probes the backend on every startup path, with the anon key, through
  // probeSupabaseReachability, which classifies a 42501/401 as "answered"
  // instead of "offline". A second, authenticated health_check 4s later only
  // duplicated that round trip and could trigger a token refresh.

  // Pre-warm map tiles for every cached match minimap snapshot so match
  // location maps render offline. Online-only, budgeted, de-duplicated per
  // session; re-run after syncs (GlobalHomeSyncManager) picks up new matches.
  unawaited(
    Future.delayed(const Duration(milliseconds: 6000), () {
      // print(), not debugPrint(): the global debugPrint filter in _mainSync
      // drops anything without a whitelisted keyword.
      print('[MapTiles] deferred minimap warm firing (+6s)');
      unawaited(
        MapTileCacheService.instance.warmCachedMatchMinimaps().catchError(
          (_) {},
        ),
      );
    }),
  );

  // Merge any offline places the native background service recorded while
  // the UI was closed into the encrypted trail and upload them (no-ops when
  // offline or when Retro Matching is not enabled).
  unawaited(
    Future.delayed(const Duration(milliseconds: 9000), () {
      unawaited(
        OfflineTrailService.instance.uploadPendingTrail().catchError((_) => 0),
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
        // A non-explicit signedOut means the SDK dropped the session because
        // a refresh failed — the user is STILL logged in and their cached
        // data must not be erased (that would empty the app the moment the
        // network hiccups). Only a real sign-out may wipe it.
        final isExplicitSignOut = SessionService.isExplicitUserSignOutPending;
        if (!isExplicitSignOut) {
          // Not a logout: the non-explicit-signedOut ladder in auth_provider
          // restores the persisted session and re-emits it. Clearing
          // authKeyInitializedUserId here would make the restored event look
          // like an account switch and force a full ChatKeyProvider
          // re-init (a fresh user_chat_keys round-trip) on every refresh
          // race — with the chat-key server read failing mid-window, that
          // left the session without chat keys. Keep everything as-is.
          debugPrint(
            '⏱️ [AUTH] Ignoring non-explicit signedOut — ladder restoring session, chat key provider kept',
          );
          continue;
        }
        debugPrint(
          '⏱️ [AUTH] Explicit signed out — resetting chat key provider',
        );
        var signedOutUserId = authKeyInitializedUserId;
        authKeyInitializedUserId = null;
        if (signedOutUserId == null || signedOutUserId.isEmpty) {
          try {
            signedOutUserId = (await SharedPreferences.getInstance()).getString(
              'user_id',
            );
          } catch (error) {
            debugPrint('[AUTH] Could not read cached outgoing user ID: $error');
          }
        }
        if (!isExplicitSignOut) {
          // Unreachable (handled above) — kept as a hard guarantee that only
          // explicit sign-outs can proceed to cache clearing.
          continue;
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
          // A new sign-in mints a new refresh-token family. Hand it to the
          // native service: a changed refresh token is its only "new sign-in"
          // signal, and the only thing besides a successful refresh allowed
          // to clear its permanent-auth-failure flag.
          try {
            final newSession = supabase.auth.currentSession;
            if (newSession?.accessToken != null) {
              unawaited(
                BackgroundService.updateToken(
                  newSession!.accessToken,
                  refreshToken: newSession.refreshToken,
                ),
              );
            }
          } catch (_) {}
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
            final platformText = SessionService.detectPlatform();
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
          final isExplicitSignOut = SessionService.isExplicitUserSignOutPending;
          if (isExplicitSignOut) {
            UserActivityService.instance.stopHeartbeat();
          }
          try {
            // Only wipe the native credentials for an EXPLICIT sign-out.
            //
            // A non-explicit signedOut means the SDK dropped the session
            // because a refresh failed (expired token / rotation race). The
            // native store holds the FRESHEST rotated refresh token, and
            // passing null here deleted it exactly when it was the only
            // token that could still renew the session.
            if (isExplicitSignOut) {
              await BackgroundService.updateToken(null, refreshToken: null);
            } else {
              debugPrint(
                '⏱️ [AUTH] Non-explicit sign-out — keeping the native refresh-token copy and the background service for recovery',
              );
            }
          } catch (_) {}
          if (isExplicitSignOut) {
            try {
              await BackgroundService.stop();
            } catch (_) {}
          }
          if (kIsWeb && isExplicitSignOut) {
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
            // Mirror every SDK rotation into MatchMe's own stores. The SDK
            // auto-refreshes on hourly ticks and rotates the single-use
            // refresh token; before this mirror those copies stayed at the
            // pre-rotation token. The recovery ladder then replayed a spent
            // token (`refresh_token_already_used`), and on desktop - where
            // nothing else rewrites them - that revoked the whole family.
            unawaited(SessionService.persistCurrentSupabaseSessionSnapshot());
            unawaited(
              SensitiveSessionStore.instance.writeAuthTokens(
                userId: session.user.id,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
              ),
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
        title: ShrinkText(
          LocalizationState.defaultTranslation('configRequired'),
        ),
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

/// Full-screen gate shown while [SessionService.deadSessionDetected] is armed
/// and a session still exists.
///
/// The refresh-token family is revoked server-side, so no request can ever
/// succeed again: a signed-in shell could only show stale cached matches,
/// chats and photos while half the app silently fails. The gate therefore
/// replaces the app subtree entirely (see the `MaterialApp.builder` above)
/// and offers one action — an explicit sign-out to the login screen. There is
/// no dismiss: the only way back into the app is a new, authenticated
/// session.
class DeadSessionGateScreen extends StatefulWidget {
  const DeadSessionGateScreen({
    super.key,
    required this.title,
    required this.body,
    required this.signInAgain,
  });

  final String title;
  final String body;
  final String signInAgain;

  @override
  State<DeadSessionGateScreen> createState() => _DeadSessionGateScreenState();
}

class _DeadSessionGateScreenState extends State<DeadSessionGateScreen> {
  bool _signingOut = false;

  Future<void> _signInAgain() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    await SessionService.signOutExpiredSession(
      'User chose to sign in again after the refresh-token family was '
      'detected as dead',
    );
    if (!mounted) return;
    // The gate normally unmounts by itself once no session remains; if the
    // local sign-out failed, re-enable the button so it can be retried.
    setState(() => _signingOut = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.body,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _signingOut ? null : _signInAgain,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: _signingOut
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(widget.signInAgain),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

  User? _retainedAuthenticatedUserDuringTransientState() {
    final visibleUser = _lastRenderedAuthUser;
    if (visibleUser == null) return null;

    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    return AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: visibleUser.id,
          currentUserId: currentUserId,
        )
        ? visibleUser
        : null;
  }

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
            // Go through the realtime manager so the channels are re-joined
            // when the tab becomes visible again. Calling
            // `realtime.disconnect()` directly dropped the socket without
            // dropping the server-side channel subscriptions, so every
            // `postgres_changes` subscription (settings included) stayed
            // dead for the rest of the tab's lifetime.
            SupabaseRealtimeManager.instance.pauseAll();
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
              if (!_shouldConnectRealtime()) return;
              SupabaseRealtimeManager.instance.resumeAll();
              return;
            }
            debugPrint('🔌 [Web] Reconnecting Supabase Realtime (tab visible)');
            // ignore: invalid_use_of_internal_member
            if (!_shouldConnectRealtime()) {
              debugPrint(
                '🔌 [Web] Skipping Supabase Realtime reconnect (tab visible, no authenticated user)',
              );
              return;
            }
            SupabaseRealtimeManager.instance.resumeAll();

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

                    // Realtime is paused while this tab is hidden, so a
                    // language change made on another device while the tab was
                    // hidden would otherwise wait for the next reconnect.
                    unawaited(
                      ref
                          .read(localizationProvider.notifier)
                          .refreshLanguageFromRemote(),
                    );

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
          // Route through the manager so its state stays consistent with the
          // socket: a restored page (bfcache) must be able to resume
          // cleanly instead of believing its channels are still live.
          SupabaseRealtimeManager.instance.pauseAll();
        } catch (_) {}
      }

      // Update presence when this page closes. The RPC is session-aware: it
      // only marks the account offline when no other device has an active
      // session, so closing a tab on one device never hides a user who is
      // still signed in (and heartbeating) elsewhere.
      DateTime? lastOfflinePresenceAt;
      void markOfflineOnClose(_) {
        // beforeunload and pagehide both fire for the same close. Coalesce
        // them without permanently disabling the handler (the page can be
        // restored from bfcache and closed again later).
        final now = DateTime.now();
        if (lastOfflinePresenceAt != null &&
            now.difference(lastOfflinePresenceAt!) <
                const Duration(seconds: 2)) {
          return;
        }
        final session = supabase.auth.currentSession;
        final userId = session?.user.id;
        final accessToken = session?.accessToken;
        final anonKey = runtimeSupabaseAnonKey;
        if (userId == null || accessToken == null || anonKey == null) return;
        lastOfflinePresenceAt = now;
        debugPrint('?? [Web] Page closing - marking user as offline');
        final offlineData = jsonEncode({
          'p_user_id': userId,
          'p_clear_pinned': false,
        });
        final supabaseUrl = runtimeSupabaseUrl;
        if (supabaseUrl == null) return;
        final beaconUrl = '$supabaseUrl/rest/v1/rpc/set_user_offline';
        final beaconSent = html.sendAuthenticatedOfflineBeacon(
          beaconUrl,
          offlineData,
          accessToken,
          anonKey,
        );

        if (beaconSent) {
          debugPrint('? [Web] Authenticated offline beacon queued');
        } else {
          debugPrint('?? [Web] Beacon failed, falling back to RPC');
          supabase
              .rpc(
                'set_user_offline',
                params: {'p_user_id': userId, 'p_clear_pinned': false},
              )
              .catchError((e) {
                debugPrint('?? [Web] Failed to set user offline on close: $e');
              });
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

    // Watchdog for channels that silently stopped being subscribed (a socket
    // drop that the connectivity layer never saw, a server-side channel that
    // was never joined). Without it, a settings change made on one device
    // simply stopped reaching the other one.
    SupabaseRealtimeManager.instance.startHealthWatchdog();

    // The single realtime subscription to the signed-in user's own row. The
    // theme, language, visibility, preferences and matching-settings
    // notifiers all listen to it, so a change made on one device reaches
    // the others.
    MyUserRealtimeService.instance.start();

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
      // The reconnect may have missed a language change made on another
      // device; this also retries a pick that was made while offline.
      unawaited(
        ref.read(localizationProvider.notifier).refreshLanguageFromRemote(),
      );
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

        if (effectiveRoute == null ||
            (!effectiveRoute.startsWith('/chat/') &&
                !effectiveRoute.startsWith('/meetup/'))) {
          return;
        }

        // The FCM callback usually handles a meet-up tap first and opens the
        // hub; this native intent carries no notification type, so skip its
        // chat route when that just happened.
        if (!effectiveRoute.startsWith('/meetup/') && matchId != null) {
          final meetupPushedAt = _lastMeetupRoutePushedAt;
          final lastMeetup = _lastMeetupRoutePushed;
          if ((lastMeetup == '/meetup/$matchId' ||
                  lastMeetup == '/meetup/$matchId/plan') &&
              meetupPushedAt != null &&
              DateTime.now().difference(meetupPushedAt) <
                  const Duration(seconds: 3)) {
            return;
          }
        }
        if (effectiveRoute.startsWith('/meetup/')) {
          final now = DateTime.now();
          final duplicate =
              _lastMeetupRoutePushed == effectiveRoute &&
              _lastMeetupRoutePushedAt != null &&
              now.difference(_lastMeetupRoutePushedAt!) <
                  const Duration(seconds: 2);
          if (duplicate) return;
          _lastMeetupRoutePushed = effectiveRoute;
          _lastMeetupRoutePushedAt = now;
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
    SupabaseRealtimeManager.instance.stopHealthWatchdog();
    MyUserRealtimeService.instance.stop();
    super.dispose();
  }

  /// Tray text for the Android badge carrier notification ("3 unread").
  ///
  /// The badge *number* is published by the platform; this string is only the
  /// informational body of the carrier notification, so it must never be
  /// treated as the source of truth for the count.
  String _badgeCarrierBody(int count) {
    try {
      return ref
          .read(localizationProvider)
          .getString('inboxUnreadCount', params: {'count': '$count'});
    } catch (_) {
      return '$count';
    }
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
        unawaited(
          AppBadgeService.setCount(
            currentBadge,
            body: _badgeCarrierBody(currentBadge),
          ),
        );
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
        // Realtime channels stay subscribed across short screen-off periods,
        // but a suspended process (iOS) can miss events entirely. Re-read the
        // account language so this device converges as soon as it is visible;
        // this also retries a pending choice that was made while offline.
        unawaited(
          ref.read(localizationProvider.notifier).refreshLanguageFromRemote(),
        );
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
    print('⏱️ [MatchMeApp] build at ${DateTime.now().millisecondsSinceEpoch}');
    final localization = ref.watch(localizationProvider);
    final authState = ref.watch(authStateProvider);

    // Keep the OS app-icon badge in lockstep with the persistent notification
    // inbox. Previously the badge was only cleared by tapping a push
    // notification, so opening the app from the home-screen icon left a stale
    // red badge forever.
    ref.listen<int?>(iconBadgeCountProvider, (previous, next) {
      if (next == null) return;
      unawaited(AppBadgeService.setCount(next, body: _badgeCarrierBody(next)));
    });
    // One-shot: a listener only fires on *changes*, so if inbox data is
    // already cached at first build (value never transitions through null)
    // the stale OS badge would otherwise survive this cold start.
    if (!_initialBadgeSyncDone) {
      _initialBadgeSyncDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final initialBadge = ref.read(iconBadgeCountProvider);
        if (initialBadge != null) {
          unawaited(
            AppBadgeService.setCount(
              initialBadge,
              body: _badgeCarrierBody(initialBadge),
            ),
          );
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

      // Handle /meetup/UUID and /meetup/UUID/plan (planning screen)
      if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'meetup') {
        final matchId = uri.pathSegments[1];

        if (matchId.isNotEmpty) {
          final openPlan =
              uri.pathSegments.length >= 3 && uri.pathSegments[2] == 'plan';
          return MaterialPageRoute(
            settings: settings,
            builder: (context) => _DeepLinkChatHandler(
              matchId: matchId,
              openMeetup: true,
              openPlan: openPlan,
            ),
          );
        }
      }

      // Handle /chat/UUID
      if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'chat') {
        final matchId = uri.pathSegments[1];

        if (matchId.isNotEmpty) {
          return MaterialPageRoute(
            // Keep the route name so the deep link can be identified as the
            // chat deep-link route (see lib/services/chat_route_observer.dart).
            settings: settings,
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
            otherUserName: otherNameRaw.formatAsFirstNameLastInitial(
              fallback: 'Chat',
            ),
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
        localization.supportedLanguages.isEmpty &&
        _retainedAuthenticatedUserDuringTransientState() == null) {
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
      navigatorObservers: [
        ChatViewStateService.routeObserver,
        chatRouteObserver,
      ],
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
        // Resolve to the language the UI actually renders. Normally that is
        // the member's choice, but when the server copy of that language is
        // unavailable the app falls back to the bundled English strings —
        // and then the framework's own strings (date pickers, dialog
        // buttons) have to follow the content as well, otherwise the app
        // mixes languages.
        return Locale(localization.contentLanguageCode);
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
        //
        // The Directionality lives HERE, not on `home:` — the builder wraps
        // the Navigator, so every route (including the pushed onboarding tour)
        // lays out in the direction of the language the app currently shows.
        // Wrapping only `home:` left pushed routes on the direction derived
        // from the chosen locale, which is how English tour text ended up
        // laid out right-to-left.
        return Directionality(
          textDirection: localization.textDirection,
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: 0.85,
            maxScaleFactor: 1.35,
            child: ScrollConfiguration(
              behavior: const _SmoothScrollBehavior(),
              child: ValueListenableBuilder<bool>(
                valueListenable: SessionService.deadSessionDetected,
                builder: (context, deadSession, _) {
                  // A proven-dead refresh-token family cannot back a signed-in
                  // UI: render the gate INSTEAD of the app, so no cached
                  // match, chat or profile can ever show behind it.
                  if (deadSession && authState.value?.session != null) {
                    return DeadSessionGateScreen(
                      title: localization.getString('sessionExpiredTitle'),
                      body: localization.getString('sessionExpiredBody'),
                      signInAgain: localization.getString(
                        'sessionExpiredSignInAgain',
                      ),
                    );
                  }
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
                          child: Container(
                            height: padding.top,
                            color: barColor,
                          ),
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
                          child: Container(
                            width: padding.left,
                            color: barColor,
                          ),
                        ),
                      if (isAndroid && padding.right > 0)
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: padding.right,
                            color: barColor,
                          ),
                        ),
                      Positioned(
                        left: 8,
                        right: 8,
                        top: padding.top + 4,
                        child: const MeetupAlertOverlay(),
                      ),
                      const SystemNotificationOverlay(),
                      Positioned.fill(
                        child: BirthdayOverlay(
                          isBirthdayToday: isBirthdayToday,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
      theme: AppThemeTokens.lightThemeData(textTheme: finalTextTheme),
      // No Directionality wrapper here on purpose: the builder above already
      // applies the app-wide direction and, unlike a wrapper on `home:`, it
      // also covers every pushed route (the onboarding tour included).
      home: authState.when(
        data: (state) {
          final user = state.session?.user;
          print(
            '[STARTUP_DIAG] auth_route_state '
            'hasUser=${user != null} '
            'loading=${authState.isLoading} error=${authState.hasError}',
          );
          if (user == null) {
            final visibleUser = _lastRenderedAuthUser;
            if (visibleUser != null &&
                visibleUser.id == AuthTransitionGuard.anchorUserId &&
                AuthTransitionGuard.shouldDeferAuthEvent(null)) {
              return ProfileCheckScreen(
                key: ValueKey(visibleUser.id),
                user: visibleUser,
              );
            }
            _lastRenderedAuthUser = null;
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
              return ProfileCheckScreen(key: ValueKey(anchor.id), user: anchor);
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
          final visibleUser = _retainedAuthenticatedUserDuringTransientState();
          if (visibleUser != null) {
            return ProfileCheckScreen(
              key: ValueKey(visibleUser.id),
              user: visibleUser,
            );
          }
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
  final bool openMeetup;
  final bool openPlan;
  const _DeepLinkChatHandler({
    required this.matchId,
    this.openMeetup = false,
    this.openPlan = false,
  });

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

  /// True while this route holds the claim on [widget.matchId]. The claim
  /// keeps a second deep link for the same conversation from opening a
  /// second copy of the chat.
  bool _ownsConversationClaim = false;

  /// True once the conversation screen has been pushed. The claim is then
  /// released by [ChatRouteObserver] when that screen goes away, not here.
  bool _pushedConversation = false;

  Timer? _resolveSafetyTimer;

  @override
  void dispose() {
    _resolveSafetyTimer?.cancel();
    _resolveSafetyTimer = null;
    // Give the claim back unless the conversation screen took it over.
    if (_ownsConversationClaim && !_pushedConversation) {
      chatRouteObserver.releaseConversation(widget.matchId);
      _ownsConversationClaim = false;
    }
    super.dispose();
  }

  /// Takes this splash off the navigator stack.
  ///
  /// [Navigator.pop] removes the top-most route, which is not necessarily
  /// this one: with a duplicate deep link pushed on top of it, popping would
  /// have removed the duplicate and left this splash stranded under the
  /// chat - the white screen with the pulsing logo that never went away.
  void _routeOffSplash() {
    if (_didRouteFromHere || !mounted) return;
    _didRouteFromHere = true;
    removeOwnRoute(context);
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

    // One notification tap can reach the app through several channels at
    // once (the FCM callbacks, the Android intent channel and the native
    // launch intent), and each of them pushed its own `/chat/<matchId>`
    // route. Claim the conversation so the first route wins and the
    // duplicates stand down instead of racing it. The meet-up hub is not a
    // conversation, so it relies on the push-level dedupe instead.
    if (!widget.openMeetup) {
      _ownsConversationClaim = chatRouteObserver.claimConversation(
        widget.matchId,
      );
      if (!_ownsConversationClaim) {
        // A duplicate deep link for a conversation that is already being
        // opened. Mark the resolve as started so the auth listener below
        // cannot start a second one, then take this splash off the stack.
        _resolutionStarted = true;
        _resolutionFinished = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _routeOffSplash();
        });
        return;
      }
    }

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

      final otherUserName = resolvedName.formatAsFirstNameLastInitial(
        fallback: 'Unknown User',
      );

      if (widget.openMeetup) {
        var matchType = 'proximity';
        try {
          final matchRow = await supabase
              .from('matches')
              .select('match_type')
              .eq('id', widget.matchId)
              .limit(1)
              .maybeSingle();
          final rawType = matchRow?['match_type']?.toString().trim();
          if (rawType != null && rawType.isNotEmpty) matchType = rawType;
        } catch (_) {
          // Older rows may not carry a type; proximity is the safe default.
        }
        if (mounted) {
          _markResolved();
          _didRouteFromHere = true;
          final routeName = widget.openPlan
              ? '/meetup/${widget.matchId}/plan'
              : '/meetup/${widget.matchId}';
          replaceOwnRoute(
            context,
            MaterialPageRoute(
              settings: RouteSettings(name: routeName),
              builder: (_) => widget.openPlan
                  ? MeetupScreen(
                      matchId: widget.matchId,
                      otherUserId: otherUserId,
                      otherUserName: otherUserName,
                      matchType: matchType,
                    )
                  : MeetupHubScreen(
                      matchId: widget.matchId,
                      otherUserId: otherUserId,
                      otherUserName: otherUserName,
                      matchType: matchType,
                    ),
            ),
          );
        }
        return;
      }

      if (mounted) {
        _markResolved();
        _didRouteFromHere = true;
        // Replace *this* splash with the conversation, not whatever route
        // happens to be on top of the stack. `pushReplacement` replaces the
        // top-most route, so a duplicate deep link pushed above this one
        // used to be removed while this splash survived underneath the chat
        // with its resolve already finished: pressing back then showed the
        // pulsing startup logo forever.
        _pushedConversation = true;
        replaceOwnRoute(
          context,
          MaterialPageRoute(
            settings: RouteSettings(
              name: '$kChatConversationRoutePrefix${widget.matchId}',
            ),
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
