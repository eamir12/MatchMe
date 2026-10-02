// lib/providers/typing_provider.dart
//
// WhatsApp-like ephemeral typing indicator built on Supabase Realtime
// Broadcast (no database reads/writes on the hot path).
//
// Behaviour:
//  * Sender emits `typing_start` immediately on first keystroke (no throttle
//    delay) and re-emits it as a heartbeat every 2.5s while still typing.
//    `typing_stop` is sent immediately on idle / send / clear / dispose.
//  * Receiver shows the indicator within ~100-300ms and hides it immediately
//    on `typing_stop`, or automatically after 6s without a heartbeat (covers
//    app-kill / offline without a stop signal).
//  * The legacy `chats.is_typing` column is intentionally no longer used.
//    It remains in the DB harmlessly for old clients; new clients never
//    read or write it (avoids 2s polling + RLS + WAL churn).
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';

final supabase = Supabase.instance.client;

/// How often the sender re-broadcasts `typing_start` while typing.
/// Keeps the receiver alive and covers late joiners (opened chat mid-typing).
const Duration kTypingHeartbeatInterval = Duration(milliseconds: 2500);

/// Receiver-side safety net: hide the indicator if no heartbeat arrived.
/// Must be comfortably larger than [kTypingHeartbeatInterval] so a single
/// dropped broadcast doesn't flicker the UI.
const Duration kTypingExpiry = Duration(seconds: 6);

/// Sender-side idle delay is owned by the chat composer (see chat_screen).
/// Kept here for the optional [TypingService.scheduleStopTyping] helper.
const Duration kTypingIdleDelay = Duration(seconds: 3);

/// Shared broadcast topic per 1-1 conversation. Both participants subscribe
/// to the same topic; events carry `userId` so each side ignores its echo.
String typingChannelName(String matchId) => 'typing:$matchId';

/// realtime-dart delivers broadcasts as
/// `{type: 'broadcast', event: <name>, payload: <original>}` — unwrap it.
Map<String, dynamic> _unwrapBroadcastPayload(Map<String, dynamic> data) {
  final inner = data['payload'];
  if (inner is Map<String, dynamic>) return inner;
  if (inner is Map) return Map<String, dynamic>.from(inner);
  return data;
}

/// Parameters to scope typing signals per conversation.
class TypingParams {
  final String matchId;
  final String selfUserId;
  final String otherUserId;
  const TypingParams({
    required this.matchId,
    required this.selfUserId,
    required this.otherUserId,
  });

  @override
  String toString() =>
      'TypingParams(matchId: $matchId, self: $selfUserId, other: $otherUserId)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TypingParams &&
        other.matchId == matchId &&
        other.selfUserId == selfUserId &&
        other.otherUserId == otherUserId;
  }

  @override
  int get hashCode => Object.hash(matchId, selfUserId, otherUserId);
}

/// Provider to get a scoped TypingService instance.
/// NOTE: not autoDispose so the service remains alive while the chat is open.
final typingServiceProvider = Provider.family<TypingService, TypingParams>((
  ref,
  params,
) {
  final svc = TypingService(params);
  ref.onDispose(() {
    // Best-effort stop; dispose can't await, the send is fire-and-forget
    // and the receiver's expiry timer covers the rare lost-stop case.
    unawaited(svc.dispose());
  });
  return svc;
});

/// Process-wide fan-out for typing broadcasts.
///
/// Multiple widgets can watch the same conversation at once (e.g. a
/// [ChatListItem] row underneath an open [ChatScreen] for the same match).
/// [SupabaseRealtimeManager.register] keeps only ONE live channel per topic,
/// so each provider must NOT register its own channel factory closing over
/// its own controller — the second watcher would never receive events.
/// Instead the hub owns the single channel per match and forwards every
/// broadcast to all live listeners.
typedef TypingBroadcastListener =
    void Function(String event, Map<String, dynamic> payload);

