import 'package:flutter/foundation.dart';
import 'package:matchme/services/connectivity_restore_coordinator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Centralized manager for all Supabase Realtime channels.
///
/// When the device goes offline, [pauseAll] disconnects the WebSocket
/// immediately (no error floods). When back online, [resumeAll] reconnects
/// and re-creates every registered channel atomically.
///
/// Providers register channel "factories" via [register] and unregister
/// them on dispose via [unregister].
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
  final Map<String, RealtimeChannel> _active = {};

  bool _isPaused = false;
  late final void Function() _restoreSubscription;

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
    final alreadyActive = _active.containsKey(name);
    _factories[name] = factory;
    if (_isPaused) return;
    if (alreadyActive || !activateNow) return;
    _activate(name);
  }

  /// Unregister and dispose a channel.
  void unregister(String name) {
    _factories.remove(name);
    _deactivate(name);
  }

  /// Pause all channels and disconnect the WebSocket immediately.
  /// Called when the device loses network transport.
  void pauseAll() {
    if (_isPaused) return;
    _isPaused = true;
    debugPrint('🔴 [REALTIME-MGR] Pausing all channels');
    try {
      // ignore: invalid_use_of_internal_member
      Supabase.instance.client.realtime.disconnect();
    } catch (_) {}
    _active.clear();
  }

  /// Resume all channels and reconnect the WebSocket.
  /// Called when connectivity is restored.
  void resumeAll() {
    if (!_isPaused) return;
    _isPaused = false;
    debugPrint(
      '🟢 [REALTIME-MGR] Resuming all channels (${_factories.length} registered)',
    );
    try {
      // ignore: invalid_use_of_internal_member
      Supabase.instance.client.realtime.connect();
    } catch (_) {}
    // Re-subscribe every registered channel
    for (final name in _factories.keys.toList()) {
      _activate(name);
    }
  }

  /// Dispose everything – call on app shutdown.
  void dispose() {
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
    resumeAll();
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

  void _deactivate(String name) {
    final channel = _active.remove(name);
    if (channel == null) return;
    try {
      Supabase.instance.client.removeChannel(channel);
    } catch (_) {}
  }
}
