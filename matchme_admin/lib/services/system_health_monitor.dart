// matchme_admin/lib/services/system_health_monitor.dart
//
// Continuous Supabase health monitor shared by the System Health screen and
// the dashboard status pill. Probes the database via the `health_check()`
// RPC (with latency), tracks the Realtime WebSocket connection state plus an
// `admin_dashboard_tick` heartbeat, inspects the admin session expiry, and
// polls the notification queue health RPC.
//
// Ref-counted: [acquire] starts probing on the first listener and [release]
// stops it when the last listener goes away. Listeners subscribe via
// [stream] and can read the latest [current] snapshot synchronously
// (broadcast streams do not replay past emissions).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum SystemHealthStatus { checking, healthy, degraded, down }

class SystemHealthSnapshot {
  const SystemHealthSnapshot({
    required this.overall,
    required this.dbOk,
    this.dbLatencyMs,
    this.dbLastCheckedAt,
    this.dbLastOkAt,
    this.dbConsecutiveFailures = 0,
    this.dbError,
    this.dbLatencyHistory = const [],
    required this.socketState,
    this.socketEverConnected = false,
    this.lastTickAt,
    required this.sessionActive,
    this.sessionExpiresAt,
    this.queueHealth,
    this.queueCheckedAt,
    required this.updatedAt,
  });

  final SystemHealthStatus overall;

  final bool dbOk;
  final int? dbLatencyMs;
  final DateTime? dbLastCheckedAt;
  final DateTime? dbLastOkAt;
  final int dbConsecutiveFailures;
  final String? dbError;
  final List<int> dbLatencyHistory;

  final String socketState;
  final bool socketEverConnected;
  final DateTime? lastTickAt;

  final bool sessionActive;
  final DateTime? sessionExpiresAt;

  final Map<String, dynamic>? queueHealth;
  final DateTime? queueCheckedAt;

  final DateTime updatedAt;

  Duration? get sessionTimeLeft {
    final exp = sessionExpiresAt;
    if (exp == null) return null;
    final left = exp.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get sessionExpiringSoon {
    final left = sessionTimeLeft;
    return left != null && left < const Duration(minutes: 15);
  }
}

class SystemHealthMonitor {
  SystemHealthMonitor._internal();

  static final SystemHealthMonitor _instance = SystemHealthMonitor._internal();
  static SystemHealthMonitor get instance => _instance;

  static const Duration _dbProbeInterval = Duration(seconds: 10);
  static const Duration _dbProbeTimeout = Duration(seconds: 6);
  static const Duration _queueProbeInterval = Duration(seconds: 30);
  static const Duration _slowLatencyThreshold = Duration(milliseconds: 1500);
  static const Duration _heartbeatStaleAfter = Duration(minutes: 3);
  static const int _maxLatencyHistory = 30;

  final _controller = StreamController<SystemHealthSnapshot>.broadcast();

  int _listeners = 0;
  Timer? _dbProbeTimer;
  Timer? _queueProbeTimer;
  StreamSubscription<bool>? _availabilitySub;
  RealtimeChannel? _tickChannel;
  int _tickChannelRetries = 0;
  bool _socketHooksRegistered = false;

  bool _dbProbeInFlight = false;
  bool _dbOk = true;
  bool _dbEverSucceeded = false;
  int? _dbLatencyMs;
  int _dbConsecutiveFailures = 0;
  String? _dbError;
  DateTime? _dbLastCheckedAt;
  DateTime? _dbLastOkAt;
  final List<int> _dbLatencyHistory = <int>[];

  String _socketState = 'closed';
  bool _socketEverConnected = false;
  DateTime? _lastTickAt;

  bool _sessionActive = false;
  DateTime? _sessionExpiresAt;

  Map<String, dynamic>? _queueHealth;
  DateTime? _queueCheckedAt;

  DateTime _updatedAt = DateTime.now();
  SystemHealthSnapshot _current = SystemHealthSnapshot(
    overall: SystemHealthStatus.checking,
    dbOk: true,
    socketState: 'closed',
    sessionActive: false,
    updatedAt: DateTime.now(),
  );

  Stream<SystemHealthSnapshot> get stream => _controller.stream;
  SystemHealthSnapshot get current => _current;

  /// Start monitoring. Call once per listener; probing begins on the first
  /// acquire and stops when the last listener releases.
  void acquire() {
    _listeners++;
    if (_listeners == 1) _start();
  }

