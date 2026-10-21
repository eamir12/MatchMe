import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matchme/services/connectivity_restore_coordinator.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Centralized manager for all Supabase Realtime channels.
///
/// When the device goes offline, [pauseAll] disconnects the WebSocket
/// immediately (no error floods). When back online, [resumeAll] reconnects
/// and re-subscribes every registered channel.
///
/// Providers register channel "factories" via [register] and unregister
/// them on dispose via [unregister].
///
/// The manager can also run a periodic health check (see
/// [startHealthWatchdog]). A socket can drop without the connectivity layer
/// ever noticing it (transient packet loss, a mobile network handover, the
/// server restarting, the OS suspending the network stack). The realtime
/// client re-joins the channels it knows were lost, and this watchdog
/// catches the remaining cases where a channel ends up subscribed-but-dead -
/// the failure mode that makes settings silently stop syncing between
/// devices.
class SupabaseRealtimeManager {
  SupabaseRealtimeManager._() {
    _restoreSubscription = ConnectivityRestoreCoordinator.instance.addListener(
      _onRestore,
    );
  }

  static final SupabaseRealtimeManager instance = SupabaseRealtimeManager._();

  /// Channel name → factory that returns a subscribed [RealtimeChannel].
  final Map<String, RealtimeChannel Function()> _factories = {};

  /// Currently active (subscribed) channels.
  ///
  /// The channel objects survive a pause/resume cycle: the realtime client
  /// re-joins them when the socket comes back, so there is no need to throw
  /// them away and re-create (duplicate) channels.
  final Map<String, RealtimeChannel> _active = {};

  bool _isPaused = false;
  Timer? _watchdogTimer;
  Timer? _healthTimer;
  late final void Function() _restoreSubscription;

  /// In-flight socket teardown / restore operations.
  ///
  /// They are awaited in order so a restore never races a teardown: calling
  /// `connect()` while the socket is still marked as "disconnecting" is a
  /// no-op, which would leave every channel unable to join.
  Future<void>? _teardownOp;
  Future<void>? _restoreOp;

  /// Channels observed to be unjoined, and since when.
  final Map<String, DateTime> _unhealthySince = {};

  /// How often the watchdog checks whether a paused manager should resume.
  static const Duration _watchdogInterval = Duration(seconds: 20);

  /// How often the health check verifies that channels are still live.
  static const Duration _healthCheckInterval = Duration(seconds: 45);

  /// How long a channel may stay unjoined before it is re-created.
  static const Duration _unhealthyGrace = Duration(seconds: 20);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Whether the manager is currently paused (offline).
  bool get isPaused => _isPaused;

  /// Whether [name] currently has a live channel in the manager.
  /// Providers should check this before recreating a channel on app resume:
  /// a screen off/on cycle does not disconnect the socket, so the existing
  /// channel is still valid and must be kept (stay subscribed).
  bool isActive(String name) => _active.containsKey(name);

  /// Returns the live channel for [name], if any.
  RealtimeChannel? getChannel(String name) => _active[name];

  /// Register a channel factory. The channel is created immediately unless
  /// the manager is paused.
  ///
  /// [name] must be unique across the app (use the Supabase channel name).
  /// [factory] should create and *subscribe* the channel, returning it.
  ///
  /// Set [activateNow] to false for channels that are subscribed by their own
  /// provider (e.g. after a cold-start delay): the factory is only stored and
  /// becomes active on the next [resumeAll] following a [pauseAll], so an
  /// offline→online cycle re-creates the channel instead of leaving it dead.
  ///
  /// Idempotent: if a live channel already exists for [name] it is kept as-is
  /// (only the factory is updated). This prevents screen off/on resume paths
  /// from tearing down healthy subscriptions and re-subscribing for no reason.
  /// Callers that really need a fresh channel must [unregister] first.
  void register(
    String name,
    RealtimeChannel Function() factory, {
    bool activateNow = true,
  }) {
    _factories[name] = factory;
    if (_isPaused) {
      _resumeIfBackendReachable();
      return;
    }
    if (_active.containsKey(name) || !activateNow) return;
    _activate(name);
  }

  /// Unregister and dispose a channel.
  void unregister(String name) {
    _factories.remove(name);
    _unhealthySince.remove(name);
    _deactivate(name);
  }

  /// Pause all channels and disconnect the WebSocket immediately.
  /// Called when the device loses network transport.
  void pauseAll() {
    if (_isPaused) return;
    _isPaused = true;
    debugPrint('🔴 [REALTIME-MGR] Pausing all channels');
    _teardownOp = _teardownSocket();
    _startWatchdog();
  }

  /// Resume all channels and reconnect the WebSocket.
  /// Called when connectivity is restored.
  void resumeAll() {
    if (!_isPaused) return;
    _isPaused = false;
    _stopWatchdog();
    debugPrint(
      '🟢 [REALTIME-MGR] Resuming all channels (${_factories.length} registered)',
    );
    _scheduleRestore();
  }

  /// Serializes socket restores so that two overlapping calls cannot
  /// interleave their connect/verify sequence.
  void _scheduleRestore() {
    final pending = _restoreOp;
    if (pending == null) {
      _restoreOp = _restoreSocket();
      return;
    }
    _restoreOp = pending.then(
      (_) => _restoreSocket(),
      onError: (_) => _restoreSocket(),
    );
  }

