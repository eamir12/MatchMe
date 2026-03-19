// lib/main.dart
import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/screens/auth/auth_screen.dart';
import 'package:matchme/screens/auth/profile_check_screen.dart';
import 'package:matchme/services/outbox_sync_service.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/local_db_service.dart'; // Added for explicit init
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/app_info_service.dart';
import 'package:matchme/services/outlook_web_auth.dart'
    if (dart.library.io) 'package:matchme/services/outlook_web_auth_stub.dart';
import 'package:matchme/utils/permission_helper.dart';
import 'package:matchme/utils/permission_coordinator.dart';
import 'package:matchme/utils/permission_manager.dart';
import 'package:quick_actions/quick_actions.dart';
// (flutter/services.dart already imported above)

import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/chat_provider.dart'
    show pendingMessageTranslationProvider;
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/utils/app_shortcuts.dart';
import 'package:matchme/web_imports.dart' as html;
import 'package:matchme/services/referral_service.dart';
import 'package:matchme/services/admin_broadcast_service.dart';
// ignore: unnecessary_import - Kept for compatibility with other files that depend on it
import 'package:matchme/services/mobile_local_notification_service.dart';

final container = ProviderContainer();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// MainActivity (Android) can deliver notification taps while the app is running.
// If we receive one before Navigator is ready, keep it here and replay post-frame.
String? _pendingNotificationRoute;
bool _fcmHandlersInstalled = false;

late final Future<_BootstrapInitResult> _bootstrapInitFuture;
bool _webFrameKickShutdown = false;
bool _webFrameKickInstalled = false;
Timer? _webWarmupTimer;
DateTime? _webWarmupStartedAt;
bool _webWarmupShutdown = false;
bool _webWarmupInstalled = false;
FlutterExceptionHandler? _webWarmupPrevFlutterErrorHandler;
String? _runtimeSupabaseUrl;
String? _runtimeSupabaseAnonKey;

void _reportNonFatal(Object error, StackTrace stackTrace) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
    ),
  );
}

bool _isIgnorableWebSocketError(Object error) {
  if (!kIsWeb) return false;
  final message = error.toString().toLowerCase();
  return message.contains('websocketchannelexception') &&
      message.contains('websocket connection failed');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Increase buffer size for flutter/lifecycle to avoid "discarded before it could be handled" warnings on Web
  ServicesBinding.instance.channelBuffers.resize('flutter/lifecycle', 20);

  AdminBroadcastService.setProviderContainer(container);
  AdminBroadcastService.setAppInForeground(true);
  MobileLocalNotificationService.setProviderContainer(container);
  WebNotificationService.setProviderContainer(container);
  PlatformDispatcher.instance.onError = (error, stack) {
    if (_isIgnorableWebSocketError(error)) {
      return true;
    }
    if (error is GoogleSignInException &&
        error.code == GoogleSignInExceptionCode.canceled) {
      return true;
    }
    return false;
  };
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null) return;
    final lower = message.toLowerCase();
    if (!lower.contains('translation') &&
        !lower.contains('l10n') &&
        !lower.contains('missing message') &&
        !lower.contains('missing translation') &&
        !lower.contains('calendarsync')) {
      return;
    }
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };

  _installWebVisibilityFrameKick();

  _bootstrapInitFuture = _bootstrapInitialize(container);
  runApp(_BootstrapApp(container: container, initFuture: _bootstrapInitFuture));
  _installWebStartupWarmupFrames();
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
            SchedulerBinding.instance.scheduleWarmUpFrame();
            SchedulerBinding.instance.scheduleFrame();
          } catch (_) {
            shutdownWarmup();
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
        SchedulerBinding.instance.scheduleWarmUpFrame();
        SchedulerBinding.instance.scheduleFrame();
      } catch (_) {
        shutdownWarmup();
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
      shutdownWarmup();
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
  late Future<_BootstrapInitResult> _initFuture;

  static const _loadingApp = MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Center(child: CircularProgressIndicator()),
    ),
  );

  @override
  void initState() {
    super.initState();
    _initFuture = widget.initFuture;
  }

  void _retryBootstrap() {
    setState(() {
      _showMainApp = false;
      _initFuture = _bootstrapInitialize(widget.container);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BootstrapInitResult>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          debugPrint('⏱️ [BOOTSTRAP] Waiting for initFuture at ${DateTime.now().millisecondsSinceEpoch}');
          return _loadingApp;
        }

        final result = snapshot.data;
        debugPrint('⏱️ [BOOTSTRAP] Init complete at ${DateTime.now().millisecondsSinceEpoch}');
        if (snapshot.hasError || result == null) {
          final err = snapshot.error?.toString() ??
              LocalizationState.defaultTranslation('bootstrapUnknownError');
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ProviderScope(
              child: SupabaseInitErrorApp(
                error: err,
                onRetry: _retryBootstrap,
              ),
            ),
          );
        }

        if (result.errorApp != null) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: result.errorApp!,
          );
        }

        // Defer building the full app by one frame so this frame stays light (avoids jank).
        if (!_showMainApp) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _showMainApp = true);
          });
          return _loadingApp;
        }

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