  void release() {
    if (_listeners == 0) return;
    _listeners--;
    if (_listeners == 0) _stop();
  }

  void _start() {
    _registerSocketHooks();
    unawaited(_probeDatabase());
    unawaited(_probeQueue());
    _dbProbeTimer = Timer.periodic(
      _dbProbeInterval,
      (_) => unawaited(_probeDatabase()),
    );
    _queueProbeTimer = Timer.periodic(
      _queueProbeInterval,
      (_) => unawaited(_probeQueue()),
    );
    // Re-probe immediately when the offline manager flips back to available
    // so the dashboard recovers without waiting for the next timer tick.
    _availabilitySub = adminOfflineCacheManager.availabilityStream.listen((
      available,
    ) {
      if (available) {
        unawaited(_probeDatabase());
        unawaited(_probeQueue());
      } else {
        _emit();
      }
    });
    _ensureTickChannel();
    _emit();
  }

  void _stop() {
    _dbProbeTimer?.cancel();
    _dbProbeTimer = null;
    _queueProbeTimer?.cancel();
    _queueProbeTimer = null;
    unawaited(_availabilitySub?.cancel());
    _availabilitySub = null;
    final channel = _tickChannel;
    _tickChannel = null;
    if (channel != null) {
      try {
        Supabase.instance.client.removeChannel(channel);
      } catch (_) {}
    }
  }

  void _registerSocketHooks() {
    if (_socketHooksRegistered) return;
    _socketHooksRegistered = true;
    try {
      final realtime = Supabase.instance.client.realtime;
      realtime.onOpen(() {
        _socketState = 'open';
        _socketEverConnected = true;
        _emit();
      });
      realtime.onClose((_) {
        _socketState = 'closed';
        _emit();
      });
    } catch (_) {
      // Realtime hooks are an enhancement; the periodic probes still run.
    }
  }

  void _ensureTickChannel() {
    if (_listeners == 0) return;
    try {
      final channel = Supabase.instance.client
          .channel('admin-system-health-monitor')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'admin_dashboard_tick',
            callback: (_) {
              _lastTickAt = DateTime.now();
              _emit();
            },
          )
          .subscribe((status, error) {
        if (error != null ||
            status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          if (_tickChannelRetries >= 5 || _listeners == 0) return;
          _tickChannelRetries++;
          Future.delayed(const Duration(seconds: 3), () {
            if (_listeners == 0) return;
            final old = _tickChannel;
            _tickChannel = null;
            if (old != null) {
              try {
                Supabase.instance.client.removeChannel(old);
              } catch (_) {}
            }
            _ensureTickChannel();
          });
        } else if (status == RealtimeSubscribeStatus.subscribed) {
          _tickChannelRetries = 0;
          _emit();
        }
      });
      _tickChannel = channel;
    } catch (_) {
      // Heartbeat is a secondary signal; socket state + probes still work.
    }
  }

  Future<void> _probeDatabase() async {
    if (_dbProbeInFlight || _listeners == 0) return;
    _dbProbeInFlight = true;
    final stopwatch = Stopwatch()..start();
    var ok = false;
    String? error;
    try {
      final res = await Supabase.instance.client
          .rpc('health_check')
          .timeout(_dbProbeTimeout);
      stopwatch.stop();
      if (res is Map) {
        ok = res['ok'] != false;
        if (!ok) error = (res['error'] ?? 'health_check returned ok=false').toString();
      } else {
        ok = true;
      }
    } catch (e) {
      stopwatch.stop();
      ok = false;
      error = e.toString();
    }
    _dbProbeInFlight = false;
    _dbLastCheckedAt = DateTime.now();
    if (ok) {
      _dbOk = true;
      _dbEverSucceeded = true;
      _dbConsecutiveFailures = 0;
      _dbError = null;
      _dbLastOkAt = _dbLastCheckedAt;
      _dbLatencyMs = stopwatch.elapsedMilliseconds;
      _dbLatencyHistory.add(_dbLatencyMs!);
      if (_dbLatencyHistory.length > _maxLatencyHistory) {
        _dbLatencyHistory.removeAt(0);
      }
    } else {
      _dbOk = false;
      _dbConsecutiveFailures += 1;
      _dbError = error;
    }
    // Keep the app-wide offline manager in sync so the global offline
    // banner and this screen agree (non-forced: failures go through the
    // manager's grace-period debounce).
    adminOfflineCacheManager.setSupabaseAvailability(ok);
    _emit();
  }

