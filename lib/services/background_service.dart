// lib/services/background_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background service that maintains app functionality when UI is closed
class BackgroundService {
  static const MethodChannel _channel = MethodChannel('matchme/background_service');
  static const MethodChannel _mainActivityChannel = MethodChannel('matchme/main_activity');
  static const String _serviceName = 'MatchMeBackgroundService';

  /// Store localized permission texts for native (post-reboot) notifications.
  static Future<void> setNativePermissionStrings(Map<String, String> strings) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setPermissionStrings', strings);
    } catch (e) {
      debugPrint('Failed to set native permission strings: $e');
    }
  }

  /// Returns the last permission issue reported by the native background service (if any),
  /// and clears it so it won't show repeatedly.
  static Future<String?> consumeNativePermissionIssueCode() async {
    if (kIsWeb || !Platform.isAndroid) return null;
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
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setPermissionIssue', {'code': code});
    } catch (e) {
      debugPrint('Failed to set native permission issue code: $e');
    }
  }

  /// Open the app's notification settings screen (Android). Falls back silently if unavailable.
  static Future<void> openAppNotificationSettings() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openAppNotificationSettings');
    } catch (e) {
      debugPrint('Failed to open notification settings: $e');
    }
  }

  /// Trigger immediate notification check in Android background service
  static Future<void> triggerNotificationCheck({
    String? messageId,
    String? translatedContent,
    String? originalContent,
    String? senderName,
    String? matchId,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      debugPrint('🔄 [BACKGROUND] Skipping notification trigger - not Android platform');
      return;
    }
    try {
      debugPrint('🔄 [BACKGROUND] Triggering Android background service notification check for messageId: $messageId');
      
      // Get the currently viewing chat ID from notification service
      final currentViewingChatId = WebNotificationService.currentViewingChatId;
      
      await _channel.invokeMethod('checkNotifications', {
        'messageId': messageId,
        'translatedContent': translatedContent,
        'originalContent': originalContent,
        'senderName': senderName,
        'matchId': matchId,
        'currentViewingChatId': currentViewingChatId,
      });
      debugPrint('🔄 [BACKGROUND] Android background service notification check triggered successfully');
    } catch (e) {
      debugPrint('🔄 [BACKGROUND] Failed to trigger notification check: $e');
    }
  }

  // Service state
  static bool _isRunning = false;
  static bool _highAccuracyMode = false;
  static bool _isOnline = true;
  static Timer? _heartbeatTimer;
  static Timer? _syncTimer;
  static StreamSubscription<ConnectivityHealth>? _connectivitySubscription;
  static int? _lastSentGpsInterval;
  static bool? _lastSentSmartThrottlingEnabled;


  // Minimal data needed for background operation
  static String? _userId;
  static String? _supabaseUrl;
  static String? _supabaseKey;
  static String? _userToken;
  static String? _refreshToken;

  /// Get initial route from notification launch
  static Future<Map<String, dynamic>?> getInitialRoute() async {
    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) return null;
    try {
      final result = await _mainActivityChannel.invokeMethod('getInitialRoute');
      if (result != null && result is Map) {
        return Map<String, dynamic>.from(result);
      }
    } catch (e) {
      debugPrint('Error getting initial route: $e');
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
    final initializeStart = DateTime.now();
    debugPrint('[BG] BackgroundService.initialize: start');

    // Store Supabase config for background service
    if (supabaseUrl != null) _supabaseUrl = supabaseUrl;
    if (supabaseKey != null) _supabaseKey = supabaseKey;

    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // Web and desktop platforms don't support background services
      // Use periodic task scheduling as fallback
      _initializeFallbackService();
      debugPrint('[BG] BackgroundService.initialize: fallback service set (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
      return;
    }

    try {
      // Initialize platform-specific background service
      debugPrint('[BG] BackgroundService.initialize: invoking native initialize (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
      await _channel.invokeMethod('initialize', {
        'serviceName': _serviceName,
        'notificationTitle': notificationTitle,
        'notificationText': notificationText,
      });
      debugPrint('[BG] BackgroundService.initialize: native initialize returned (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');

      // Set up method call handler for communication from native side
      _channel.setMethodCallHandler(_handleMethodCall);
      debugPrint('[BG] BackgroundService.initialize: setMethodCallHandler done (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');

      debugPrint('[BG] Background service initialized successfully (total_elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
    } catch (e, st) {
      debugPrint('[BG] Failed to initialize background service: $e\n$st (elapsed=${DateTime.now().difference(initializeStart).inMilliseconds}ms)');
      _initializeFallbackService();
    }
  }

  /// Start the background service
  /// Starts the native background service.
  ///
  /// Returns a permission-issue code if the native start failed due to a missing permission.
  static Future<String?> start() async {
    final startStart = DateTime.now();
    debugPrint('[BG] BackgroundService.start: start');

    if (_isRunning) return null;

    // Load High Accuracy Mode preference from local storage before starting
    try {
      if (!kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        _highAccuracyMode = prefs.getBool('flutter.high_accuracy_mode') ?? false;
        debugPrint('[BG] BackgroundService.start: loaded highAccuracyMode=$_highAccuracyMode');
      }
    } catch (e) {
      debugPrint('[BG] BackgroundService.start: failed to load highAccuracyMode: $e');
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;

    _userId = user.id;
    // Get the current session and refresh token if needed
    final session = Supabase.instance.client.auth.currentSession;
    debugPrint('[BG] BackgroundService.start: session present=${session != null} (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
    if (session != null) {
      // Check if token is expired and refresh if needed
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      if (session.expiresAt != null && session.expiresAt! < now) {
        if (kIsWeb) {
          try {
            await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
          } catch (_) {}
          return null;
        }
        try {
          debugPrint('[BG] BackgroundService.start: refreshing session (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
          await Supabase.instance.client.auth.refreshSession();
          final refreshedSession = Supabase.instance.client.auth.currentSession;
          _userToken = refreshedSession?.accessToken;
          // Update refresh token to the new one from the refreshed session
          if (refreshedSession?.refreshToken != null) {
            _refreshToken = refreshedSession!.refreshToken;
          }
          debugPrint('[BG] BackgroundService.start: refreshed token=${_userToken != null} (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
        } catch (e) {
          debugPrint('[BG] BackgroundService.start: Failed to refresh token: $e (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
          _userToken = session.accessToken; // Use existing token as fallback
        }
      } else {
        _userToken = session.accessToken;
      }

      // Store refresh token so native background service can refresh access tokens when Flutter is background-throttled.
      // Use the latest refresh token (either from original session or refreshed session)
      _refreshToken ??= session.refreshToken;

      // Try to register session on server (best effort) — defer to avoid blocking startup
      try {
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null) {
          final platformText = kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'unknown'));
          debugPrint('[BG] BackgroundService.start: scheduling async registerSession (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
          unawaited(() async {
            debugPrint('[BG] BackgroundService.start: async registerSession start');
            try {
              await SessionService.registerSession(user.id, platform: platformText);
              debugPrint('[BG] BackgroundService.start: async registerSession done');
            } catch (e, st) {
              debugPrint('[BG] BackgroundService.start: async registerSession failed: $e\n$st');
            }
          }());
        }
      } catch (e, st) {
        debugPrint('[BG] BackgroundService.start: Background upsert_user_session scheduling failed: $e\n$st (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      }

      debugPrint('[BG] BackgroundService.start: token present=${_userToken != null} (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
    } else {
      debugPrint('[BG] BackgroundService.start: No session found for background service (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
    }
    // Supabase config should already be set during initialization

    try {
      if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        _startFallbackService();
        debugPrint('[BG] BackgroundService.start: started fallback service (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      } else {
        // Ensure HTTPS URL
        final httpsUrl = _supabaseUrl?.startsWith('https://') == true ? _supabaseUrl : 'https://${_supabaseUrl?.replaceFirst('http://', '')}';

        // Load High Accuracy Mode preference from local storage before starting
        try {
          if (!kIsWeb) {
            final prefs = await SharedPreferences.getInstance();
            _highAccuracyMode = prefs.getBool('flutter.high_accuracy_mode') ?? false;
            debugPrint('[BG] BackgroundService.start: loaded highAccuracyMode=$_highAccuracyMode');
          }
        } catch (e) {
          debugPrint('[BG] BackgroundService.start: failed to load highAccuracyMode: $e');
        }

        // Load visibility preference
        bool isVisible = true;
        try {
          final prefs = await SharedPreferences.getInstance();
          // Prioritize effective visibility (persisted by VisibilityProvider) if available
          if (prefs.containsKey('effective_visibility')) {
            isVisible = prefs.getBool('effective_visibility') ?? true;
            debugPrint('[BG] BackgroundService.start: loaded effective visibility=$isVisible');
          } else {
            // Fallback to manual visibility or default
            isVisible = prefs.getBool('manual_visibility') ?? true;
            debugPrint('[BG] BackgroundService.start: loaded manual visibility=$isVisible');
          }
        } catch (e) {
          debugPrint('[BG] BackgroundService.start: failed to load visibility: $e');
        }

        // Check initial connectivity
        bool isOnline = true;
        try {
          final health = await getCurrentConnectivityHealth();
          isOnline = health.isOnline;
          _isOnline = isOnline;
          debugPrint('[BG] BackgroundService.start: initial isOnline=$isOnline');
          
          _connectivitySubscription?.cancel();
          _connectivitySubscription = createConnectivityHealthStream().listen((health) {
            _handleConnectivityChange(health);
          });
        } catch (e) {
          debugPrint('[BG] BackgroundService.start: failed to check connectivity: $e');
        }

        // Start platform-specific background service
        debugPrint('[BG] BackgroundService.start: invoking native startService (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
        final result = await _channel.invokeMethod('startService', {
          'userId': _userId,
          'supabaseUrl': httpsUrl,
          'supabaseKey': _supabaseKey,
          'userToken': _userToken,
          'refreshToken': _refreshToken,
          'highAccuracyMode': _highAccuracyMode,
          'isVisible': isVisible,
          'isOnline': isOnline,
          // Inform native code that the UI is currently open. This allows the service to
          // avoid leaving the persistent foreground notification visible after cold starts.
          'appInForeground': true,
        });
        debugPrint('[BG] BackgroundService.start: native startService returned result=$result (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      }

      _isRunning = true;
      debugPrint('[BG] BackgroundService.start: Background service started (total_elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');
      return null;
    } catch (e, st) {
      debugPrint('[BG] BackgroundService.start: Failed to start background service: $e\n$st (elapsed=${DateTime.now().difference(startStart).inMilliseconds}ms)');

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

  /// Stop the background service
  static Future<void> stop() async {
    final shouldAttemptNativeStop = !kIsWeb && Platform.isAndroid;
    if (!_isRunning && !shouldAttemptNativeStop) return;

    // Use RPC to mark the user offline; do NOT modify the user's manual visibility setting here
    try {
      final targetUserId = _userId ?? Supabase.instance.client.auth.currentUser?.id;
      if (targetUserId != null) {
        debugPrint('BackgroundService.stop: marking user offline via RPC for $targetUserId');
      }
    } catch (e) {
      debugPrint('BackgroundService.stop: failed to mark offline (RPC may handle this): $e');
    }

    // Also try to mark the user's presence offline immediately via RPC
    try {
      final targetUserId = _userId ?? Supabase.instance.client.auth.currentUser?.id;
      if (targetUserId != null) {
        await Supabase.instance.client.rpc('set_user_offline', params: {'p_user_id': targetUserId});
        debugPrint('BackgroundService.stop: set_user_offline RPC called for $targetUserId');
      }
    } catch (e) {
      debugPrint('BackgroundService.stop: set_user_offline RPC failed: $e');
    }

    try {
      if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
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


      // Clear sensitive memory
      _userId = null;
      _userToken = null;

      debugPrint('Background service stopped and cleaned up');
    } catch (e) {
      debugPrint('Failed to stop background service: $e');
      _stopFallbackService();
    }
  }

  /// Check if background service is running
  static Future<bool> isRunning() async {
    try {
      if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        return _isRunning;
      }
      final result = await _channel.invokeMethod('isRunning');
      return result ?? false;
    } catch (e) {
      return _isRunning;
    }
  }

  /// Update user visibility status in background
  static Future<void> updateVisibility(bool isVisible) async {
    try {
      if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        return;
      }
      try {
        await _channel.invokeMethod('updateVisibility', {'isVisible': isVisible});
      } catch (e) {
        debugPrint('Native updateVisibility failed: $e');
      }
    } catch (e) {
      debugPrint('Failed to update visibility in background: $e');
    }
  }

  /// Tell the native background service whether the app UI is currently in the foreground.
  ///
  /// On Android, this lets us hide the persistent foreground-service notification while the
  /// app is open, and re-enable foreground mode when the app is backgrounded.
  static Future<void> updateAppForeground(bool isForeground) async {
    try {
      if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        return;
      }
      await _channel.invokeMethod('updateAppForeground', {'isForeground': isForeground});
    } catch (e) {
      debugPrint('BackgroundService.updateAppForeground failed: $e');
    }
  }

  /// Update High Accuracy Mode setting
  ///
  /// When enabled, the Android service runs as a Foreground Service with a persistent notification
  /// to ensure continuous execution.
  /// When disabled (Standard Mode), the service behaves like a standard social app (no persistent notification),
  /// which may result in process death when backgrounded.
  static Future<void> updateHighAccuracyMode(bool enabled) async {
    _highAccuracyMode = enabled;
    try {
      if (!kIsWeb && !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
        await _channel.invokeMethod('updateHighAccuracyMode', {
          'enabled': enabled,
        });
        
        // If mode changed to disabled and app is in background, native side should stop service
        // If mode changed to enabled and app is in background, native side should start service
      }
    } catch (e) {
      debugPrint('BackgroundService.updateHighAccuracyMode failed: $e');
    }
  }

  /// Update background service configuration (GPS interval, throttling)
  static Future<void> updateConfig({required int gpsInterval, required bool smartThrottlingEnabled}) async {
    try {
      if (!kIsWeb && !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
        if (_lastSentGpsInterval == gpsInterval &&
            _lastSentSmartThrottlingEnabled == smartThrottlingEnabled) {
          return;
        }
        await _channel.invokeMethod('updateConfig', {
          'gpsInterval': gpsInterval,
          'smartThrottlingEnabled': smartThrottlingEnabled,
        });
        _lastSentGpsInterval = gpsInterval;
        _lastSentSmartThrottlingEnabled = smartThrottlingEnabled;
        debugPrint('Background service config updated: interval=$gpsInterval, throttling=$smartThrottlingEnabled');
      }
    } catch (e) {
      debugPrint('Failed to update background service config: $e');
    }
  }

  /// Update JWT token in background service (call when token is refreshed)
  static Future<void> updateToken(String? token, {String? refreshToken}) async {
    _userToken = token;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      _refreshToken = refreshToken;
    }
    debugPrint(
      'Background service token update: token present=${token != null}; refreshToken present=${_refreshToken != null}',
    );
    try {
      if (!kIsWeb && !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
        final result = await _channel.invokeMethod('updateToken', {
          'token': token,
          'refreshToken': _refreshToken,
        });
        debugPrint('Background service token update result: $result');
      }
      debugPrint('Updated JWT token in background service successfully');
    } catch (e) {
      debugPrint('Failed to update token in background service: $e');
    }
  }

  /// Check if app is ignoring battery optimizations (Android only)
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod('isIgnoringBatteryOptimizations') ?? true;
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
      debugPrint('Failed to request ignore battery optimizations: $e');
    }
  }

  /// Reset notification state for a specific chat (Android only)
  /// This allows the chat to send new notifications when new messages arrive after the user has read the previous ones
  static Future<void> resetChatNotification(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final result = await _channel.invokeMethod('resetChatNotification', {'matchId': matchId});
      debugPrint('BackgroundService: resetChatNotification result: $result');
    } catch (e) {
      debugPrint('Failed to reset chat notification: $e');
    }
  }

  /// Dismiss a notification for a specific chat (Android only)
  /// This clears a notification from the notification shade for the given chat
  static Future<void> dismissChatNotification(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      debugPrint('BackgroundService: Calling dismissChatNotification for matchId: $matchId');
      final result = await _channel.invokeMethod('dismissChatNotification', {'matchId': matchId});
      debugPrint('BackgroundService: dismissChatNotification result: $result');
    } catch (e) {
      debugPrint('Failed to dismiss chat notification: $e');
    }
  }

  /// Notify background service that user is viewing a specific chat (Android only)
  /// This prevents notifications for that chat while it's being viewed
  static Future<void> setViewingChat(String matchId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      debugPrint('BackgroundService: Calling setViewingChat for matchId: $matchId');
      final result = await _channel.invokeMethod('setViewingChat', {'matchId': matchId});
      debugPrint('BackgroundService: setViewingChat result: $result');
    } catch (e) {
      debugPrint('Failed to set viewing chat: $e');
    }
  }

  /// Notify background service that user is no longer viewing any chat (Android only)
  static Future<void> clearViewingChat() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      debugPrint('BackgroundService: Calling clearViewingChat');
      final result = await _channel.invokeMethod('clearViewingChat');
      debugPrint('BackgroundService: clearViewingChat result: $result');
    } catch (e) {
      debugPrint('Failed to clear viewing chat: $e');
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
        debugPrint('Unknown method call from background service: ${call.method}');
    }
  }

  /// Initialize fallback service for platforms that don't support background services
  static void _initializeFallbackService() {
    debugPrint('Using fallback background service (limited functionality)');
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
    _connectivitySubscription = createConnectivityHealthStream().listen((health) {
      _handleConnectivityChange(health);
    });

    debugPrint('Fallback background service started');
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
    debugPrint('Fallback background service stopped');
  }

  /// Background heartbeat to keep user online
  static Future<void> _backgroundHeartbeat() async {
    if (_userId == null) return;
    if (!_isOnline) return;

    try {
      final hbStart = DateTime.now();
      await Supabase.instance.client.rpc('update_user_activity', params: <String, dynamic>{'p_user_id': _userId});
      debugPrint('[BG] _backgroundHeartbeat: update_user_activity completed (elapsed=${DateTime.now().difference(hbStart).inMilliseconds}ms)');
    } catch (e) {
      debugPrint('Background heartbeat failed: $e');
    }
  }

  /// Background sync operations
  static Future<void> _backgroundSync() async {
    if (_userId == null) return;
    if (!_isOnline) return;

    try {
      final syncStart = DateTime.now();

      // Sync matches
      final matchesStart = DateTime.now();
      await Supabase.instance.client.from('matches').select('id').or('user1_id.eq.$_userId,user2_id.eq.$_userId');
      debugPrint('[BG] _backgroundSync: matches sync elapsed=${DateTime.now().difference(matchesStart).inMilliseconds}ms');

      // Sync recent chats
      final chatsStart = DateTime.now();
      await Supabase.instance.client.from('chat_messages').select('id').eq('sender_id', _userId!).order('created_at', ascending: false).limit(1);
      debugPrint('[BG] _backgroundSync: recent chats sync elapsed=${DateTime.now().difference(chatsStart).inMilliseconds}ms');

      debugPrint('[BG] _backgroundSync: total elapsed=${DateTime.now().difference(syncStart).inMilliseconds}ms');

      // Note: Match engine is now handled server-side autonomously
      // No client-side triggering needed - matches are created by Supabase functions
    } catch (e) {
      debugPrint('Background sync failed: $e');
    }
  }

  /// Handle connectivity changes
  static void _handleConnectivityChange(ConnectivityHealth health) {
    final isOnline = health.isOnline;
    if (_isOnline == isOnline) {
      return;
    }
    _isOnline = isOnline;
    debugPrint('Background connectivity changed: ${isOnline ? 'online' : 'offline'}');
    
    // Background service will handle reconnection automatically
    // Update native service about connectivity state
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _channel.invokeMethod('setConnectivity', {'isOnline': isOnline}).catchError((e) {
        debugPrint('Failed to update native connectivity: $e');
      });
    }

    final userId = _userId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      if (!isOnline) {
        Supabase.instance.client
            .rpc('set_user_offline', params: {'p_user_id': userId})
            .catchError((e) {
          debugPrint('BackgroundService: set_user_offline RPC failed: $e');
          return null;
        });
      } else {
        Supabase.instance.client
            .rpc('update_user_activity', params: {'p_user_id': userId})
            .catchError((e) {
          debugPrint('BackgroundService: update_user_activity RPC failed: $e');
          return null;
        });
      }
    }
  }

  /// Handle location updates from background service
  static Future<void> _handleBackgroundLocationUpdate(Map<String, dynamic> data) async {
    final userId = data['userId'] as String?;
    final latitude = data['latitude'] as double?;
    final longitude = data['longitude'] as double?;

    if (userId == null || latitude == null || longitude == null) return;

    try {
      // Check user visibility in DB before updating location - do not transmit location for invisible users
      try {
        final resp = await Supabase.instance.client.from('users').select('user_visibility_setting, system_visibility_status').eq('id', userId).maybeSingle();
        final userVisibilitySetting = resp != null && resp['user_visibility_setting'] == true;
        final systemVisibility = resp != null ? (resp['system_visibility_status'] as String?) : null;
        if (!userVisibilitySetting || systemVisibility == 'invisible') {
          debugPrint('BackgroundService: user is not visible (setting/system) - ignoring background location update for $userId');
          return;
        }
      } catch (e) {
        // If visibility check fails, log and proceed conservatively (skip update)
        debugPrint('BackgroundService: Could not verify user visibility - skipping location update: $e');
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
      debugPrint('Failed to handle background location update: $e');
    }
  }

  /// Handle connectivity changes from background service
  static Future<void> _handleBackgroundConnectivityChange(Map<String, dynamic> data) async {
    final isOnline = data['isOnline'] as bool? ?? false;
    debugPrint('Background connectivity changed: ${isOnline ? 'online' : 'offline'}');

    if (isOnline && _userId != null) {
      try {
        await Supabase.instance.client.rpc('update_user_activity', params: {'p_user_id': _userId});
      } catch (e) {
        debugPrint('BackgroundService: update_user_activity RPC failed: $e');
      }
      // Sync any pending data when coming back online
      await _backgroundSync();
    } else if (!isOnline && _userId != null) {
      try {
        await Supabase.instance.client.rpc('set_user_offline', params: {'p_user_id': _userId});
      } catch (e) {
        debugPrint('BackgroundService: set_user_offline RPC failed: $e');
      }
    }
  }

  /// Handle new messages from background service
  static Future<void> _handleBackgroundNewMessage(Map<String, dynamic> data) async {
    final messageId = data['messageId'] as String?;
    final matchId = data['matchId'] as String?;
    final senderId = data['senderId'] as String?;
    final content = data['content'] as String?;

    if (messageId == null || matchId == null || senderId == null || content == null) return;

    try {
      // Store message locally if LocalDbService is available
      final localDb = await LocalDbService.instance;
      // Note: Background service doesn't have Supabase access, so we skip currentUserId
      // The RPC call will be made when the app comes to foreground and syncs
      await localDb.addMessages(matchId, [{
        'id': messageId,
        'match_id': matchId,
        'sender_id': senderId,
        'content_original': content,
        'created_at': DateTime.now().toIso8601String(),
      }]);

      // TODO: Show notification if app is not in foreground
      debugPrint('New message received in background: $messageId');
    } catch (e) {
      debugPrint('Failed to handle background message: $e');
    }
  }

  /// Handle new matches from background service
  static Future<void> _handleBackgroundNewMatch(Map<String, dynamic> data) async {
    final matchId = data['matchId'] as String?;
    final user1Id = data['user1Id'] as String?;
    final user2Id = data['user2Id'] as String?;

    if (matchId == null || user1Id == null || user2Id == null) return;

    try {
      // Store match locally if LocalDbService is available
      final localDb = await LocalDbService.instance;
      await localDb.saveMatches([{
        'match_id': matchId,
        'user1_id': user1Id,
        'user2_id': user2Id,
        'created_at': DateTime.now().toIso8601String(),
      }]);

      // TODO: Show notification
      debugPrint('New match received in background: $matchId');
    } catch (e) {
      debugPrint('Failed to handle background match: $e');
    }
  }

}
