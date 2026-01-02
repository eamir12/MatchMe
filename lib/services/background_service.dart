// lib/services/background_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/session_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Background service that maintains app functionality when UI is closed
class BackgroundService {
  static const MethodChannel _channel = MethodChannel('matchme/background_service');
  static const String _serviceName = 'MatchMeBackgroundService';

  // Service state
  static bool _isRunning = false;
  static Timer? _heartbeatTimer;
  static Timer? _syncTimer;
  static StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  static StreamSubscription? _realtimeSubscription;

  // Minimal data needed for background operation
  static String? _userId;
  static String? _supabaseUrl;
  static String? _supabaseKey;
  static String? _userToken;

  /// Initialize the background service
  static Future<void> initialize({String? supabaseUrl, String? supabaseKey}) async {
    // Store Supabase config for background service
    if (supabaseUrl != null) _supabaseUrl = supabaseUrl;
    if (supabaseKey != null) _supabaseKey = supabaseKey;

    if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // Web and desktop platforms don't support background services
      // Use periodic task scheduling as fallback
      _initializeFallbackService();
      return;
    }

    try {
      // Initialize platform-specific background service
      await _channel.invokeMethod('initialize', {
        'serviceName': _serviceName,
        'notificationTitle': 'MatchMe Active',
        'notificationText': 'Finding matches nearby',
      });

      // Set up method call handler for communication from native side
      _channel.setMethodCallHandler(_handleMethodCall);

      debugPrint('Background service initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize background service: $e');
      _initializeFallbackService();
    }
  }

  /// Start the background service
  static Future<void> start() async {
    if (_isRunning) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    _userId = user.id;
    // Get the current session and refresh token if needed
    final session = Supabase.instance.client.auth.currentSession;
    debugPrint('Background service start - session exists: ${session != null}');
    if (session != null) {
      debugPrint('Session expires at: ${session.expiresAt}, current time: ${DateTime.now().millisecondsSinceEpoch / 1000}');
      // Check if token is expired and refresh if needed
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      if (session.expiresAt != null && session.expiresAt! < now) {
        try {
          await Supabase.instance.client.auth.refreshSession();
          final refreshedSession = Supabase.instance.client.auth.currentSession;
          _userToken = refreshedSession?.accessToken;
          debugPrint('Refreshed JWT token for background service: ${_userToken != null ? "success" : "failed"}');
        } catch (e) {
          debugPrint('Failed to refresh token: $e');
          _userToken = session.accessToken; // Use existing token as fallback
        }
      } else {
        _userToken = session.accessToken;
      }

      // Try to register session on server (best effort)
      try {
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null) {
          final platformText = kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'unknown'));
          await SessionService.registerSession(user.id, platform: platformText);
        }
      } catch (e) {
        debugPrint('Background upsert_user_session failed: $e');
      }

      debugPrint('Final token extracted: ${_userToken != null ? "present (${_userToken!.length} chars)" : "null"}');
    } else {
      debugPrint('No session found for background service');
    }
    // Supabase config should already be set during initialization

    try {
      if (kIsWeb || Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        _startFallbackService();
      } else {
        // Ensure HTTPS URL
        final httpsUrl = _supabaseUrl?.startsWith('https://') == true ? _supabaseUrl : 'https://${_supabaseUrl?.replaceFirst('http://', '')}';

        // Start platform-specific background service
        debugPrint('Starting Android background service with userId: $_userId, url: $httpsUrl, key length: ${_supabaseKey?.length}, token: ${_userToken != null ? 'present (${_userToken!.length} chars)' : 'null'}');
        final result = await _channel.invokeMethod('startService', {
          'userId': _userId,
          'supabaseUrl': httpsUrl,
          'supabaseKey': _supabaseKey,
          'userToken': _userToken,
        });
        debugPrint('Android background service start result: $result');
      }

      _isRunning = true;
      debugPrint('Background service started');
    } catch (e) {
      debugPrint('Failed to start background service: $e');
      _startFallbackService();
    }
  }

  /// Stop the background service
  static Future<void> stop() async {
    if (!_isRunning) return;

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
      _realtimeSubscription?.cancel();
      _heartbeatTimer = null;
      _syncTimer = null;
      _connectivitySubscription = null;
      _realtimeSubscription = null;

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
        // Fallback: update via regular Supabase client if available
        final targetUserId = _userId ?? Supabase.instance.client.auth.currentUser?.id;
        if (targetUserId != null) {
          await Supabase.instance.client
              .from('users')
              .update({'user_visibility_setting': isVisible})
              .eq('id', targetUserId);
        }
      } else {
        // Prefer telling native service to change its behavior
        try {
            await _channel.invokeMethod('updateVisibility', {'isVisible': isVisible}); // native service expects same payload; DB field renamed to user_visibility_setting
        } catch (e) {
          debugPrint('Native updateVisibility failed: $e');
        }

        // Always ensure DB visibility is updated immediately as a fallback
        try {
          final targetUserId = _userId ?? Supabase.instance.client.auth.currentUser?.id;
          if (targetUserId != null) {
            await Supabase.instance.client
                .from('users')
                .update({'user_visibility_setting': isVisible})
                .eq('id', targetUserId);
          }
        } catch (e) {
          debugPrint('Failed to set user_visibility_setting in DB: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to update visibility in background: $e');
    }
  }

  /// Update JWT token in background service (call when token is refreshed)
  static Future<void> updateToken(String? token) async {
    _userToken = token;
    debugPrint('Background service token update: ${token != null ? 'present (${token.length} chars)' : 'null'}');
    try {
      if (!kIsWeb && !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
        final result = await _channel.invokeMethod('updateToken', {'token': token});
        debugPrint('Background service token update result: $result');
      }
      debugPrint('Updated JWT token in background service successfully');
    } catch (e) {
      debugPrint('Failed to update token in background service: $e');
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
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      if (results.isNotEmpty) {
        _handleConnectivityChange(results.first);
      }
    });

    debugPrint('Fallback background service started');
  }

  /// Stop fallback background service
  static void _stopFallbackService() {
    _isRunning = false;
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _connectivitySubscription?.cancel();
    _realtimeSubscription?.cancel();
    _heartbeatTimer = null;
    _syncTimer = null;
    _connectivitySubscription = null;
    _realtimeSubscription = null;
    debugPrint('Fallback background service stopped');
  }

  /// Background heartbeat to keep user online
  static Future<void> _backgroundHeartbeat() async {
    if (_userId == null) return;

    try {
      await Supabase.instance.client.rpc('update_user_activity', params: <String, dynamic>{'p_user_id': _userId});
    } catch (e) {
      debugPrint('Background heartbeat failed: $e');
    }
  }

  /// Background sync operations
  static Future<void> _backgroundSync() async {
    if (_userId == null) return;

    try {
      // Sync matches
      await Supabase.instance.client.from('matches').select('id').or('user1_id.eq.$_userId,user2_id.eq.$_userId');

      // Sync recent chats
      await Supabase.instance.client.from('chat_messages').select('id').eq('sender_id', _userId!).order('created_at', ascending: false).limit(1);

      // Note: Match engine is now handled server-side autonomously
      // No client-side triggering needed - matches are created by Supabase functions
    } catch (e) {
      debugPrint('Background sync failed: $e');
    }
  }

  /// Handle connectivity changes
  static void _handleConnectivityChange(ConnectivityResult result) {
    final isOnline = result != ConnectivityResult.none;
    debugPrint('Background connectivity changed: ${isOnline ? 'online' : 'offline'}');
    // Background service will handle reconnection automatically
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
      // Sync any pending data when coming back online
      await _backgroundSync();
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
      final localDb = LocalDbService();
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
      final localDb = LocalDbService();
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
