import 'dart:async';

import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Coalesces [update_user_activity] RPC calls so heartbeat, navigation, and
/// connectivity handlers do not hammer the database.
class UserActivityService {
  UserActivityService._();

  static final UserActivityService instance = UserActivityService._();

  static const Duration _minInterval = Duration(seconds: 25);

  DateTime? _lastPingAt;
  String? _lastUserId;
  bool _inFlight = false;

  Timer? _heartbeatTimer;
  static const Duration _heartbeatInterval = Duration(seconds: 30);

  /// Starts a visibility-independent heartbeat so a logged-in user stays
  /// online even while invisible. The location stream (which normally keeps
  /// [update_user_activity] fresh) is stopped for invisible users, yet the
  /// online count counts all logged-in users regardless of visibility. The
  /// timer self-cancels if the signed-in user changes or signs out.
  void startHeartbeat(String userId) {
    stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (currentUserId == null || currentUserId != userId) {
        stopHeartbeat();
        return;
      }
      pingIfDue(userId, source: 'periodic-heartbeat');
    });
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Ping user activity at most once per [_minInterval] per user.
  Future<void> pingIfDue(
    String userId, {
    bool force = false,
    String source = 'unknown',
  }) async {
    final uid = userId.trim();
    if (uid.isEmpty) return;
    if (shouldSkipSupabaseCalls()) return;

    final now = DateTime.now();
    if (!force &&
        _lastUserId == uid &&
        _lastPingAt != null &&
        now.difference(_lastPingAt!) < _minInterval) {
      return;
    }
    if (_inFlight) return;

    _inFlight = true;
    try {
      await Supabase.instance.client.rpc(
        'update_user_activity',
        params: {'p_user_id': uid},
      );
      _lastPingAt = now;
      _lastUserId = uid;
    } catch (e) {
      // Suppress auth/RLS failures (dead refresh token) — they are handled
      // via backoff below, not log spam on every heartbeat/location tick.
      if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
        // ignore: avoid_print
        print('[UserActivity] ping failed ($source): $e');
      }
      // Auth/rate-limit/RLS rejections (dead refresh token, 429, 42501)
      // will fail every retry — impose the normal coalescing interval so
      // even force pings back off instead of hot-looping Supabase.
      if (isAuthRateLimitFailure(e)) {
        _lastPingAt = now;
        _lastUserId = uid;
      }
    } finally {
      _inFlight = false;
    }
  }

  void reset() {
    _lastPingAt = null;
    _lastUserId = null;
    _inFlight = false;
  }
}