void _applyNavigationFromPushData(Map<String, dynamic> data, {bool isUserInteraction = false}) {
  final matchId =
      ((data['matchId'] ?? data['match_id']) as String?)?.trim();
  final routeFromData =
      ((data['route'] ?? data['deep_link']) as String?)?.trim();
  final tabIndex = _parseTabIndexFromAny(data['tabIndex'] ?? data['tab_index']);

  final effectiveRoute = (routeFromData != null && routeFromData.isNotEmpty)
      ? routeFromData
      : (matchId != null && matchId.isNotEmpty)
          ? '/chat/$matchId'
          : null;

  if (!isUserInteraction) {
    return;
  }

  if (tabIndex != null && tabIndex >= 0 && tabIndex <= 4) {
    AppShortcuts.setPendingTabIndex(tabIndex);
    try {
      container.read(navigationIndexProvider.notifier).setIndex(tabIndex);
    } catch (_) {
    }
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

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    // Handle admin broadcast messages
    AdminBroadcastService.handleBroadcastMessage(message);
    if (defaultTargetPlatform == TargetPlatform.android &&
        (message.notification == null)) {
      final data = Map<String, dynamic>.from(message.data);
      final messageId = (data['messageId'] ?? data['message_id'])?.toString().trim();
      final matchId = (data['matchId'] ?? data['match_id'])?.toString().trim();
      final kind = (data['kind'] ?? data['type'] ?? data['notification_type'])
          ?.toString()
          .trim()
          .toLowerCase();

      if ((messageId != null && messageId.isNotEmpty) ||
          (kind == 'match' && (matchId != null && matchId.isNotEmpty))) {
        final title = (data['title'] ?? data['senderName'] ?? 'MatchMe')
            .toString()
            .trim();
        final body = (data['body'] ?? data['message'] ?? '').toString().trim();

        await BackgroundService.triggerNotificationCheck(
          messageId: (messageId != null && messageId.isNotEmpty) ? messageId : null,
          translatedContent: body.isNotEmpty ? body : null,
          originalContent: body.isNotEmpty ? body : null,
          senderName: title.isNotEmpty ? title : null,
          matchId: (matchId != null && matchId.isNotEmpty) ? matchId : null,
        );
      }
    }
  } catch (_) {
  }
}

Future<void> _initializeFcmForCurrentUser() async {
  if (!_isFcmSupportedPlatform()) return;

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    return;
  }

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await PermissionManager.requestNotificationPermission();
    } catch (_) {
    }
  }

  if (kIsWeb) {
    try {
      await WebNotificationService.initialize();
    } catch (_) {
    }
  }

  if (!_fcmHandlersInstalled) {
    _fcmHandlersInstalled = true;
    if (!kIsWeb) {
      try {
        FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      } catch (_) {
      }
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      var hasApsEntitlement = true;
      try {
        hasApsEntitlement = await AppInfoService.hasApsEnvironmentEntitlement();
      } catch (_) {
      }

      try {
        if (hasApsEntitlement) {
          await FirebaseMessaging.instance.requestPermission(
            alert: true,
            badge: true,
            sound: true,
          );
        }
      } catch (_) {
      }
      try {
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
          alert: false,
          badge: false,
          sound: false,
        );
      } catch (_) {
      }
    }

    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        _applyNavigationFromPushData(Map<String, dynamic>.from(initial.data), isUserInteraction: true);
      }
    } catch (_) {
    }

    try {
      FirebaseMessaging.onMessage.listen((message) {
        // Handle admin broadcast messages
        AdminBroadcastService.handleBroadcastMessage(message);
        final data = Map<String, dynamic>.from(message.data);
        final type = (data['type'] ?? data['kind'] ?? data['notification_type'])
            ?.toString()
            .trim()
            .toLowerCase();
        if (type == 'profile_edit_review') {
          final requestId = (data['request_id'] ?? data['requestId'])?.toString().trim();
          final title = message.notification?.title?.trim();
          final body = message.notification?.body?.trim();
          if (title != null && title.isNotEmpty && body != null && body.isNotEmpty) {
            unawaited(
              MobileLocalNotificationService.showAdminBroadcastNotification(
                broadcastId: requestId?.isNotEmpty == true ? 'profile_edit_review:$requestId' : 'profile_edit_review',
                title: title,
                body: body,
              ),
            );
          }
        }
        // Don't navigate automatically for background messages - just show notification
        _applyNavigationFromPushData(Map<String, dynamic>.from(message.data), isUserInteraction: false);
      });
    } catch (_) {
    }

    try {
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        // Handle admin broadcast message opens
        AdminBroadcastService.handleBroadcastMessageOpened(message);
        // Navigate when user taps on notification
        _applyNavigationFromPushData(Map<String, dynamic>.from(message.data), isUserInteraction: true);
      });
    } catch (_) {
    }

    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final trimmed = newToken.trim();
        if (trimmed.isEmpty) return;
        final current = supabase.auth.currentUser?.id;
        if (current == null || current.isEmpty) return;
        final platformText = kIsWeb
            ? 'web'
            : defaultTargetPlatform == TargetPlatform.android
                ? 'android'
                : 'ios';
        try {
          await SessionService.registerSession(
            current,
            platform: platformText,
            fcmToken: trimmed,
          );
        } catch (_) {
        }
      });
    } catch (_) {
    }
  }

  final userId = supabase.auth.currentUser?.id;
  if (userId == null || userId.isEmpty) return;

  String? token;
  try {
    if (kIsWeb) {
      final envVapid = const String.fromEnvironment('FCM_WEB_VAPID_KEY', defaultValue: '').trim();
      final dotVapid = (dotenv.env['FCM_WEB_VAPID_KEY'] ?? '').trim();
      final vapidKey = envVapid.isNotEmpty ? envVapid : dotVapid;
      token = await FirebaseMessaging.instance.getToken(
        vapidKey: vapidKey.isNotEmpty ? vapidKey : null,
      );
    } else {
      token = await FirebaseMessaging.instance.getToken();
    }
  } catch (_) {
  }

  if (token != null) {
    final trimmed = token.trim();
    if (trimmed.isNotEmpty) {
      try {
        final platformText = kIsWeb
            ? 'web'
            : defaultTargetPlatform == TargetPlatform.android
                ? 'android'
                : 'ios';
        await SessionService.registerSession(
          userId,
          platform: platformText,
          fcmToken: trimmed,
        );
      } catch (_) {
      }
    }
  }
}

class _BootstrapInitResult {
  final Widget? errorApp;
  final String? supabaseUrl;
  final String? supabaseAnonKey;
  const _BootstrapInitResult({this.errorApp, this.supabaseUrl, this.supabaseAnonKey});
}

class _SupabaseRuntimeConfig {
  final String url;
  final String anonKey;
  const _SupabaseRuntimeConfig({required this.url, required this.anonKey});
}