  Future<void> _probeQueue() async {
    if (_listeners == 0) return;
    try {
      final res = await Supabase.instance.client
          .rpc('get_notification_queue_health')
          .timeout(const Duration(seconds: 8));
      if (res is Map) {
        _queueHealth = Map<String, dynamic>.from(res);
        _queueCheckedAt = DateTime.now();
        _emit();
      }
    } catch (_) {
      // Queue health is informational; keep the last known value.
    }
  }

  void _refreshSession() {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      _sessionActive = session != null;
      final exp = session?.expiresAt;
      _sessionExpiresAt = exp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    } catch (_) {
      _sessionActive = false;
      _sessionExpiresAt = null;
    }
  }

  SystemHealthStatus _computeOverall() {
    final now = DateTime.now();

    if (_dbConsecutiveFailures >= 2) return SystemHealthStatus.down;
    if (!_dbEverSucceeded &&
        _dbConsecutiveFailures >= 1 &&
        _dbLastCheckedAt != null &&
        now.difference(_dbLastCheckedAt!) >= const Duration(seconds: 25)) {
      return SystemHealthStatus.down;
    }

    var degraded = false;
    if (_dbConsecutiveFailures == 1) degraded = true;
    if (_dbLatencyMs != null &&
        _dbLatencyMs! > _slowLatencyThreshold.inMilliseconds) {
      degraded = true;
    }
    // Only penalize the socket after it has connected at least once, so the
    // initial 'closed' state before the first connect isn't flagged.
    if (_socketEverConnected && _socketState != 'open') degraded = true;
    final tick = _lastTickAt;
    if (tick != null && now.difference(tick) > _heartbeatStaleAfter) {
      degraded = true;
    }
    if (_queueHealth?['alert'] == true) degraded = true;
    if (_sessionExpiresAt != null &&
        _sessionExpiresAt!.difference(now) < const Duration(minutes: 15)) {
      degraded = true;
    }

    if (degraded) return SystemHealthStatus.degraded;
    if (!_dbEverSucceeded) return SystemHealthStatus.checking;
    return SystemHealthStatus.healthy;
  }

  void _emit() {
    if (_listeners == 0) return;
    _refreshSession();
    _updatedAt = DateTime.now();
    _current = SystemHealthSnapshot(
      overall: _computeOverall(),
      dbOk: _dbOk,
      dbLatencyMs: _dbLatencyMs,
      dbLastCheckedAt: _dbLastCheckedAt,
      dbLastOkAt: _dbLastOkAt,
      dbConsecutiveFailures: _dbConsecutiveFailures,
      dbError: _dbError,
      dbLatencyHistory: List<int>.unmodifiable(_dbLatencyHistory),
      socketState: _socketState,
      socketEverConnected: _socketEverConnected,
      lastTickAt: _lastTickAt,
      sessionActive: _sessionActive,
      sessionExpiresAt: _sessionExpiresAt,
      queueHealth: _queueHealth,
      queueCheckedAt: _queueCheckedAt,
      updatedAt: _updatedAt,
    );
    if (_controller.hasListener) {
      try {
        _controller.add(_current);
      } catch (_) {
        // Stream may be mid-close during teardown; safe to ignore.
      }
    }
  }
}

final systemHealthMonitor = SystemHealthMonitor.instance;

/// Short human age label, e.g. `5s`, `3m`, `2h`, `4d`. Duration.zero and
/// negative durations render as `—` via the caller when appropriate.
String systemHealthAgeLabel(Duration d) {
  if (d.isNegative) return '—';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inSeconds < 3600) return '${d.inMinutes}m';
  if (d.inSeconds < 86400) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Riverpod stream provider mirroring the monitor. Starts probing on first
/// watch; because it is keep-alive, once created it monitors for the rest
/// of the app session (the admin app wants constant health updates).
/// Consumers should render [SystemHealthMonitor.current] as an immediate
/// value while waiting for the first stream event.
final systemHealthProvider = StreamProvider<SystemHealthSnapshot>((ref) {
  systemHealthMonitor.acquire();
  ref.onDispose(systemHealthMonitor.release);
  return systemHealthMonitor.stream;
});
