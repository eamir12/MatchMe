import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Publishes the foreground chat being viewed so server push/inbox producers
/// can suppress only messages for that conversation. Rows are session-scoped
/// (rather than device-scoped) so multiple browser tabs do not overwrite one
/// another; stale rows are ignored by the server after 45 seconds.
class ChatViewStateService {
  ChatViewStateService._();

  static final RouteObserver<Route<dynamic>> routeObserver =
      RouteObserver<Route<dynamic>>();

  static final String _sessionId = const Uuid().v4();
  static String? _userId;
  static String? _matchId;
  static bool _foreground = false;
  static bool _routeVisible = false;
  static Timer? _heartbeat;
  static Future<void> _writeQueue = Future<void>.value();

  static Future<void> setViewingChat(String matchId) {
    _matchId = matchId.trim().isEmpty ? null : matchId.trim();
    _userId = Supabase.instance.client.auth.currentUser?.id;
    _foreground = true;
    _routeVisible = true;
    final write = _scheduleWrite();
    _heartbeat ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => _scheduleWrite(),
    );
    return write;
  }

  static Future<void> clearViewingChat() {
    _matchId = null;
    _routeVisible = false;
    final write = _scheduleWrite();
    _stopHeartbeatIfIdle();
    return write;
  }

  static void setAppForeground(bool foreground) {
    _foreground = foreground;
    _scheduleWrite();
    if (foreground && _matchId != null && _routeVisible) {
      _heartbeat ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => _scheduleWrite(),
      );
    } else {
      _stopHeartbeatIfIdle();
    }
  }

  static void setChatRouteVisible(bool visible) {
    _routeVisible = visible;
    _scheduleWrite();
    if (visible && _foreground && _matchId != null) {
      _heartbeat ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => _scheduleWrite(),
      );
    } else {
      _stopHeartbeatIfIdle();
    }
  }

  static Future<void> clearForLogout() async {
    _userId = null;
    _matchId = null;
    _routeVisible = false;
    _foreground = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _scheduleWrite();
  }

  static void _stopHeartbeatIfIdle() {
    if (_matchId == null || !_foreground || !_routeVisible) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  static Future<void> _scheduleWrite() {
    _writeQueue = _writeQueue.then((_) => _writeState());
    return _writeQueue;
  }

  static Future<void> _writeState() async {
    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id ?? _userId;
    if (currentUserId == null || currentUserId.isEmpty) return;
    _userId = currentUserId;
    final active = _foreground && _routeVisible && _matchId != null;
    try {
      await client.from('user_chat_view_state').upsert(
        {
          'user_id': currentUserId,
          'session_id': _sessionId,
          'match_id': active ? _matchId : null,
          'is_active': active,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,session_id',
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Chat view state sync failed: $error');
      }
    }
  }
}
