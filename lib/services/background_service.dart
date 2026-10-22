// lib/services/background_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/session_registration_coordinator.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/utils/offline_utils.dart';

/// Background service that maintains app functionality when UI is closed
class BackgroundService {
  static const MethodChannel _channel = MethodChannel(
    'matchme/background_service',
  );
  static const MethodChannel _mainActivityChannel = MethodChannel(
    'matchme/main_activity',
  );
  static const String _serviceName = 'MatchMeBackgroundService';

  /// Store localized permission texts for native (post-reboot) notifications.
  static Future<void> setNativePermissionStrings(
    Map<String, String> strings,
  ) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setPermissionStrings', strings);
    } catch (e) {
      // print('Failed to set native permission strings: $e');
    }
  }

  /// Store localized strings for the persistent "MatchMe Active" foreground
  /// notification so it appears in the user's chosen display language, and
  /// refresh the notification if the service is currently in the foreground.
  ///
  /// [genericBody] is the masked chat-notification body shown when the user
  /// disabled message previews; the Kotlin poller reads it from prefs
  /// (flutter.notifications_generic_message_body) so killed/background trays
  /// match the display language instead of falling back to English.
  static Future<void> setNativeBackgroundNotificationStrings({
    required String title,
    required String text,
    String? genericBody,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // Persist via SharedPreferences (flutter.* keys are read by the native
      // service's createNotification()) for survival across process death /
      // reboot, and also notify the native side to refresh the live
      // notification immediately.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bgNotificationTitle', title);
      await prefs.setString('bgNotificationText', text);
      if (genericBody != null && genericBody.isNotEmpty) {
        await prefs.setString(
          'notifications_generic_message_body',
          genericBody,
        );
      }
    } catch (_) {}
    try {
      await _channel.invokeMethod('setBackgroundNotificationStrings', {
        'title': title,
        'text': text,
      });
    } catch (_) {
      // Fallback: at least try to refresh via the dedicated channel.
      try {
        await _channel.invokeMethod('refreshBackgroundNotification');
      } catch (_) {}
    }
  }

  /// Ask the native service to re-create its foreground notification (e.g.
  /// after the display language changed). No-op if the service is not in the
  /// foreground.
  static Future<void> refreshNativeBackgroundNotification() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('refreshBackgroundNotification');
    } catch (_) {}
  }

  /// Returns the last permission issue reported by the native background service (if any),
  /// and clears it so it won't show repeatedly.
  ///
  /// Cross-platform: Android records these codes natively (foreground-service
  /// permission blocks); iOS records `location_always` when the app only has
  /// "While Using the App" authorization, which silently disables background
  /// location once the UI is closed.
  static Future<String?> consumeNativePermissionIssueCode() async {
    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod('consumePermissionIssue');
      final code = result?.toString().trim();
      return (code == null || code.isEmpty) ? null : code;
    } catch (_) {
      return null;
    }
  }

  /// Record a permission issue so it can be surfaced as a dialog next time the UI is active.
  static Future<void> setNativePermissionIssueCode(String code) async {
    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return;
    }
    try {
      await _channel.invokeMethod('setPermissionIssue', {'code': code});
    } catch (e) {
      // print('Failed to set native permission issue code: $e');
    }
  }

  /// The native layer's view of the location authorization status.
  ///
  /// Returns one of `notDetermined`, `restricted`, `denied`, `always`,
  /// `whenInUse`, `unknown`, or `null` when the platform has no such
  /// concept / the channel call failed.
  ///
  /// This is the authoritative answer on iOS: `geolocator` maps
  /// `notDetermined` to `.denied` and cannot distinguish "Always" from
  /// "While Using" on its own, while the native layer can.
  static Future<String?> getNativeLocationAuthorizationStatus() async {
    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod(
        'getLocationAuthorizationStatus',
      );
      final status = result?.toString().trim();
      return (status == null || status.isEmpty) ? null : status;
    } catch (_) {
      return null;
    }
  }

  /// Open the app's notification settings screen (Android). Falls back silently if unavailable.
  static Future<void> openAppNotificationSettings() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openAppNotificationSettings');
    } catch (e) {
      // print('Failed to open notification settings: $e');
    }
  }

  /// Trigger immediate notification check in Android background service
  static Future<void> triggerNotificationCheck({
    String? messageId,
    String? translatedContent,
    String? originalContent,
    String? senderName,
    String? matchId,
    bool? shouldAlert,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      // print('🔄 [BACKGROUND] Skipping notification trigger - not Android platform');
      return;
    }
    try {
      // print('🔄 [BACKGROUND] Triggering Android background service notification check for messageId: $messageId');

      // Get the currently viewing chat ID from notification service
      final currentViewingChatId = WebNotificationService.currentViewingChatId;

      await _channel.invokeMethod('checkNotifications', {
        'messageId': messageId,
        'translatedContent': translatedContent,
        'originalContent': originalContent,
        'senderName': senderName,
        'matchId': matchId,
        'shouldAlert': shouldAlert,
        'currentViewingChatId': currentViewingChatId,
      });
      // print('🔄 [BACKGROUND] Android background service notification check triggered successfully');
    } catch (e) {
      // print('🔄 [BACKGROUND] Failed to trigger notification check: $e');
    }
  }

  // Service state
  static bool _isRunning = false;
  static bool _backgroundMatchingMode = false;
  static bool _isOnline = true;
  static Timer? _heartbeatTimer;
  static Timer? _syncTimer;
  static StreamSubscription<ConnectivityHealth>? _connectivitySubscription;
  static int? _lastSentGpsInterval;
  static bool? _lastSentSmartThrottlingEnabled;
  static Future<void>? _stopFuture;

  // Debouncing for rapid visibility/foreground changes to prevent service restart loops
  static Timer? _visibilityDebounceTimer;
  static bool? _pendingVisibilityUpdate;
  static Timer? _foregroundDebounceTimer;
  static bool? _pendingForegroundUpdate;
  static const Duration _debounceDelay = Duration(milliseconds: 500);

  // Minimal data needed for background operation
  static String? _userId;
  static String? _supabaseUrl;
  static String? _supabaseKey;
  static String? _userToken;
  static String? _refreshToken;

  /// Get initial route from notification launch
  static Future<Map<String, dynamic>?> getInitialRoute() async {
    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return null;
    }
    try {
      final result = await _mainActivityChannel.invokeMethod('getInitialRoute');
      if (result != null && result is Map) {
        return Map<String, dynamic>.from(result);
      }
    } catch (e) {
      // print('Error getting initial route: $e');
    }
    return null;
  }

  /// Initialize the background service
  static Future<void> initialize({
    String? supabaseUrl,
    String? supabaseKey,
    String? notificationTitle,
    String? notificationText,
  }) async {
    final _ = DateTime.now();
    // print('[BG] BackgroundService.initialize: start');

    // Store Supabase config for background service
    if (supabaseUrl != null) _supabaseUrl = supabaseUrl;
    if (supabaseKey != null) _supabaseKey = supabaseKey;

    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // Web and desktop platforms don't support background services
      // Use periodic task scheduling as fallback
      _initializeFallbackService();
      // print('[BG] BackgroundService.initialize: fallback service set (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
      return;
    }

    try {
      // Initialize platform-specific background service
      // print('[BG] BackgroundService.initialize: invoking native initialize (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
      await _channel.invokeMethod('initialize', {
        'serviceName': _serviceName,
        'notificationTitle': notificationTitle,
        'notificationText': notificationText,
      });
      // print('[BG] BackgroundService.initialize: native initialize returned (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');

      // Set up method call handler for communication from native side
      _channel.setMethodCallHandler(_handleMethodCall);
      // print('[BG] BackgroundService.initialize: setMethodCallHandler done (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');

      // print('[BG] Background service initialized successfully (total_elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
    } catch (_) {
      // print('[BG] Failed to initialize background service: $e\n$st (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
      _initializeFallbackService();
    }
  }

  /// Start the background service
  /// Starts the native background service.
  ///
  /// Returns a permission-issue code if the native start failed due to a missing permission.
  static Future<String?> start() async {
    final _ = DateTime.now();
    debugPrint(
      '🔍 [BG] BackgroundService.start: entered (isRunning=$_isRunning)',
    );

    if (_isRunning) return null;
    if (offlineCacheManager.shouldUseCachedData()) {
      debugPrint(
        '🔍 [BG] BackgroundService.start: skipped (offline cache mode active)',
      );
      return null;
    }

    // Load Background Matching Mode preference from local storage before starting.
    // Default true to match UserPreferencesState + DB default for new users.
    try {
      if (!kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        _backgroundMatchingMode =
            prefs.getBool('flutter.background_matching_mode') ?? true;
      }
    } catch (e) {
      // print('[BG] BackgroundService.start: failed to load backgroundMatchingMode: $e');
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;

    _userId = user.id;
    // Get the current session and refresh token if needed
    final session = Supabase.instance.client.auth.currentSession;
    // print('[BG] BackgroundService.start: session present=${session != null} (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
    if (session != null) {
      // Check if token is expired and refresh if needed
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      if (session.expiresAt != null && session.expiresAt! < now) {
        // POLICY: never auto-sign-out here. An expired token only means
        // the background service skips its network work until a refresh
        // succeeds; the user's login state is untouched. Only
        // auth.forced_sign_out_days or an explicit UI logout may sign out.
        if (kIsWeb) {
          unawaited(
            SessionService.persistSignOutReason(
              reason: 'Token expired on web (kept session)',
              source: 'backgroundService',
            ),
          );
          return null;
        }
        if (offlineCacheManager.shouldUseCachedData()) {
          // print('[BG] BackgroundService.start: session expired but device is offline, keeping cached token');
          _userToken = session.accessToken;
        } else {
          try {
            await SessionService.safeRefreshSession();
            final refreshedSession =
                Supabase.instance.client.auth.currentSession;
            _userToken = refreshedSession?.accessToken ?? session.accessToken;
            if (refreshedSession?.refreshToken != null) {
              _refreshToken = refreshedSession!.refreshToken;
            }
          } catch (e) {
            final lower = e.toString().toLowerCase();
            if (lower.contains('refresh_token_already_used') ||
                lower.contains('already used')) {
              // Native may have refreshed, use latest from currentSession
              final s = Supabase.instance.client.auth.currentSession;
              _userToken = s?.accessToken ?? session.accessToken;
              _refreshToken = s?.refreshToken ?? session.refreshToken;
            } else {
              _userToken = session.accessToken;
            }
          }
        }
      } else {
        _userToken = session.accessToken;
      }

      // Store refresh token so native background service can refresh access tokens when Flutter is background-throttled.
      // Use the latest refresh token (either from original session or refreshed session)
      _refreshToken ??= session.refreshToken;

      // Try to register session on server (best effort) — defer to avoid blocking startup
      // Always update user_session with country, even if offline or invisible
      try {
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null) {
          final platformText = kIsWeb
              ? 'web'
              : (Platform.isAndroid
                    ? 'android'
                    : (Platform.isIOS ? 'ios' : 'unknown'));
          // print('[BG] BackgroundService.start: scheduling async registerSession (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
          SessionRegistrationCoordinator.instance.schedule(
            userId: user.id,
            platform: platformText,
            source: 'background-service-start',
          );
        }
      } catch (_) {
        // print('[BG] BackgroundService.start: Background upsert_user_session scheduling failed: $e\n$st (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      }

      // print('[BG] BackgroundService.start: token present=${_userToken != null} (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
    } else {
      // print('[BG] BackgroundService.start: No session found for background service (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
    }
    // Supabase config should already be set during initialization

    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        _startFallbackService();
        // print('[BG] BackgroundService.start: started fallback service (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      } else {
        // Ensure HTTPS URL
        final httpsUrl = _supabaseUrl?.startsWith('https://') == true
            ? _supabaseUrl
            : 'https://${_supabaseUrl?.replaceFirst('http://', '')}';

        // Load Background Matching Mode preference from local storage before starting.
        // Default true to match UserPreferencesState + DB default for new users.
        try {
          if (!kIsWeb) {
            final prefs = await SharedPreferences.getInstance();
            _backgroundMatchingMode =
                prefs.getBool('flutter.background_matching_mode') ?? true;
          }
        } catch (e) {}

        // Load GPS interval and smart throttling so native service starts at correct rate
        int gpsInterval = 5;
        bool smartThrottlingEnabled = true;
        try {
          if (!kIsWeb) {
            final prefs = await SharedPreferences.getInstance();
            gpsInterval =
                prefs.getInt('flutter.gps_interval') ??
                prefs.getInt('gps_interval') ??
                5;
            smartThrottlingEnabled =
                prefs.getBool('flutter.smart_throttling_enabled') ??
                prefs.getBool('smart_throttling_enabled') ??
                true;
            if (gpsInterval <= 0) gpsInterval = 5;
            _lastSentGpsInterval = gpsInterval;
            _lastSentSmartThrottlingEnabled = smartThrottlingEnabled;
          }
        } catch (e) {}

        // Load visibility preference
        bool isVisible = true;
        try {
          final prefs = await SharedPreferences.getInstance();
          // Prioritize effective visibility (persisted by VisibilityProvider) if available
          if (prefs.containsKey('effective_visibility')) {
            isVisible = prefs.getBool('effective_visibility') ?? true;
            // print('[BG] BackgroundService.start: loaded effective visibility=$isVisible');
          } else {
            // Fallback to manual visibility or default
            isVisible = prefs.getBool('manual_visibility') ?? true;
            // print('[BG] BackgroundService.start: loaded manual visibility=$isVisible');
          }
        } catch (e) {
          // print('[BG] BackgroundService.start: failed to load visibility: $e');
        }

        // A user whose profile is not complete yet (e.g. still in the
        // onboarding wizard) has never made a visibility choice and is not
        // part of the matching pool. Never start the native service in a
        // visible state for them — otherwise the persistent "MatchMe Active"
        // foreground notification appears as soon as the app is backgrounded.
        if (isVisible) {
          try {
            final userId = Supabase.instance.client.auth.currentUser?.id;
            if (userId != null) {
              final localDb = await LocalDbService.instance;
              final localProfile = await localDb.getLocalProfile(userId);
              final raw =
                  localProfile?['isProfileComplete'] ??
                  localProfile?['is_profile_complete'];
              final profileComplete =
                  raw != null &&
                  (raw == true || raw.toString().toLowerCase() == 'true');
              if (!profileComplete) {
                debugPrint(
                  '🔍 [BG] BackgroundService.start: profile not complete, starting invisible',
                );
                isVisible = false;
              }
            }
          } catch (e) {
            // ignore — fall back to the pref-derived visibility
          }
        }

        // Check initial connectivity
        bool isOnline = true;
        try {
          final health = await getCurrentConnectivityHealth();
          isOnline = health.isOnline;
          _isOnline = isOnline;
          // print('[BG] BackgroundService.start: initial isOnline=$isOnline');

          _connectivitySubscription?.cancel();
          _connectivitySubscription = createConnectivityHealthStream().listen((
            health,
          ) {
            _handleConnectivityChange(health);
          });
        } catch (e) {
          // print('[BG] BackgroundService.start: failed to check connectivity: $e');
        }

        // Start platform-specific background service
        debugPrint(
          '🔍 [BG] BackgroundService.start: invoking native startService interval=$gpsInterval throttling=$smartThrottlingEnabled',
        );
        // Report the real UI state instead of assuming foreground: on iOS
        // `start()` can run while the app is already backgrounded (delayed
        // post-frame callback, background relaunch). A hardcoded `true` would
        // make the native service release the GPS immediately.
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        final appInForeground =
            lifecycle == null || lifecycle == AppLifecycleState.resumed;
        final _ = await _channel.invokeMethod('startService', {
          'userId': _userId,
          'supabaseUrl': httpsUrl,
          'supabaseKey': _supabaseKey,
          'userToken': _userToken,
          'refreshToken': _refreshToken,
          'backgroundMatchingMode': _backgroundMatchingMode,
          'isVisible': isVisible,
          'isOnline': isOnline,
          'gpsInterval': gpsInterval,
          'smartThrottlingEnabled': smartThrottlingEnabled,
          // Inform native code whether the UI is currently open. This allows
          // the service to avoid leaving the persistent foreground
          // notification visible after cold starts, and tells iOS whether to
          // hand GPS over to the native layer.
          'appInForeground': appInForeground,
        });

        // Immediately dump what the native service logged during startup so the
        // flutter console (which filters out non-"flutter" log tags) can show it.
        try {
          final diag = await _channel.invokeMethod('getDiagnostics');
          if (diag is List) {
            debugPrint(
              '🔍 Native background service diagnostics (after start):',
            );
            for (final line in diag) {
              debugPrint('🔍   $line');
            }
          }
        } catch (e) {
          debugPrint('🔍 [BG] getDiagnostics after start failed: $e');
        }
        // print('[BG] BackgroundService.start: native startService returned result=$_ (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      }

      _isRunning = true;
      // print('[BG] BackgroundService.start: Background service started (total_elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      return null;
    } catch (e) {
      // print('[BG] BackgroundService.start: Failed to start background service: $e\n$_ (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');

      // If the native layer rejected the call due to missing permissions, record it so the UI can prompt.
      String? issue;
      if (e is PlatformException && e.code == 'PERMISSION_DENIED') {
        issue = 'location_always';
        await setNativePermissionIssueCode(issue);
      }

      _startFallbackService();
      return issue;
    }
  }

  /// Stop the background service.
  ///
  /// This is intentionally LOCAL-ONLY. Remote session revocation/presence
  /// updates require the still-valid user JWT, so they must happen before
  /// `auth.signOut()` and are owned by the logout screen. Running them here
  /// would execute after the auth listener fires and fail as `anon`.
  static Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _stopInternal().whenComplete(() {
      if (identical(_stopFuture, tracked)) {
        _stopFuture = null;
      }
    });
    _stopFuture = tracked;
    return tracked;
  }

  static Future<void> _stopInternal() async {
    // iOS must also be told to stop: its native service persists its state
    // and auto-restarts on the next process launch. Skipping the native stop
    // (the old Android-only gate) meant a sign-out could leave the previous
    // user id/token behind and the service would keep heartbeating as that
    // user after the app was reopened or relaunched in the background.
    final shouldAttemptNativeStop =
        !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (!_isRunning && !shouldAttemptNativeStop) return;

    // Cancel any pending debounced updates
    _visibilityDebounceTimer?.cancel();
    _visibilityDebounceTimer = null;
    _pendingVisibilityUpdate = null;
    _foregroundDebounceTimer?.cancel();
    _foregroundDebounceTimer = null;
    _pendingForegroundUpdate = null;

    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        _stopFallbackService();
      } else {
        await _channel.invokeMethod('stopService');
      }

      // Clear any stored credentials and cancel subscriptions/timers
      _isRunning = false;
      _heartbeatTimer?.cancel();
      _syncTimer?.cancel();
      _connectivitySubscription?.cancel();
      _heartbeatTimer = null;
      _syncTimer = null;
      _connectivitySubscription = null;

      // Clear sensitive memory. Do this only after the native stop call so
      // the native side still has the credentials it needs during teardown.
      _userId = null;
      _userToken = null;
      _refreshToken = null;
      _supabaseUrl = null;
      _supabaseKey = null;
    } catch (e) {
      // print('Failed to stop background service: $e');
      _stopFallbackService();
    }
  }

  /// Check if background service is running
  static Future<bool> isRunning() async {
    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        return _isRunning;
      }
      final result = await _channel.invokeMethod('isRunning');
      return result ?? false;
    } catch (e) {
      return _isRunning;
    }
  }

  /// Fetch the native service's in-memory event log (last ~300 events) plus
  /// whether the service process is alive. Used for diagnosing background
  /// GPS/matching issues after the app resumes.
  static Future<List<String>> getDiagnostics() async {
    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        return const [];
      }
      final result = await _channel.invokeMethod('getDiagnostics');
      if (result is List) {
        return result.map((e) => e.toString()).toList();
      }
      return const [];
    } catch (e) {
      return ['Failed to fetch diagnostics: $e'];
    }
  }

  /// Update user visibility status in background
  /// Debounced to prevent rapid stop/start cycles when visibility toggles
  static Future<void> updateVisibility(bool isVisible) async {
    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        return;
      }

      _pendingVisibilityUpdate = isVisible;

      // Cancel existing debounce timer
      _visibilityDebounceTimer?.cancel();

      // Set up new debounce timer
      _visibilityDebounceTimer = Timer(_debounceDelay, () async {
        final updateValue = _pendingVisibilityUpdate;
        _visibilityDebounceTimer = null;
        _pendingVisibilityUpdate = null;

        if (updateValue == null) return;

        try {
          await _channel.invokeMethod('updateVisibility', {
            'isVisible': updateValue,
          });
        } catch (e) {
          // print('Native updateVisibility failed: $e');
        }
      });
    } catch (e) {
      // print('Failed to update visibility in background: $e');
    }
  }

  /// Tell the native background service whether the app UI is currently in the foreground.
  ///
  /// On Android, this lets us hide the persistent foreground-service notification while the
  /// app is open, and re-enable foreground mode when the app is backgrounded.
  /// Debounced to prevent rapid stop/start cycles during provider initialization.
  static Future<void> updateAppForeground(bool isForeground) async {
    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        return;
      }

      _pendingForegroundUpdate = isForeground;

      // Cancel existing debounce timer
      _foregroundDebounceTimer?.cancel();

      // Set up new debounce timer
      _foregroundDebounceTimer = Timer(_debounceDelay, () async {
        final updateValue = _pendingForegroundUpdate;
        _foregroundDebounceTimer = null;
        _pendingForegroundUpdate = null;

        if (updateValue == null) return;

        try {
          await _channel.invokeMethod('updateAppForeground', {
            'isForeground': updateValue,
          });
        } catch (e) {
          // print('BackgroundService.updateAppForeground failed: $e');
        }
      });
    } catch (e) {
      // print('BackgroundService.updateAppForeground failed: $e');
    }
  }

  /// Update Background Matching Mode setting
  ///
  /// When enabled, the Android service runs as a Foreground Service with a persistent notification
  /// to ensure continuous background matching and online presence.
  /// When disabled (Standard Mode), the service behaves like a standard social app (no persistent notification),
  /// which may result in process death when backgrounded.
  static Future<void> updateBackgroundMatchingMode(bool enabled) async {
    _backgroundMatchingMode = enabled;
    try {
      if (!kIsWeb &&
          !Platform.isLinux &&
          !Platform.isWindows &&
          !Platform.isMacOS) {
        await _channel.invokeMethod('updateBackgroundMatchingMode', {
          'enabled': enabled,
        });
      }
    } catch (e) {
      // print('BackgroundService.updateBackgroundMatchingMode failed: $e');
    }
  }

  /// Tell the native service that the pinned home-base changed (pin / unpin /
  /// expire) so it can re-evaluate the foreground notification and GPS
  /// polling immediately. While a pin is active the native side suppresses
  /// the persistent notification and stops accessing GPS; matching continues
  /// server-side and chat notifications still arrive via FCM.
  /// No-op off Android; failures are swallowed like the other signals.
  static Future<void> notifyPinnedStateChanged() async {
    try {
      if (kIsWeb ||
          Platform.isLinux ||
          Platform.isWindows ||
          Platform.isMacOS) {
        return;
      }
      await _channel.invokeMethod('updatePinnedState');
    } catch (_) {}
  }

  /// Update background service configuration (GPS interval, throttling)
  static Future<void> updateConfig({
    required int gpsInterval,
    required bool smartThrottlingEnabled,
    bool force = false,
  }) async {
    try {
      if (!kIsWeb &&
          !Platform.isLinux &&
          !Platform.isWindows &&
          !Platform.isMacOS) {
        if (!force &&
            _lastSentGpsInterval == gpsInterval &&
            _lastSentSmartThrottlingEnabled == smartThrottlingEnabled) {
          return;
        }
        await _channel.invokeMethod('updateConfig', {
          'gpsInterval': gpsInterval,
          'smartThrottlingEnabled': smartThrottlingEnabled,
        });
        _lastSentGpsInterval = gpsInterval;
        _lastSentSmartThrottlingEnabled = smartThrottlingEnabled;
        // print('Background service config updated: interval=$gpsInterval, throttling=$smartThrottlingEnabled');
      }
    } catch (e) {
      // print('Failed to update background service config: $e');
    }
  }

  /// Update JWT token in background service (call when token is refreshed)
  static Future<void> updateToken(String? token, {String? refreshToken}) async {
    final normalizedToken = token?.trim();
    final normalizedRefreshToken = refreshToken?.trim();
    final previousToken = _userToken;
    final previousRefreshToken = _refreshToken;
    final nextRefreshToken = normalizedToken == null && refreshToken == null
        ? null
        : (normalizedRefreshToken != null && normalizedRefreshToken.isNotEmpty
              ? normalizedRefreshToken
              : previousRefreshToken);
    if (previousToken == normalizedToken &&
        previousRefreshToken == nextRefreshToken) {
      // print('Background service token update skipped: credentials unchanged');
      return;
    }
    _userToken = normalizedToken;
    _refreshToken = nextRefreshToken;
    // Token update logging disabled
    try {
      if (!kIsWeb &&
          !Platform.isLinux &&
          !Platform.isWindows &&
          !Platform.isMacOS) {
        final _ = await _channel.invokeMethod('updateToken', {
          'token': normalizedToken,
          'refreshToken': _refreshToken,
        });
        // print('Background service token update result: $result');
      }
      // print('Updated JWT token in background service successfully');
    } catch (e) {
      // print('Failed to update token in background service: $e');
    }
  }

  /// Check if app is ignoring battery optimizations (Android only)
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod('isIgnoringBatteryOptimizations') ??
          true;
    } catch (e) {
      return true;
    }
  }

  /// Request user to ignore battery optimizations (Android only)
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      // print('Failed to request ignore battery optimizations: $e');
    }
  }

  /// Tell the native background service to start broadcasting live location
  /// updates for the given match. The service reads the persisted session key
  /// and match metadata from SharedPreferences and writes encrypted position
  /// updates to the `location_share_positions` table via the Supabase REST API.
  static Future<void> startLocationShare({
    required String matchId,
    required String otherUserId,
    required String sessionKeyBase64,
    required int updateIntervalSeconds,
    String? expiresAtIso,
  }) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('startLocationShare', {
        'matchId': matchId,
        'otherUserId': otherUserId,
        'sessionKeyBase64': sessionKeyBase64,
        'updateIntervalSeconds': updateIntervalSeconds,
        'expiresAtIso': expiresAtIso,
      });
    } catch (e) {
      // print('Failed to start location share in background: $e');
    }
  }

  /// Tell the native background service to stop broadcasting live location
  /// updates.
  static Future<void> stopLocationShare() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('stopLocationShare');
    } catch (e) {
      // print('Failed to stop location share in background: $e');
    }
  }

  /// Notify the native background service that the location share duration
  /// has changed. The background service uses [expiresAt] to compute the
  /// countdown shown in the persistent foreground notification (Android) and
  /// to decide when to stop broadcasting on native expiry timers (iOS).
  /// Passing `null` means the share has no expiry (runs until stopped
  /// manually).
  ///
  /// No-op on web: browsers do not expose native foreground notifications or
  /// background broadcast timers that can be updated from Dart.
  static Future<void> updateLocationShareDuration(DateTime? expiresAt) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('updateLocationShareDuration', {
        'expiresAtIso': expiresAt?.toUtc().toIso8601String(),
      });
    } catch (e) {
      // Swallow: failing to update the native counter does not break the
      // share itself (the peer still receives the new expiry over Realtime).
    }
  }

  /// Reset notification state for a specific chat (Android only)
  /// This allows the chat to send new notifications when new messages arrive after the user has read the previous ones
  static Future<void> resetChatNotification(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final _ = await _channel.invokeMethod('resetChatNotification', {
        'matchId': matchId,
      });
      // print('BackgroundService: resetChatNotification result: $result');
    } catch (e) {
      // print('Failed to reset chat notification: $e');
    }
  }

  /// Dismiss a notification for a specific chat (Android only)
  /// This clears a notification from the notification shade for the given chat
  static Future<void> dismissChatNotification(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // print('BackgroundService: Calling dismissChatNotification for matchId: $matchId');
      final _ = await _channel.invokeMethod('dismissChatNotification', {
        'matchId': matchId,
      });
      // print('BackgroundService: dismissChatNotification result: $result');
    } catch (e) {
      // print('Failed to dismiss chat notification: $e');
    }
  }

  /// Cancel server-posted (FCM SDK) tray cards by their notification tag
  /// (Android only). Used by the expiry paths to drop the server card for an
  /// event that a local card (or a consumed tap) already represents, so the
  /// shade keeps exactly one entry per event.
  static Future<void> cancelServerCard(String tag) async {
    if (kIsWeb || !Platform.isAndroid) return;
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return;
    try {
      await _channel.invokeMethod('cancelServerCard', {'tag': trimmed});
    } catch (e) {
      // print('Failed to cancel server card: $e');
    }
  }

  /// True when the match was already alerted on this device (native card,
  /// server card or WorkManager fallback). Lets the foreground FCM handler
  /// skip showing a second card when the native Realtime/poll path won the
  /// race for the same match.
  static Future<bool> wasMatchNotified(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    final trimmed = matchId.trim();
    if (trimmed.isEmpty) return true;
    try {
      final result = await _channel.invokeMethod('wasMatchNotified', {
        'matchId': trimmed,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Record that the match was alerted (Android only): the native service and
  /// the WorkManager fallback consult this before posting their own card, so
  /// the foreground local card stays the single notification for the match.
  static Future<void> markMatchNotified(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    final trimmed = matchId.trim();
    if (trimmed.isEmpty) return;
    try {
      await _channel.invokeMethod('markMatchNotified', {'matchId': trimmed});
    } catch (e) {
      // print('Failed to mark match notified: $e');
    }
  }

  /// Notify background service that user is viewing a specific chat (Android only)
  /// This prevents notifications for that chat while it's being viewed.
  /// Also mirrors to SharedPreferences so the FCM background isolate and
  /// post-reboot native service can suppress without UI state.
  static Future<void> setViewingChat(String matchId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('flutter.viewing_chat_id', matchId);
      await prefs.setString('viewing_chat_id', matchId);
    } catch (_) {}
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // print('BackgroundService: Calling setViewingChat for matchId: $matchId');
      final _ = await _channel.invokeMethod('setViewingChat', {
        'matchId': matchId,
      });
      // print('BackgroundService: setViewingChat result: $result');
    } catch (e) {
      // print('Failed to set viewing chat: $e');
    }
  }

  /// Notify background service that user is no longer viewing any chat (Android only)
  static Future<void> clearViewingChat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('flutter.viewing_chat_id');
      await prefs.remove('viewing_chat_id');
    } catch (_) {}
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // print('BackgroundService: Calling clearViewingChat');
      final _ = await _channel.invokeMethod('clearViewingChat');
      // print('BackgroundService: clearViewingChat result: $result');
    } catch (e) {
      // print('Failed to clear viewing chat: $e');
    }
  }

  /// Handle method calls from native background service
  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onLocationUpdate':
        await _handleBackgroundLocationUpdate(call.arguments);
        break;
      case 'onConnectivityChanged':
        await _handleBackgroundConnectivityChange(call.arguments);
        break;
      case 'onNewMessage':
        await _handleBackgroundNewMessage(call.arguments);
        break;
      case 'onNewMatch':
        await _handleBackgroundNewMatch(call.arguments);
        break;
      default:
      // print('Unknown method call from background service: ${call.method}');
    }
  }

  /// Initialize fallback service for platforms that don't support background services
  static void _initializeFallbackService() {
    // print('Using fallback background service (limited functionality)');
  }

  /// Start fallback background service
  static void _startFallbackService() {
    _isRunning = true;

    // Start heartbeat
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _backgroundHeartbeat();
    });

    // Start periodic sync
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      await _backgroundSync();
    });

    // Monitor connectivity
    _connectivitySubscription?.cancel();
    _connectivitySubscription = createConnectivityHealthStream().listen((
      health,
    ) {
      _handleConnectivityChange(health);
    });

    // print('Fallback background service started');
  }

  /// Stop fallback background service
  static void _stopFallbackService() {
    _isRunning = false;
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _connectivitySubscription?.cancel();
    _heartbeatTimer = null;
    _syncTimer = null;
    _connectivitySubscription = null;
    // print('Fallback background service stopped');
  }

  /// Background heartbeat to keep user online
  static Future<void> _backgroundHeartbeat() async {
    if (_userId == null) return;
    if (!_isOnline) return;

    await UserActivityService.instance.pingIfDue(
      _userId!,
      source: 'bg-heartbeat',
    );
  }

  /// Background sync operations
  static Future<void> _backgroundSync() async {
    if (_userId == null) return;
    if (!_isOnline) return;

    try {
      // Sync matches
      await Supabase.instance.client
          .from('matches')
          .select('id')
          .or('user1_id.eq.$_userId,user2_id.eq.$_userId');
      // print('[BG] _backgroundSync: matches sync elapsed=${DateTime.now().difference(matchesStart).inMilliseconds}ms');

      // Sync recent chats
      await Supabase.instance.client
          .from('chat_messages')
          .select('id')
          .eq('sender_id', _userId!)
          .order('created_at', ascending: false)
          .limit(1);
      // print('[BG] _backgroundSync: recent chats sync elapsed=${DateTime.now().difference(chatsStart).inMilliseconds}ms');

      // print('[BG] _backgroundSync: total elapsed=${DateTime.now().difference(syncStart).inMilliseconds}ms');

      // Note: Match engine is now handled server-side autonomously
      // No client-side triggering needed - matches are created by Supabase functions
    } catch (e) {
      // print('Background sync failed: $e');
    }
  }

  /// Handle connectivity changes
  static void _handleConnectivityChange(ConnectivityHealth health) {
    final isOnline = health.isOnline;
    if (_isOnline == isOnline) {
      return;
    }
    _isOnline = isOnline;
    // print('Background connectivity changed: ${isOnline ? 'online' : 'offline'}');

    // Background service will handle reconnection automatically
    // Update native service about connectivity state
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _channel
          .invokeMethod('setConnectivity', {'isOnline': isOnline})
          .catchError((e) {
            // print('Failed to update native connectivity: $e');
          });
    }

    final userId = _userId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      if (!isOnline) {
        // Do NOT call set_user_offline on transient offline – 61s window + WorkManager heartbeat
        // will expire naturally. Immediate offline breaks bg=ON contract (10:50->16:30 bug).
      } else {
        UserActivityService.instance.pingIfDue(
          userId,
          force: true,
          source: 'bg-connectivity',
        );
      }
    }
  }

  /// Handle location updates from background service
  static Future<void> _handleBackgroundLocationUpdate(
    Map<String, dynamic> data,
  ) async {
    final userId = data['userId'] as String?;
    final latitude = data['latitude'] as double?;
    final longitude = data['longitude'] as double?;

    if (userId == null || latitude == null || longitude == null) return;
    if (shouldSkipSupabaseCalls()) return;

    // Pinned home-base: never forward native GPS fixes while a pin is active.
    // (The server RPC would ignore them anyway; this avoids needless writes.)
    if (await PinnedLocationGate.isActive()) {
      debugPrint(
        '⏸️ [BG] Pinned location active — GPS update dropped, GPS not accessed for upload',
      );
      return;
    }

    try {
      // Check user visibility in DB before updating location - do not transmit location for invisible users
      try {
        final resp = await Supabase.instance.client
            .from('users')
            .select('user_visibility_setting, system_visibility_status')
            .eq('id', userId)
            .maybeSingle();
        final userVisibilitySetting =
            resp != null && resp['user_visibility_setting'] == true;
        final systemVisibility = resp != null
            ? (resp['system_visibility_status'] as String?)
            : null;
        if (!userVisibilitySetting || systemVisibility == 'invisible') {
          // print('BackgroundService: user is not visible (setting/system) - ignoring background location update for $userId');
          return;
        }
      } catch (e) {
        // If visibility check fails, log and proceed conservatively (skip update)
        // print('BackgroundService: Could not verify user visibility - skipping location update: $e');
        return;
      }

      // Update location in Supabase
      await Supabase.instance.client.from('user_locations').upsert({
        'user_id': userId,
        'latitude': latitude,
        'longitude': longitude,
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Note: Match engine is now handled server-side autonomously
      // Location updates will trigger server-side matching via database triggers or scheduled jobs
    } catch (e) {
      // print('Failed to handle background location update: $e');
    }
  }

  /// Handle connectivity changes from background service
  static Future<void> _handleBackgroundConnectivityChange(
    Map<String, dynamic> data,
  ) async {
    final isOnline = data['isOnline'] as bool? ?? false;
    // print('Background connectivity changed: ${isOnline ? 'online' : 'offline'}');

    if (isOnline && _userId != null) {
      // The native layer only knows about the OS transport, so it is a reason to
      // probe Supabase now — never a reason to declare the app online. A device
      // with working internet and an unreachable Supabase is offline here.
      try {
        final health = await getCurrentConnectivityHealth();
        if (health.status != ConnectivityHealthStatus.online) {
          debugPrint(
            '💡 [BG] Native reported online but Supabase is ${health.status.name} - staying offline',
          );
          return;
        }
      } catch (e) {
        // print('BackgroundService: immediate connectivity check failed: $e');
      }

      await UserActivityService.instance.pingIfDue(
        _userId!,
        force: true,
        source: 'bg-native-online',
      );
      // Sync any pending data when coming back online
      await _backgroundSync();
    } else if (!isOnline && _userId != null) {
      // A native "offline" is likewise only a hint: let the Supabase probe and
      // OfflineCacheManager's grace period decide (non-forced, so a single
      // native hiccup cannot flap availability).
      offlineCacheManager.setSupabaseAvailability(false);

      try {
        await Supabase.instance.client.rpc(
          'set_user_offline',
          params: {'p_user_id': _userId},
        );
      } catch (e) {
        // print('BackgroundService: set_user_offline RPC failed: $e');
      }
    }
  }

  /// Handle new messages from background service
  static Future<void> _handleBackgroundNewMessage(
    Map<String, dynamic> data,
  ) async {
    final messageId = data['messageId'] as String?;
    final matchId = data['matchId'] as String?;
    final senderId = data['senderId'] as String?;
    final content = data['content'] as String?;

    if (messageId == null ||
        matchId == null ||
        senderId == null ||
        content == null) {
      return;
    }

    try {
      // Store message locally if LocalDbService is available
      final localDb = await LocalDbService.instance;
      // Note: Background service doesn't have Supabase access, so we skip currentUserId
      // The RPC call will be made when the app comes to foreground and syncs
      // Don't store raw content in legacy columns — the sync process will fetch
      // the encrypted content when the app comes to foreground.
      await localDb.addMessages(matchId, [
        {
          'id': messageId,
          'match_id': matchId,
          'sender_id': senderId,
          'created_at': DateTime.now().toIso8601String(),
        },
      ]);

      // TODO: Show notification if app is not in foreground
      // print('New message received in background: $messageId');
    } catch (e) {
      // print('Failed to handle background message: $e');
    }
  }

  /// Handle new matches from background service
  static Future<void> _handleBackgroundNewMatch(
    Map<String, dynamic> data,
  ) async {
    final matchId = data['matchId'] as String?;
    final user1Id = data['user1Id'] as String?;
    final user2Id = data['user2Id'] as String?;

    if (matchId == null || user1Id == null || user2Id == null) return;

    try {
      // Determine current user from the match data
      String? currentUserId;
      try {
        currentUserId = Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {}
      if (currentUserId == null ||
          (currentUserId != user1Id && currentUserId != user2Id)) {
        // Can't determine which user this match is for; skip local save
        // (sync will pick it up when the app opens)
        return;
      }

      // Store match locally if LocalDbService is available
      final localDb = await LocalDbService.instance;
      await localDb.saveMatches(currentUserId, [
        {
          'match_id': matchId,
          'user1_id': user1Id,
          'user2_id': user2Id,
          'created_at': DateTime.now().toIso8601String(),
        },
      ]);

      // TODO: Show notification
      // print('New match received in background: $matchId');
    } catch (e) {
      // print('Failed to handle background match: $e');
    }
  }
}