const String _prefsSupabaseUrlKey = 'runtime_supabase_url';
const String _prefsSupabaseAnonKeyKey = 'runtime_supabase_anon_key';

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
      final qpUrl =
          _stripOptionalQuotes(qp['SUPABASE_URL'] ?? qp['supabase_url'] ?? '');
      final qpKey = _stripOptionalQuotes(
        qp['SUPABASE_ANON_KEY'] ?? qp['supabase_anon_key'] ?? '',
      );

      if (url.isEmpty && qpUrl.isNotEmpty) url = qpUrl;
      if (anonKey.isEmpty && qpKey.isNotEmpty) anonKey = qpKey;

      if (prefs != null) {
        if (qpUrl.isNotEmpty) await prefs.setString(_prefsSupabaseUrlKey, qpUrl);
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
      anonKey =
          _stripOptionalQuotes(prefs.getString(_prefsSupabaseAnonKeyKey) ?? '');
    }
  }

  return _SupabaseRuntimeConfig(url: url, anonKey: anonKey);
}

Future<void> _captureWebQueryParams(String currentUrl, String currentKey) async {
  try {
    final qp = Uri.base.queryParameters;
    final qpUrl =
        _stripOptionalQuotes(qp['SUPABASE_URL'] ?? qp['supabase_url'] ?? '');
    final qpKey = _stripOptionalQuotes(
      qp['SUPABASE_ANON_KEY'] ?? qp['supabase_anon_key'] ?? '',
    );

    if (qpUrl.isEmpty && qpKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    if (qpUrl.isNotEmpty) await prefs.setString(_prefsSupabaseUrlKey, qpUrl);
    if (qpKey.isNotEmpty) await prefs.setString(_prefsSupabaseAnonKeyKey, qpKey);
  } catch (e, st) {
    _reportNonFatal(e, st);
  }
}

Future<_BootstrapInitResult> _bootstrapInitialize(ProviderContainer container) async {
  // Yield immediately so main() can call runApp and the first frame (loading indicator) paints before heavy work.
  await Future.delayed(Duration.zero);
  try {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
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
        final backoffMs = min(1500, 80 * (1 << min(attempt, 5)));
        await Future.delayed(Duration(milliseconds: backoffMs));
      }
    }
    if (lastError != null) throw lastError;
  }

  await ensurePluginsReady();

  Future<void> initHive() async {
    Object? lastError;
    final maxAttempts = kIsWeb ? 3 : 12;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await Hive.initFlutter();
        return;
      } on MissingPluginException catch (e) {
        lastError = e;
        final backoffMs = min(2000, 80 * (1 << min(attempt, 5)));
        await Future.delayed(Duration(milliseconds: backoffMs));
      }
    }
    if (lastError != null) throw lastError;
  }

  // Start Hive and DotEnv in parallel
  debugPrint('⏱️ [BOOTSTRAP] Starting parallel init (Hive + DotEnv) at ${DateTime.now().millisecondsSinceEpoch}');
  final hiveInitFuture = initHive();

  final dotenvFuture = dotenv.load(fileName: 'assets/.env').catchError((e, st) {
    _reportNonFatal(e, st);
  });

  // Wait for DotEnv to load BEFORE resolving config, as config accesses dotenv.env
  await dotenvFuture;
  debugPrint('⏱️ [BOOTSTRAP] DotEnv loaded at ${DateTime.now().millisecondsSinceEpoch}');

  final configFuture = _resolveSupabaseRuntimeConfig();

  // Wait for config to be ready before starting Supabase
  final config = await configFuture;
  debugPrint('⏱️ [BOOTSTRAP] Config resolved at ${DateTime.now().millisecondsSinceEpoch}');
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

  // Start Supabase init (Parallel with Hive)
  debugPrint('⏱️ [BOOTSTRAP] Starting Supabase.initialize at ${DateTime.now().millisecondsSinceEpoch}');
  final supabaseInitFuture = Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  // Wait for Hive to be ready before starting LocalDb
  await hiveInitFuture;
  debugPrint('⏱️ [BOOTSTRAP] Hive initialized at ${DateTime.now().millisecondsSinceEpoch}');

  // Start LocalDb init (depends on Hive)
  // We do NOT await this here, so the UI can load while Hive opens boxes.
  unawaited(LocalDbService.instance.catchError((e, st) {
    _reportNonFatal(e, st);
    throw e;
  }).then((_) => debugPrint('⏱️ [BOOTSTRAP] LocalDbService initialized at ${DateTime.now().millisecondsSinceEpoch}')));

  // Await Supabase completion (critical for auth check in MatchMeApp)
  String? supabaseError;
  try {
    final supabaseInstance = await supabaseInitFuture;
    debugPrint('⏱️ [BOOTSTRAP] Supabase initialized at ${DateTime.now().millisecondsSinceEpoch}');
    
    // Verify global instance matches
    if (supabaseInstance.client != Supabase.instance.client) {
      debugPrint('⚠️ [BOOTSTRAP] WARNING: Returned client != Supabase.instance.client');
    }

    // Critical for web: validate recovered session immediately after Supabase init
    // If the restored session has an invalid/expired JWT, clear it and force re-login
    if (kIsWeb) {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        debugPrint('⏱️ [BOOTSTRAP] Web session recovered, validating JWT...');
        try {
          final now = DateTime.now().millisecondsSinceEpoch / 1000;
          final exp = session.expiresAt;
          final expired = exp != null && exp <= now;
          final accessToken = session.accessToken.trim();
          if (expired || accessToken.isEmpty) {
            debugPrint('❌ [BOOTSTRAP] Web session expired/invalid. Clearing persistence and reloading.');
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('supabase.auth.token');
              if (kIsWeb) {
                // html.window.location.reload();
                // Return immediately to avoid further processing while reload happens
                // return _BootstrapInitResult(supabaseUrl: supabaseUrl, supabaseAnonKey: supabaseAnonKey);
                 debugPrint('🔄 [BOOTSTRAP] Web session cleared. Continuing to Auth Screen without reload.');
              }
            } catch (_) {}
          } else {
            await Supabase.instance.client.auth.getUser();
            debugPrint('✅ [BOOTSTRAP] Web session JWT is valid');
          }
        } catch (e) {
          final errorMsg = e.toString().toLowerCase();
          if (errorMsg.contains('invalid jwt') ||
              errorMsg.contains('jwt expired') ||
              errorMsg.contains('unauthorized') ||
              errorMsg.contains('403') ||
              errorMsg.contains('401')) {
            debugPrint('❌ [BOOTSTRAP] Web session JWT is INVALID: $e. Clearing persistence and reloading.');
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('supabase.auth.token');
              if (kIsWeb) {
                 // html.window.location.reload();
                 // return _BootstrapInitResult(supabaseUrl: supabaseUrl, supabaseAnonKey: supabaseAnonKey);
                 debugPrint('🔄 [BOOTSTRAP] Web session cleared (error). Continuing to Auth Screen without reload.');
              }
            } catch (_) {}
          } else {
            debugPrint('⚠️ [BOOTSTRAP] Web session validation error (non-auth): $e');
          }
        }
      }
    }

    var user = Supabase.instance.client.auth.currentUser;
    if (user == null && Supabase.instance.client.auth.currentSession != null) {
      try {
        final refreshed = await Supabase.instance.client.auth.getUser();
        user = refreshed.user;
      } catch (_) {}
    }

    if (user != null) {
      String? url;
      try {
        final dynamic c = Supabase.instance.client;
        url = (c.supabaseUrl as String?)?.trim();
      } catch (_) {}
      debugPrint('[BGSESSION] bootstrap: scheduling registerSession userId=${user.id} url=$url');
      if (kIsWeb) {
        try {
          WebNotificationService.setServiceWorkerUserId(user.id);
        } catch (_) {}
      }
      final platformText = kIsWeb
          ? 'web'
          : defaultTargetPlatform == TargetPlatform.android
              ? 'android'
              : defaultTargetPlatform == TargetPlatform.iOS
                  ? 'ios'
                  : 'unknown';
      unawaited(
        SessionService.registerSession(user.id, platform: platformText).catchError((e, st) {
          _reportNonFatal(e as Object, st as StackTrace);
        }),
      );
    }
  } catch (e) {
    supabaseError = e.toString();
  }

  if (supabaseError != null) {
    throw Exception(supabaseError);
  }

  // Note: We deliberately do NOT await localDbInitFuture here.
  // This allows the UI to render "Loading..." states instead of blocking on splash screen.

  _runtimeSupabaseUrl = supabaseUrl;
  _runtimeSupabaseAnonKey = supabaseAnonKey;

  try {
    container.read(outboxSyncProvider);
  } catch (e, st) {
    _reportNonFatal(e, st);
  }

  ResumeDiagnostics.setEnabled(false);

  return _BootstrapInitResult(
    supabaseUrl: supabaseUrl,
    supabaseAnonKey: supabaseAnonKey,
  );
}