class TypingChannelHub {
  static final Map<String, Set<TypingBroadcastListener>> _listeners = {};

  static void addListener(String matchId, TypingBroadcastListener listener) {
    final name = typingChannelName(matchId);
    _listeners
        .putIfAbsent(name, () => <TypingBroadcastListener>{})
        .add(listener);
    if (shouldSkipSupabaseCalls()) return;
    try {
      // Idempotent: keeps the existing channel (and its dispatch handlers)
      // when one is already live; the factory below only runs when a fresh
      // subscription is actually needed, so it never captures a stale
      // per-widget controller.
      SupabaseRealtimeManager.instance.register(
        name,
        () => _createChannel(name),
      );
    } catch (e) {
      if (kDebugMode && !isExpectedOfflineFailure(e)) {
        debugPrint('Typing realtime subscribe failed: $e');
      }
    }
  }

  static void removeListener(String matchId, TypingBroadcastListener listener) {
    final name = typingChannelName(matchId);
    final set = _listeners[name];
    if (set != null) {
      set.remove(listener);
      if (set.isEmpty) _listeners.remove(name);
    }
    if (!_listeners.containsKey(name)) {
      try {
        SupabaseRealtimeManager.instance.unregister(name);
      } catch (_) {}
    }
  }

  static RealtimeChannel _createChannel(String name) {
    final channel = supabase.channel(name);
    channel.onBroadcast(
      event: 'typing_start',
      callback: (raw) => _dispatch(name, 'typing_start', raw),
    );
    channel.onBroadcast(
      event: 'typing_stop',
      callback: (raw) => _dispatch(name, 'typing_stop', raw),
    );
    // Back-compat: accept a single `typing` event if some client sends it.
    channel.onBroadcast(
      event: 'typing',
      callback: (raw) => _dispatch(name, 'typing', raw),
    );
    channel.subscribe((status, error) {
      if (error == null) return;
      handleExpectedSupabaseOfflineFailure(error);
    });
    return channel;
  }

  static void _dispatch(
    String channelName,
    String event,
    Map<String, dynamic> raw,
  ) {
    final set = _listeners[channelName];
    if (set == null || set.isEmpty) return;
    late final Map<String, dynamic> payload;
    try {
      payload = _unwrapBroadcastPayload(raw);
    } catch (_) {
      return;
    }
    for (final listener in set.toList()) {
      try {
        listener(event, payload);
      } catch (_) {}
    }
  }
}