  /// Dispose everything – call on app shutdown.
  void dispose() {
    _stopWatchdog();
    _stopHealthWatchdog();
    _restoreSubscription();
    _factories.clear();
    for (final channel in _active.values.toList()) {
      try {
        Supabase.instance.client.removeChannel(channel);
      } catch (_) {}
    }
    _active.clear();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _onRestore() {
    if (_isPaused) {
      resumeAll();
      return;
    }
    // The connectivity layer says the backend is reachable again, but the
    // socket may still be down (a drop the connectivity layer never saw).
    // The pause/resume cycle never happened in that case, so nothing else
    // would bring the socket back.
    try {
      if (!Supabase.instance.client.realtime.isConnected) {
        _recover();
      }
    } catch (_) {}
  }

  Future<void> _teardownSocket() async {
    try {
      // ignore: invalid_use_of_internal_member
      await Supabase.instance.client.realtime.disconnect();
    } catch (_) {}
  }

  Future<void> _restoreSocket() async {
    // A pending teardown has to finish first: `connect()` is a no-op while
    // the socket is still marked as "disconnecting", which would leave every
    // channel unable to join.
    final teardown = _teardownOp;
    if (teardown != null) {
      await teardown;
    }

    try {
      // ignore: invalid_use_of_internal_member
      await Supabase.instance.client.realtime.connect();
    } catch (_) {}

    final realtime = Supabase.instance.client.realtime;
    if (!realtime.isConnected) {
      // The backend is not reachable yet. Do not re-arm the pause watchdog
      // here: the health watchdog already retries a dropped socket, and a
      // second periodic timer would only duplicate that work.
      debugPrint('🟠 [REALTIME-MGR] Resume failed: socket is not connected');
      return;
    }

    // The realtime client re-joins the channels that were subscribed before
    // the socket dropped. Channels that were registered while the socket was
    // down - or whose re-join failed - still have to be created here.
    for (final name in _factories.keys.toList()) {
      if (realtime.isTopicLive(name)) {
        _unhealthySince.remove(name);
        continue;
      }
      _activate(name);
    }
  }

  /// Recovers a socket that dropped without the connectivity layer noticing.
  void _recover() {
    debugPrint('🟠 [REALTIME-MGR] Recovering a dropped realtime socket');
    _teardownOp = _teardownSocket();
    _scheduleRestore();
  }

  void _startWatchdog() {
    _watchdogTimer ??= Timer.periodic(_watchdogInterval, (_) {
      if (!_isPaused) {
        _stopWatchdog();
        return;
      }
      _resumeIfBackendReachable();
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _resumeIfBackendReachable() {
    if (!_isPaused) return;
    if (!OfflineCacheManager.instance.isSupabaseAvailable) return;
    debugPrint(
      '🟠 [REALTIME-MGR] Watchdog: channels paused while backend reachable — resuming',
    );
    resumeAll();
  }

  void _startHealthWatchdog() {
    _healthTimer ??= Timer.periodic(
      _healthCheckInterval,
      (_) => _runHealthCheck(),
    );
  }

  void _stopHealthWatchdog() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  /// Starts the channel health watchdog.
  ///
  /// The owner of the app lifecycle calls this when the app starts and
  /// [stopHealthWatchdog] when it goes away. It is deliberately not started
  /// from the constructor: a service singleton that owns a periodic timer
  /// would leave a pending timer behind in every widget test that happens to
  /// touch the manager.
  void startHealthWatchdog() {
    _startHealthWatchdog();
  }

  /// Stops the channel health watchdog.
  void stopHealthWatchdog() {
    _stopHealthWatchdog();
  }

  /// Verifies that the socket is up and that every registered channel is
  /// actually subscribed.
  ///
  /// A channel can report itself as subscribed while the server has no
  /// subscription for it (the socket dropped and came back without the
  /// channel being re-joined). Nothing else in the app notices this, so the
  /// settings simply stop syncing until the process is restarted.
  void _runHealthCheck() {
    if (_isPaused) return;
    if (_factories.isEmpty) return;

    final RealtimeClient realtime;
    try {
      realtime = Supabase.instance.client.realtime;
    } catch (_) {
      return;
    }
    if (!realtime.isConnected) {
      // The socket dropped without the connectivity layer noticing it.
      debugPrint(
        '🟠 [REALTIME-MGR] Health check: socket is down — recovering',
      );
      _recover();
      return;
    }

    for (final name in _factories.keys.toList()) {
      if (realtime.isTopicLive(name)) {
        _unhealthySince.remove(name);
        continue;
      }
      final since = _unhealthySince[name];
      if (since == null) {
        // Give a freshly created channel time to complete its join before
        // treating it as dead.
        _unhealthySince[name] = DateTime.now();
        continue;
      }
      if (DateTime.now().difference(since) < _unhealthyGrace) continue;
      debugPrint(
        '🟠 [REALTIME-MGR] Health check: channel "$name" is not joined — re-subscribing',
      );
      _unhealthySince.remove(name);
      _replaceChannel(name);
    }
  }

  void _activate(String name) {
    if (_active.containsKey(name)) return;
    final factory = _factories[name];
    if (factory == null) return;
    try {
      _active[name] = factory();
    } catch (e) {
      debugPrint('[REALTIME-MGR] Failed to activate channel "$name": $e');
    }
  }

  /// Re-creates a channel whose subscription is no longer live.
  void _replaceChannel(String name) {
    final old = _active.remove(name);
    if (old != null) {
      try {
        // `unsubscribe` rather than `removeChannel`: the latter disconnects
        // the socket when it was the last channel.
        unawaited(old.unsubscribe());
      } catch (_) {}
    }
    _activate(name);
  }

  void _deactivate(String name) {
    final channel = _active.remove(name);
    if (channel == null) return;
    try {
      Supabase.instance.client.removeChannel(channel);
    } catch (_) {}
  }
}