Future<bool> _ensureValidSupabaseSessionOrSignOut() async {
  final session = supabase.auth.currentSession;
  if (session == null) return false;
  if (kIsWeb) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final exp = session.expiresAt;
    if (exp != null && exp <= now) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('supabase.auth.token');
        if (kIsWeb) {
          html.window.location.reload();
          return false;
        }
      } catch (_) {}
      try {
        await supabase.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
      return false;
    }
    if (session.accessToken.trim().isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('supabase.auth.token');
        if (kIsWeb) {
          html.window.location.reload();
          return false;
        }
      } catch (_) {}
      try {
        await supabase.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
      return false;
    }
  }

  try {
    await supabase.auth.getUser();
    return true;
  } catch (e) {
    final lower = e.toString().toLowerCase();
    final shouldSignOut = lower.contains('invalid jwt') ||
        lower.contains('jwt expired') ||
        lower.contains('token is expired') ||
        lower.contains('invalid refresh token') ||
        lower.contains('refresh_token_not_found') ||
        lower.contains('refresh token not found') ||
        lower.contains('refresh_token_already_used') ||
        lower.contains('already used') ||
        lower.contains('unauthorized') ||
        lower.contains('not authorized');
    if (shouldSignOut) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('supabase.auth.token');
        if (kIsWeb) {
          html.window.location.reload();
          return false;
        }
      } catch (_) {}
      try {
        await supabase.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
      return false;
    }
    return true;
  }
}

Future<void> _runDeferredTasks({
  required ProviderContainer container,
  required String supabaseUrl,
  required String supabaseAnonKey,
}) async {
  try {
    container.read(authStateProvider);
    
    // Use default translations directly instead of reading the provider synchronously.
    // The provider might be in a loading state where strings are empty (e.g., during setLocale).
    // Default translations are always available and cover critical keys like bgNotificationTitle.
    final bgTitle = LocalizationState.defaultTranslation('bgNotificationTitle');
    final bgText = LocalizationState.defaultTranslation('bgNotificationText');

    unawaited(BackgroundService.initialize(
      supabaseUrl: supabaseUrl,
      supabaseKey: supabaseAnonKey,
      notificationTitle: bgTitle,
      notificationText: bgText,
    ));

    unawaited(Future.delayed(const Duration(milliseconds: 500), () {
      unawaited(_initializeFcmForCurrentUser());
    }));

    final user = supabase.auth.currentUser;
    if (user != null) {
      final ok = await _ensureValidSupabaseSessionOrSignOut();
      if (ok) {
        // Wait for visibility provider to initialize and calculate effective visibility
        // This prevents starting the background service with incorrect visibility state
        final visibilityNotifier = container.read(isVisibleProvider.notifier);
        await visibilityNotifier.waitForInitialization();
        
        BackgroundService.start();

        unawaited(Future.delayed(const Duration(milliseconds: 900), () async {
          try {
            await container.read(profileSyncProvider).syncProfile(user.id);
          } catch (e, st) {
            _reportNonFatal(e, st);
          }
        }));

        unawaited(Future.delayed(const Duration(milliseconds: 1300), () async {
          await container.read(isVisibleProvider.notifier).ensureServiceStarted();
        }));

        container.read(userProfileProvider(user.id));

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
      unawaited(
        appConfigService.initialize().catchError(
              (e, st) => _reportNonFatal(e as Object, st as StackTrace),
            ),
      );
    }),
  );

  unawaited(
    Future.delayed(const Duration(milliseconds: 1200), () {
      unawaited(
        _performSupabaseHealthCheck().catchError(
              (e, st) => _reportNonFatal(e as Object, st as StackTrace),
            ),
      );
    }),
  );

  if (kIsWeb) {
    unawaited(_deferredBackgroundInit(
      container: container,
      supabaseUrl: supabaseUrl,
      supabaseKey: supabaseAnonKey,
    ));
  } else {
    unawaited(Future.delayed(const Duration(milliseconds: 1500), () {
      unawaited(_deferredBackgroundInit(
        container: container,
        supabaseUrl: supabaseUrl,
        supabaseKey: supabaseAnonKey,
      ));
    }));
  }
}