/// Ephemeral "other user is typing" stream driven by Realtime Broadcast.
/// No polling, no database reads.
final isOtherTypingProvider = StreamProvider.autoDispose
    .family<bool, TypingParams>((ref, params) {
      final controller = StreamController<bool>.broadcast();

      bool lastValue = false;
      Timer? expiryTimer;

      void emit(bool value) {
        if (controller.isClosed) return;
        if (value == lastValue) {
          // Heartbeat for `true`: keep the value but refresh the expiry window
          // so a steady stream of starts never times out mid-typing.
          if (value) {
            expiryTimer?.cancel();
            expiryTimer = Timer(kTypingExpiry, () => emit(false));
          }
          return;
        }
        lastValue = value;
        controller.add(value);
        expiryTimer?.cancel();
        if (value) {
          expiryTimer = Timer(kTypingExpiry, () => emit(false));
        }
      }

      bool isPeerEvent(Map<String, dynamic> payload) {
        final senderId = payload['userId']?.toString();
        if (senderId == null || senderId.isEmpty) return false;
        // Ignore our own broadcast echo.
        if (senderId == params.selfUserId) return false;
        // 1-1 chat: only the conversation peer matters.
        if (params.otherUserId.isNotEmpty && senderId != params.otherUserId) {
          return false;
        }
        return true;
      }

      void onHubEvent(String event, Map<String, dynamic> payload) {
        try {
          if (!isPeerEvent(payload)) return;
          switch (event) {
            case 'typing_start':
              emit(true);
              break;
            case 'typing_stop':
              emit(false);
              break;
            default: // generic `typing` event
              final flag = payload['isTyping'] ?? payload['typing'];
              if (flag is bool) {
                emit(flag);
              } else if (flag != null) {
                emit(flag.toString().toLowerCase() == 'true');
              }
              break;
          }
        } catch (_) {}
      }

      TypingChannelHub.addListener(params.matchId, onHubEvent);

      // Clear a potentially stale `true` when backgrounded; the sender's
      // heartbeat will re-assert within ~2.5s if they are genuinely still typing.
      final lifecycleListener = AppLifecycleListener(
        onStateChange: (AppLifecycleState state) {
          if (state == AppLifecycleState.paused ||
              state == AppLifecycleState.detached ||
              state == AppLifecycleState.hidden) {
            emit(false);
          }
        },
      );

      // Re-register after connectivity restore (manager re-subscribes channels;
      // a lost window is covered by the sender heartbeat + our expiry timer).
      // The hub factory re-attaches dispatch handlers, which fan out to the
      // current live listener set — no per-widget closures go stale.
      final resumeDispose = onSupabaseResume(() {
        if (!ref.mounted) return;
        if (shouldSkipSupabaseCalls()) return;
        try {
          final name = typingChannelName(params.matchId);
          if (SupabaseRealtimeManager.instance.getChannel(name) == null) {
            SupabaseRealtimeManager.instance.register(
              name,
              () => TypingChannelHub._createChannel(name),
            );
          }
        } catch (_) {}
      });

      ref.onDispose(() {
        expiryTimer?.cancel();
        try {
          TypingChannelHub.removeListener(params.matchId, onHubEvent);
        } catch (_) {}
        try {
          lifecycleListener.dispose();
        } catch (_) {}
        try {
          resumeDispose();
        } catch (_) {}
        try {
          controller.close();
        } catch (_) {}
      });

      return controller.stream;
    });

/// Sends this device's typing state over Realtime Broadcast.
///
/// * `startTyping()` sends immediately on the 0→1 transition (no artificial
///   delay) and starts a heartbeat that re-sends `typing_start` so late
///   joiners and single-packet loss still converge.
/// * `stopTyping()` sends immediately on the 1→0 transition.
/// * All sends are best-effort with short timeouts — typing must never block
///   the composer or crash on network hiccups.
class TypingService {
  final TypingParams _p;
  Timer? _stopTypingTimer;
  Timer? _heartbeatTimer;
  bool _isTyping = false;
  bool _disposed = false;

  RealtimeChannel? _channel;
  Future<RealtimeChannel?>? _channelFuture;
  bool _ownsChannel = false;

  TypingService(this._p);

  String get _channelName => typingChannelName(_p.matchId);

  /// Returns a subscribed broadcast channel, preferring the shared hub
  /// channel owned by [TypingChannelHub] when a receiver is active.
  /// Lazily created on first send (not in the constructor) so the sender
  /// reuses the already-subscribed hub channel instead of opening a
  /// duplicate subscription to the same topic.
  Future<RealtimeChannel?> _ensureChannel() {
    if (_disposed) return Future.value(null);
    if (shouldSkipSupabaseCalls()) return Future.value(null);
    if (_channel != null) return Future.value(_channel);
    final inFlight = _channelFuture;
    if (inFlight != null) return inFlight;

    // Fast path: the receive side already subscribed via the realtime
    // manager — broadcasts can be sent over that same WebSocket.
    try {
      final shared = SupabaseRealtimeManager.instance.getChannel(_channelName);
      if (shared != null) {
        _channel = shared;
        _ownsChannel = false;
        return Future.value(shared);
      }
    } catch (_) {}

    final future = _createSendChannel();
    _channelFuture = future;
    return future;
  }