/// Simple sanity check that the Supabase client can talk to your backend.
/// Uses a lightweight RPC `health_check()` (SECURITY DEFINER) so anonymous clients
/// do not need direct table access to perform the check.
Future<void> _performSupabaseHealthCheck() async {
  try {
    debugPrint('⏱️ [BOOTSTRAP] Performing Supabase health check...');
    // Explicitly check if headers are present before call
    final headers = supabase.headers;
    if (!headers.containsKey('apikey')) {
      debugPrint('🛑 [BOOTSTRAP] CRITICAL: "apikey" header missing from Supabase client headers!');
    } else {
      debugPrint('✅ [BOOTSTRAP] "apikey" header is present.');
    }

    await supabase.rpc('health_check').maybeSingle();
    debugPrint('✅ [BOOTSTRAP] Supabase health check passed.');
  } catch (e) {
    debugPrint('🛑 [BOOTSTRAP] Supabase health check failed: $e');
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
      final parsed = raw is int ? raw : raw is String ? int.tryParse(raw.trim()) : null;
      if (parsed != null && parsed >= 0 && parsed <= 4) {
        AppShortcuts.setPendingTabIndex(parsed);
        try {
          container.read(navigationIndexProvider.notifier).setIndex(parsed);
        } catch (_) {}
      }
    } catch (_) {}

    // Set up token refresh listener
    supabase.auth.onAuthStateChange.listen((event) async {
      if (event.event == AuthChangeEvent.initialSession ||
          event.event == AuthChangeEvent.signedIn) {
        final ok = await _ensureValidSupabaseSessionOrSignOut();
        if (!ok) return;
        final userId = supabase.auth.currentUser?.id;
        if (userId != null && userId.isNotEmpty) {
          if (kIsWeb) {
            try {
              WebNotificationService.setServiceWorkerUserId(userId);
            } catch (_) {
            }
          }
          final platformText = kIsWeb
              ? 'web'
              : defaultTargetPlatform == TargetPlatform.android
                  ? 'android'
                  : defaultTargetPlatform == TargetPlatform.iOS
                      ? 'ios'
                      : 'unknown';
          String? url;
          try {
            final dynamic c = Supabase.instance.client;
            url = (c.supabaseUrl as String?)?.trim();
          } catch (_) {}
          debugPrint('[BGSESSION] authListener: scheduling registerSession userId=$userId url=$url event=${event.event.name}');
          unawaited(
            SessionService.registerSession(userId, platform: platformText).catchError((e, st) {
              _reportNonFatal(e as Object, st as StackTrace);
            }),
          );
          
          // Process any pending referral
          // 1. Check local storage (Deep Link)
          unawaited(container.read(referralServiceProvider).processPendingReferral(userId));
          
          // 2. If no referral processed, check fingerprint (Deferred Deep Link)
          unawaited(_hasReferral(userId).then((hasReferral) async {
            if (!hasReferral) {
               final code = await container.read(referralServiceProvider).checkPendingReferralFromFingerprint();
               if (code != null) {
                 await container.read(referralServiceProvider).handleIncomingReferralCode(code);
                 await container.read(referralServiceProvider).processPendingReferral(userId);
               }
            }
          }));
        }
        unawaited(_initializeFcmForCurrentUser());
      }
      if (event.event == AuthChangeEvent.signedOut) {
        if (kIsWeb) {
          try {
            WebNotificationService.clearServiceWorkerUserId();
          } catch (_) {
          }
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
    }, onError: (error) {
      // Handle stream errors (e.g. Invalid Refresh Token) to prevent app crash
    });
  } catch (_) {
  }
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
      lines.add(
        LocalizationState.defaultTranslation('supabaseWebQueryTip'),
      );
      lines.add(
        LocalizationState.defaultTranslation('supabaseWebQueryExample'),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(LocalizationState.defaultTranslation('configRequired'))),
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
      appBar: AppBar(title: Text(title)),
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
                            LocalizationState.defaultTranslation('generalDetails'),
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
                  child: Text(LocalizationState.defaultTranslation('generalRetry')),
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
    return const ClampingScrollPhysics().applyTo(
      const BouncingScrollPhysics(),
    );
  }
}

class MatchMeApp extends ConsumerStatefulWidget {
  const MatchMeApp({super.key});

  @override
  ConsumerState<MatchMeApp> createState() => _MatchMeAppState();
}