  Future<RealtimeChannel?> _createSendChannel() async {
    if (_disposed || shouldSkipSupabaseCalls()) {
      _channelFuture = null;
      return null;
    }
    try {
      final channel = supabase.channel(_channelName);
      // Dummy handlers keep the channel in WebSocket mode; without an active
      // subscription realtime-dart falls back to a REST POST that requires
      // RLS on realtime.messages (not provisioned in this project).
      channel.onBroadcast(event: 'typing_start', callback: (_) {});
      channel.onBroadcast(event: 'typing_stop', callback: (_) {});
      channel.subscribe((status, error) {
        if (error == null) return;
        handleExpectedSupabaseOfflineFailure(error);
      });
      _channel = channel;
      _ownsChannel = true;
      return channel;
    } catch (_) {
      return null;
    } finally {
      _channelFuture = null;
    }
  }

  Future<void> _send(String event) async {
    if (_disposed || shouldSkipSupabaseCalls()) return;
    try {
      final channel = await _ensureChannel();
      if (channel == null || _disposed) return;
      if (shouldSkipSupabaseCalls()) return;
      await channel
          .sendBroadcastMessage(
            event: event,
            payload: {
              'userId': _p.selfUserId,
              'ts': DateTime.now().millisecondsSinceEpoch,
            },
          )
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      if (kDebugMode && !isExpectedOfflineFailure(e)) {
        debugPrint('Typing broadcast $event failed (best-effort): $e');
      }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(kTypingHeartbeatInterval, (_) {
      if (_disposed || !_isTyping) return;
      if (shouldSkipSupabaseCalls()) return;
      unawaited(_send('typing_start'));
    });
  }

  void _cancelHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Should be called on every local text change while the composer is
  /// non-empty. Sends immediately the first time; subsequent calls only
  /// keep the heartbeat alive (dedupe → no network spam per keystroke).
  void startTyping() {
    _stopTypingTimer?.cancel();
    if (_disposed) return;
    if (shouldSkipSupabaseCalls()) {
      _isTyping = true;
      return;
    }
    if (_isTyping) return;
    _isTyping = true;
    unawaited(_send('typing_start'));
    _startHeartbeat();
  }

  /// Should be called on idle timeout, send, clear, blur and dispose.
  /// Sends immediately (no throttle) so the peer hides the indicator fast.
  void stopTyping() {
    _stopTypingTimer?.cancel();
    _cancelHeartbeat();
    if (_disposed) return;
    if (!_isTyping) return;
    _isTyping = false;
    if (shouldSkipSupabaseCalls()) return;
    unawaited(_send('typing_stop'));
  }

  /// Schedule [stopTyping] after [delay] (used for idle timeout when the
  /// caller prefers the service to own the timer).
  void scheduleStopTyping({Duration delay = kTypingIdleDelay}) {
    _stopTypingTimer?.cancel();
    if (_disposed) return;
    if (!_isTyping) return;
    _stopTypingTimer = Timer(delay, () => stopTyping());
  }

  Future<void> dispose() async {
    _disposed = true;
    _stopTypingTimer?.cancel();
    _stopTypingTimer = null;
    _cancelHeartbeat();
    if (_isTyping) {
      _isTyping = false;
      // Best-effort final stop; the receiver expiry covers a lost packet.
      try {
        final channel = _channel;
        if (channel != null && !shouldSkipSupabaseCalls()) {
          await channel
              .sendBroadcastMessage(
                event: 'typing_stop',
                payload: {
                  'userId': _p.selfUserId,
                  'ts': DateTime.now().millisecondsSinceEpoch,
                },
              )
              .timeout(const Duration(seconds: 2));
        }
      } catch (_) {}
    }
    if (_ownsChannel) {
      final channel = _channel;
      _channel = null;
      _ownsChannel = false;
      if (channel != null) {
        try {
          await supabase
              .removeChannel(channel)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    } else {
      _channel = null;
    }
  }
}