class _MatchMeAppState extends ConsumerState<MatchMeApp> with WidgetsBindingObserver {
  QuickActions? _quickActions;
  String? _lastQuickActionsLang;
  bool _quickActionsListenerRegistered = false;
  bool _quickActionsDisabled = false;
  bool _deferredTasksStarted = false;
  bool _translationSyncRunning = false;
  DateTime? _lastTranslationSyncAt;



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
          ShortcutItem(type: 'matchme_home', localizedTitle: l10n.getString('navHome'), icon: 'home'),
          ShortcutItem(type: 'matchme_matches', localizedTitle: l10n.getString('navMatches'), icon: 'favorite'),
          ShortcutItem(type: 'matchme_chats', localizedTitle: l10n.getString('navChats'), icon: 'message'),
          ShortcutItem(type: 'matchme_profile', localizedTitle: l10n.getString('navProfile'), icon: 'contact'),
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
    try {
      html.document.addEventListener('visibilitychange', (_) {
        try {
          if (html.document.visibilityState == 'hidden' || html.document.hidden == true) {
            debugPrint('🔌 [Web] Disconnecting Supabase Realtime (tab hidden)');
            Supabase.instance.client.realtime.disconnect();
          } else {
            debugPrint('🔌 [Web] Reconnecting Supabase Realtime (tab visible)');
            // ignore: invalid_use_of_internal_member
            Supabase.instance.client.realtime.connect();
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
          final supabaseUrl = _runtimeSupabaseUrl!;
          final beaconUrl = '$supabaseUrl/rest/v1/rpc/set_user_offline';
          final beaconSent = html.sendOfflineBeacon(beaconUrl, offlineData);
          
          if (beaconSent) {
            debugPrint('✅ [Web] Offline beacon sent successfully');
          } else {
            debugPrint('⚠️ [Web] Beacon failed, falling back to RPC');
            // Fall back to regular RPC call
            supabase.rpc('set_user_offline', params: {'p_user_id': userId}).catchError((e) {
              debugPrint('⚠️ [Web] Failed to set user offline on close: $e');
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
    debugPrint('⏱️ [MatchMeApp] initState at ${DateTime.now().millisecondsSinceEpoch}');
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _installWebRealtimeVisibilityDisconnect();
    });

    ref.listenManual(authStateProvider, (prev, next) {
      final session = next.asData?.value.session;
      if (session == null) return;
      unawaited(AdminBroadcastService.replayPendingBlueNotifications());
      _translatePendingMessages();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('⏱️ [MatchMeApp] First Frame Rendered at ${DateTime.now().millisecondsSinceEpoch}');

      if (_deferredTasksStarted) return;
      _deferredTasksStarted = true;

      final url = _runtimeSupabaseUrl;
      final key = _runtimeSupabaseAnonKey;
      if (url != null && url.isNotEmpty && key != null && key.isNotEmpty) {
        unawaited(_runDeferredTasks(
          container: container,
          supabaseUrl: url,
          supabaseAnonKey: key,
        ));
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
      if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
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
    } catch (_) {
    }

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
            if (sharedText != null && sharedText.isNotEmpty) 'sharedText': sharedText,
            if (sharedFilePath != null && sharedFilePath.isNotEmpty) 'sharedFilePath': sharedFilePath,
          };

          try {
            container.read(pendingAddEventShareProvider.notifier).setPayload(payload);
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

        final effectiveRoute = (routeFromNative != null && routeFromNative.isNotEmpty)
            ? routeFromNative
            : (matchId != null && matchId.isNotEmpty)
                ? '/chat/$matchId'
                : null;

        if (tabIndex != null && tabIndex >= 0 && tabIndex <= 4) {
          AppShortcuts.setPendingTabIndex(tabIndex);
          try {
            container.read(navigationIndexProvider.notifier).setIndex(tabIndex);
          } catch (_) {
          }
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
      });
    } catch (_) {
    }

    // Re-apply system UI overlay styles at runtime to handle OEM quirks (e.g., Moto Android 15)
    void applyOverlays() {
      try {
        // Force both top and bottom system overlays visible (manual) and apply style
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom]);
        SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ));
      } catch (_) {
      }
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
        unawaited(PermissionHelper.requestNotificationPermission().catchError((_) {}));
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // When app goes to background, ensure Android background service is ready for realtime notifications
    if (state == AppLifecycleState.paused) {
      // Notify background service to activate realtime monitoring
      BackgroundService.updateAppForeground(false);
      AdminBroadcastService.setAppInForeground(false);

      // Disconnect Supabase Realtime to save battery
      // FCM will handle notifications while we are away
      debugPrint('🔌 Disconnecting Supabase Realtime socket (App Backgrounded)');
      Supabase.instance.client.realtime.disconnect();
    }
    // When app is detached (killed), mark user as offline immediately
    else if (state == AppLifecycleState.detached) {
      debugPrint('🔌 App detached - marking user as offline');
      // Mark user as offline in the database so online counts update immediately
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        // Use synchronous-like call - fire and forget but try to complete
        supabase.rpc('set_user_offline', params: {'p_user_id': userId}).catchError((e) {
          debugPrint('⚠️ Failed to set user offline on detach: $e');
        });
      }
      BackgroundService.updateAppForeground(false);
      AdminBroadcastService.setAppInForeground(false);
    }
    // When app is resumed (not in background), hide the background service notification
    else if (state == AppLifecycleState.resumed) {
      // Reconnect Supabase Realtime
      debugPrint('🔌 Reconnecting Supabase Realtime socket (App Resumed)');
      // ignore: invalid_use_of_internal_member
      Supabase.instance.client.realtime.connect();

      BackgroundService.updateAppForeground(true);
      AdminBroadcastService.setAppInForeground(true);
      unawaited(AdminBroadcastService.replayPendingBlueNotifications());

      // When app resumes from background, translate any pending messages that arrived while closed
      // This ensures all messages show translated versions in the chat history
      _translatePendingMessages();
    }

    // When app resumes, ensure locale is properly maintained and reconnect realtime subscriptions
    if (state == AppLifecycleState.resumed) {
      // Force a rebuild to ensure locale and text direction are maintained
      if (mounted) {
        setState(() {});
      }
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
        now.difference(_lastTranslationSyncAt!) <
            const Duration(seconds: 20)) {
      return;
    }

    _translationSyncRunning = true;
    _lastTranslationSyncAt = now;
    unawaited(() async {
      try {
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
    debugPrint('⏱️ [MatchMeApp] build at ${DateTime.now().millisecondsSinceEpoch}');
    final localization = ref.watch(localizationProvider);
    final authState = ref.watch(authStateProvider);

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

      String oauthErrorMessage(LocalizationState l10n, String? description) {
        final d = (description ?? '').trim();
        final lower = d.toLowerCase();
        if (lower.contains('already registered') ||
            lower.contains('already exists') ||
            lower.contains('user already registered')) {
          return l10n.getString('authOAuthAccountExists');
        }
        if (lower.contains('cancel') || lower.contains('canceled')) {
          return l10n.getString('authOAuthCancelled');
        }
        return d.isNotEmpty ? d : l10n.getString('authOAuthFailed');
      }

      final fragmentParams = parseFragmentParams(uri.fragment);
      final allParams = <String, String>{
        ...uri.queryParameters,
        ...fragmentParams,
      };

      final isSupabaseOAuthCallback =
          kIsWeb && (uri.path == '/auth/callback' || uri.path.startsWith('/auth/callback'));
      final hasOAuthError = allParams.containsKey('error') || allParams.containsKey('error_description');
      final hasOAuthCode = allParams.containsKey('code') || uri.fragment.contains('code=');

      if (isSupabaseOAuthCallback && (hasOAuthCode || hasOAuthError)) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            final l10n = container.read(localizationProvider);
            if (hasOAuthError) {
              final msg = oauthErrorMessage(
                l10n,
                allParams['error_description'] ?? allParams['error'],
              );
              container.read(authUiMessageProvider.notifier).setMessage(msg);
            } else {
              await Supabase.instance.client.auth.getSessionFromUrl(Uri.base);
            }
          } catch (_) {
            try {
              final l10n = container.read(localizationProvider);
              container.read(authUiMessageProvider.notifier).setMessage(
                    l10n.getString('authOAuthFailed'),
                  );
            } catch (_) {}
          } finally {
            try {
              if (kIsWeb) {
                final cleaned = Uri.base.replace(path: '/', query: '', fragment: '');
                html.window.history.replaceState(null, '', cleaned.toString());
              }
            } catch (_) {}
          }
        });
        return null;
      }

      // Check if this is an OAuth redirect (has code in fragment or query)
      final hasCodeInFragment = uri.fragment.contains('code=');
      final hasCodeInQuery =
          uri.queryParameters.containsKey('code') || uri.query.contains('code=');
      if (kIsWeb && (hasCodeInFragment || hasCodeInQuery)) {
        // Handle async OAuth processing
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            // Initialize MSAL first if not already initialized
            var clientId =
                const String.fromEnvironment('OUTLOOK_CLIENT_ID', defaultValue: '').trim();
            var tenantId =
                const String.fromEnvironment('OUTLOOK_TENANT_ID', defaultValue: '').trim();
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
              final token = await OutlookWebAuth.instance.handleRedirectCallback();
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
                } catch (_) {
                }
              } else {
              }
            }
          } catch (_) {
          } finally {
            try {
              final cleaned = Uri.base.replace(path: '/', query: '', fragment: '');
              html.window.history.replaceState(null, '', cleaned.toString());
            } catch (_) {}
          }
        });
        
        // Return null to show home screen while processing
        return null;
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
      '/chat': (context) {
        // This route exists for legacy navigation; notification deep-links should use /chat/<matchId>.
        final rawArgs = ModalRoute.of(context)?.settings.arguments;
        if (rawArgs is Map) {
          final args = Map<String, dynamic>.from(rawArgs);
          final otherNameRaw = (args['otherUserName'] ?? '').toString();
          return ChatScreen(
            matchId: args['matchId'],
            otherUserName: otherNameRaw.trim().isEmpty ? 'Chat' : otherNameRaw.formatAsFirstNameLastInitial(),
            otherUserId: args['otherUserId'] ?? '',
          );
        }

        // If we somehow landed here from a notification tap, try to recover using native intent extras.
        return const _ChatRouteRecovery();
      },
    };

    if (localization.isLoading && localization.supportedLanguages.isEmpty) {
      // Keep routing enabled even while localization is still loading so cold-start deep links
      // like /chat/<matchId> don't get rejected as an unknown initialRoute.
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        onGenerateRoute: appOnGenerateRoute,
        routes: appRoutes,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
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

    final List<String> emojiFallbacks = [
      'Noto Color Emoji',
      'Noto Sans Symbols',
      'Noto Sans Symbols2',
      'Noto Serif',
      'Segoe UI Emoji',
      'Apple Color Emoji',
      'Noto Sans Hebrew',
      'Noto Sans Arabic',
      'Noto Sans TC',
    ];

    // Make a local copy of the fallbacks and ensure for Hebrew locales the
    // Hebrew font is available early in the fallback list so script glyphs
    // render correctly while digits will come from the primary (Latin) font.
    final List<String> themeFallbacks = List<String>.from(emojiFallbacks);
    if (lang == 'he') {
      themeFallbacks.insert(0, 'Noto Sans Hebrew');
    }

    final TextTheme finalTextTheme =
        _normalizeTextTheme(selectedTextTheme, themeFallbacks);

    // Theme mode controlled by provider
    final themeMode = ref.watch(themeModeProvider);

    // Dark theme
    final colorSchemeDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1),
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFF6366F1),
      secondary: const Color(0xFFEC4899),
      surface: const Color(0xFF0F172A),
      onSurface: const Color(0xFFE6EEF8),
    );

    final darkTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorSchemeDark,
      appBarTheme: AppBarTheme(
        backgroundColor: colorSchemeDark.surface,
        foregroundColor: colorSchemeDark.onSurface,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Noto Sans',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorSchemeDark.onSurface,
        ),
      ),
      textTheme: finalTextTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      // Semantic success colors for status indicators (dark)
      extensions: const <ThemeExtension<dynamic>>[
        // success = green-400, successContainer = green-900 translucent
        // Chosen to be visible on dark backgrounds
        SemanticColors(success: Color(0xFF34D399), successContainer: Color(0xFF052E16)),
      ],
    );

    // Light theme color scheme declared here so we can reference 'surface' consistently
    final colorSchemeLight = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1), // Modern indigo
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(0xFF6366F1),
      secondary: const Color(0xFFEC4899), // Pink accent
      tertiary: const Color(0xFFF59E0B), // Amber
      surface: const Color(0xFFF8FAFC), // Light gray background
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: const Color(0xFF1E293B), // Dark slate
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: localization.getString('appName'),
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
          final Color statusBarColor = currentTheme.appBarTheme.backgroundColor ?? currentTheme.colorScheme.surface;
          final Color navBarColor = currentTheme.scaffoldBackgroundColor;
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: statusBarColor,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: navBarColor,
            systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          ));
        } catch (_) {
        }
        // ✅ Mouse wheel smoothing applied app-wide
        // Always wrap the app content in a SafeArea so all screens respect Android status/navigation bars
        // Additionally add a visual fallback overlay for Android devices that ignore status/nav bar color
        return ScrollConfiguration(
          behavior: const _SmoothScrollBehavior(),
          child: Builder(builder: (context) {
            final bool isAndroid = defaultTargetPlatform == TargetPlatform.android;
            final EdgeInsets padding = MediaQuery.of(context).padding;
            final Color barColor = Theme.of(context).scaffoldBackgroundColor;
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
              ],
            );
          }),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        // Add a conservative fontFamilyFallback so ASCII digits can fall back to a Latin font
        // with more conventional digit glyphs when needed. This helps avoid proportional or
        // spaced digit glyphs showing up unexpectedly in Hebrew UI due to font fallbacks.
        fontFamilyFallback: ['Noto Sans', 'Roboto', 'Segoe UI', 'Helvetica Neue'],
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Modern indigo
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFFEC4899), // Pink accent
          tertiary: const Color(0xFFF59E0B), // Amber
          surface: const Color(0xFFF8FAFC), // Light gray background
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: const Color(0xFF1E293B), // Dark slate
        ),
        // Semantic success colors for status indicators (light)
        extensions: const <ThemeExtension<dynamic>>[
          // success = green-500, successContainer = light green background
          SemanticColors(success: Color(0xFF10B981), successContainer: Color(0xFFDCFCE7)),
        ],

        appBarTheme: AppBarTheme(
          backgroundColor: colorSchemeLight.surface,
          foregroundColor: colorSchemeLight.onSurface,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontFamily: 'Noto Sans',
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: colorSchemeLight.onSurface,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: colorSchemeLight.primary,
            foregroundColor: colorSchemeLight.onPrimary,
            elevation: 0,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: colorSchemeLight.primary,
            foregroundColor: colorSchemeLight.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: colorSchemeLight.primary,
            side: BorderSide(color: colorSchemeLight.primary, width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: colorSchemeLight.surface,
          selectedItemColor: colorSchemeLight.primary,
          unselectedItemColor: colorSchemeLight.onSurface.withValues(alpha:0.6),
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
          elevation: 8,
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha:0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          color: colorSchemeLight.surface,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: colorSchemeLight.surfaceContainerHighest,
          selectedColor: colorSchemeLight.primary.withValues(alpha:0.1),
          checkmarkColor: colorSchemeLight.primary,
          labelStyle: TextStyle(color: colorSchemeLight.onSurface),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorSchemeLight.surfaceContainerHighest),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorSchemeLight.primary, width: 2),
          ),
          labelStyle: TextStyle(color: colorSchemeLight.onSurface.withValues(alpha:0.7)),
          filled: true,
          fillColor: colorSchemeLight.surface,
        ),
        textTheme: finalTextTheme.apply(bodyColor: colorSchemeLight.onSurface, displayColor: colorSchemeLight.onSurface).copyWith(
          headlineLarge: finalTextTheme.headlineLarge?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          headlineMedium: finalTextTheme.headlineMedium?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
          ),
          titleLarge: finalTextTheme.titleLarge?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: finalTextTheme.bodyLarge?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w400,
            height: 1.5,
          ),
        ),
        dividerTheme: DividerThemeData(
          color: colorSchemeLight.surfaceContainerHighest,
          thickness: 1,
        ),
      ),
      home: Directionality(
        textDirection: localization.textDirection,
        child: authState.when(
          data: (state) {
            final user = state.session?.user;
            if (user == null) {
              return const AuthScreen();
            } else {
              return ProfileCheckScreen(user: user);
            }
          },
          loading: () {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          },
          error: (err, stack) {
            return Scaffold(
              body: Center(child: Text('${LocalizationState.defaultTranslation('authStreamError')}: $err')),
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

class _DeepLinkChatHandler extends ConsumerStatefulWidget {
  final String matchId;
  const _DeepLinkChatHandler({required this.matchId});

  @override
  ConsumerState<_DeepLinkChatHandler> createState() => _DeepLinkChatHandlerState();
}

class _DeepLinkChatHandlerState extends ConsumerState<_DeepLinkChatHandler> with WidgetsBindingObserver {
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

  String _maskDisplayName(String? fullName) {
    final raw = (fullName ?? '').trim();
    if (raw.isEmpty) return 'Unknown User';
    final parts = raw.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'Unknown User';
    if (parts.length == 1) return parts.first;
    final first = parts.first;
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
    _resolveChat();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser == null) return;
      PermissionCoordinator.syncNativePermissionStrings(ref);
      PermissionCoordinator.handleOnResume(context, ref);
    });
  }

  Future<void> _resolveChat() async {
    try {
      final supabase = Supabase.instance.client;
      final currentUserId = supabase.auth.currentUser?.id;

      if (currentUserId != null) {
        // Use maybeSingle() to handle potential duplicates or missing rows gracefully
        final matchData = await supabase
            .from('matches')
            .select('user1_id, user2_id')
            .eq('id', widget.matchId)
            .limit(1)
            .maybeSingle();

        if (matchData == null) {
          if (mounted) Navigator.of(context).pop();
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
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                matchId: widget.matchId,
                otherUserName: otherUserName,
                otherUserId: otherUserId,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Go back if failed
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
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
        await ref.read(referralServiceProvider).handleIncomingReferralCode(widget.code);
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null) {
          final hasReferral = await _hasReferral(user.id);
          if (!hasReferral) {
            await ref.read(referralServiceProvider).processPendingReferral(user.id);
          }
        }
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/');
        }
      }();
    });
  }
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

Future<bool> _hasReferral(String userId) async {
  try {
    final res = await Supabase.instance.client.from('referrals').select('id').eq('referee_id', userId).maybeSingle();
    return res != null;
  } catch (e) {
    return false;
  }
}
