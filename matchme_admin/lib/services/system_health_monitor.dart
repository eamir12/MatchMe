// matchme_admin/lib/services/system_health_monitor.dart
//
// Continuous Supabase health monitor shared by the System Health screen and
// the dashboard status pill. Combines two kinds of signals:
//
// 1. Supabase's own self-reported status (status.supabase.com Statuspage
//    API): overall indicator, named components, per-region component
//    statuses, and active incidents. This is the authoritative view of
//    Supabase's health and is independent of the device's network quality.
// 2. Client probes of this project: the `health_check()` RPC (with
//    latency), the Realtime WebSocket + `admin_dashboard_tick` heartbeat,
//    the notification queue health RPC, recent project-level failures
//    (edge functions, cron tasks, app errors) via `admin_get_health_errors()`,
//    and auth failures + disk/API usage via the `project-logs-health` edge
//    function (Supabase Management API).
//
// Client-side concerns that are not Supabase's health (admin session
// expiry, local network quality) are deliberately excluded.
//
// Ref-counted: [acquire] starts probing on the first listener and [release]
// stops it when the last listener goes away. Listeners subscribe via
// [stream] and can read the latest [current] snapshot synchronously
// (broadcast streams do not replay past emissions).
//
// Anti-flap: worsening transitions (healthy → degraded/down) must persist
// for [_statusChangeGrace] before being shown, so brief transients — app
// resume reconnects, a single failed probe, network handoff — keep the last
// confirmed status with no visible bounce. Improvements show instantly.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum SystemHealthStatus { checking, healthy, degraded, down }

// Failure-count thresholds above which the project counts as degraded.
// Tunable constants — revisit if app_error_log proves noisy (background
// services report benign errors) or too lax.
const int kProjectEdgeFailureAlert = 3; // failed edge invocations / 15 min
const int kProjectCronFailureAlert = 2; // failed cron runs / 1 hour
const int kProjectAppErrorAlert = 5; // app_error_log rows / 15 min
const int kAuthFailureAlert = 10; // auth failures (auth_logs) / 15 min
const double kDiskUsageAlertPercent = 90; // db disk used / total size

/// One database probe round-trip measurement.
class SystemHealthLatencySample {
  const SystemHealthLatencySample({required this.at, required this.ms});

  final DateTime at;
  final int ms;
}

/// A named Supabase platform component from the official status page
/// (e.g. Auth, Realtime, Dashboard) with its raw Statuspage status string.
class SupabaseComponentStatus {
  const SupabaseComponentStatus({required this.name, required this.status});

  final String name;
  final String status; // operational | degraded_performance | ...
}

/// An active incident from the official status page.
class SupabaseIncidentStatus {
  const SupabaseIncidentStatus({
    required this.title,
    required this.impact,
    required this.status,
    this.shortlink,
    this.updatedAt,
  });

  final String title;
  final String impact; // none | minor | major | critical
  final String status; // investigating | identified | monitoring | ...
  final String? shortlink;
  final DateTime? updatedAt;
}

/// Aggregated recent failure counts for THIS project (not Supabase the
/// platform): edge-function failures, cron task failures, and app-reported
/// client errors, each with a last-seen timestamp. Parsed from the
/// `admin_get_health_errors()` RPC.
class ProjectErrorsStatus {
  const ProjectErrorsStatus({
    required this.checkedAt,
    this.edgeFailed15m = 0,
    this.edgeLastFailedAt,
    this.edgeLastError,
    this.cronFailed1h = 0,
    this.cronLastFailedAt,
    this.cronLastFailedTasks = const [],
    this.appErrors15m = 0,
    this.appLastErrorAt,
    this.appLastSource,
    this.appLastMessage,
  });

  final DateTime checkedAt;
  final int edgeFailed15m;
  final DateTime? edgeLastFailedAt;
  final String? edgeLastError;
  final int cronFailed1h;
  final DateTime? cronLastFailedAt;
  final List<String> cronLastFailedTasks;
  final int appErrors15m;
  final DateTime? appLastErrorAt;
  final String? appLastSource;
  final String? appLastMessage;

  /// Recent failures exceed the alert thresholds (drives the overall
  /// banner's degraded state and the card's chip).
  bool get alert =>
      edgeFailed15m >= kProjectEdgeFailureAlert ||
      cronFailed1h >= kProjectCronFailureAlert ||
      appErrors15m >= kProjectAppErrorAlert;
}

/// Sign-in activity, auth failures, and usage metrics from THIS project's
/// `project-logs-health` edge function (Supabase Management API: ClickHouse
/// logs for auth, disk utilization, API request counts). Null until the
/// first successful probe; [configured] is false while the function has no
/// `SUPABASE_ACCESS_TOKEN` secret (rows render as unavailable, not alarmed).
class ProjectLogsStatus {
  const ProjectLogsStatus({
    required this.checkedAt,
    required this.configured,
    this.signins15m,
    this.signinsLastAt,
    this.authErrors15m,
    this.authLastErrorAt,
    this.authLastErrorAction,
    this.authLastErrorMessage,
    this.diskUsedBytes,
    this.diskSizeBytes,
    this.diskAvailBytes,
    this.apiRequestsCount,
    this.warnings = const [],
  });

  final DateTime checkedAt;
  final bool configured;
  final int? signins15m;
  final DateTime? signinsLastAt;
  final int? authErrors15m;
  final DateTime? authLastErrorAt;
  final String? authLastErrorAction;
  final String? authLastErrorMessage;
  final int? diskUsedBytes;
  final int? diskSizeBytes;
  final int? diskAvailBytes;
  final int? apiRequestsCount;
  final List<String> warnings;

  double? get diskUsedPercent {
    final used = diskUsedBytes;
    final size = diskSizeBytes;
    if (used == null || size == null || size <= 0) return null;
    return used / size * 100;
  }

  bool get authAlert =>
      configured && (authErrors15m ?? 0) >= kAuthFailureAlert;

  bool get diskAlert {
    if (!configured) return false;
    final pct = diskUsedPercent;
    return pct != null && pct >= kDiskUsageAlertPercent;
  }

  /// Either signal over threshold (drives the overall banner's degraded
  /// state and either card's chip).
  bool get alert => authAlert || diskAlert;
}

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
    this.socketOpenedAt,
    this.lastTickAt,
    this.queueHealth,
    this.queueCheckedAt,
    this.projectErrors,
    this.projectLogs,
    this.spIndicator,
    this.spDescription,
    this.spComponents = const [],
    this.spAffectedRegions = const [],
    this.spRegionsTotal = 0,
    this.spIncidents = const [],
    this.spCheckedAt,
    this.spAvailable = false,
    required this.updatedAt,
  });

  final SystemHealthStatus overall;

  final bool dbOk;
  final int? dbLatencyMs;
  final DateTime? dbLastCheckedAt;
  final DateTime? dbLastOkAt;
  final int dbConsecutiveFailures;
  final String? dbError;
  final List<SystemHealthLatencySample> dbLatencyHistory;

  final String socketState;
  final bool socketEverConnected;
  final DateTime? socketOpenedAt;
  final DateTime? lastTickAt;

  final Map<String, dynamic>? queueHealth;
  final DateTime? queueCheckedAt;

  /// Recent project-level failures (edge functions, cron, app errors).
  /// Null until the first successful `admin_get_health_errors()` probe.
  final ProjectErrorsStatus? projectErrors;

  /// Sign-ins, auth failures, and usage metrics. Null until the first
  /// successful `project-logs-health` probe.
  final ProjectLogsStatus? projectLogs;

  /// Official Supabase status (status.supabase.com Statuspage API).
  /// [spIndicator]: none | minor | major | critical | maintenance.
  final String? spIndicator;
  final String? spDescription;
  final List<SupabaseComponentStatus> spComponents;

  /// Regions with at least one non-operational component (worst status per
  /// region); [spRegionsTotal] is the number of distinct regions tracked.
  final List<SupabaseComponentStatus> spAffectedRegions;
  final int spRegionsTotal;
  final List<SupabaseIncidentStatus> spIncidents;
  final DateTime? spCheckedAt;
  final bool spAvailable;

  final DateTime updatedAt;

  /// True when the socket has been open long enough to have received a tick
  /// but hasn't — right after (re)connect the old tick age is not a signal.
  bool get heartbeatStale {
    final tick = lastTickAt;
    final opened = socketOpenedAt;
    if (tick == null || opened == null) return false;
    const staleAfter = Duration(minutes: 3);
    final now = DateTime.now();
    return now.difference(opened) > staleAfter &&
        now.difference(tick) > staleAfter;
  }
}

class SystemHealthMonitor with WidgetsBindingObserver {
  SystemHealthMonitor._internal();

  static final SystemHealthMonitor _instance = SystemHealthMonitor._internal();
  static SystemHealthMonitor get instance => _instance;

  static const Duration _dbProbeInterval = Duration(seconds: 10);
  static const Duration _dbProbeTimeout = Duration(seconds: 6);
  static const Duration _queueProbeInterval = Duration(seconds: 30);
  // Statuspage asks callers not to poll faster than once per 60 seconds.
  static const Duration _statusPageInterval = Duration(seconds: 60);
  static const Duration _projectErrorsInterval = Duration(seconds: 60);
  // Management API calls are rate-limited (30/min for logs/usage) — a
  // 5-minute cadence keeps this probe far below the quota.
  static const Duration _projectLogsInterval = Duration(minutes: 5);
  static const Duration _slowLatencyThreshold = Duration(milliseconds: 1500);
  static const Duration _heartbeatStaleAfter = Duration(minutes: 3);
  static const Duration _statusChangeGrace = Duration(seconds: 15);
  static const int _maxLatencyHistory = 30;
  static final _regionNamePattern = RegExp(r'^(ap|ca|eu|sa|us)-[a-z]+-\d+$');

  static int _severity(SystemHealthStatus s) => switch (s) {
    SystemHealthStatus.healthy || SystemHealthStatus.checking => 0,
    SystemHealthStatus.degraded => 1,
    SystemHealthStatus.down => 2,
  };

  /// Severity of a Statuspage component status string.
  static int _componentSeverity(String status) => switch (status) {
    'operational' => 0,
    'maintenance' => 1,
    'degraded_performance' => 2,
    'partial_outage' => 3,
    'major_outage' => 4,
    _ => 0,
  };

  final _controller = StreamController<SystemHealthSnapshot>.broadcast();

  int _listeners = 0;
  Timer? _dbProbeTimer;
  Timer? _queueProbeTimer;
  Timer? _statusPageTimer;
  Timer? _projectErrorsTimer;
  Timer? _projectLogsTimer;
  bool _statusPageProbeInFlight = false;
  bool _projectErrorsProbeInFlight = false;
  bool _projectLogsProbeInFlight = false;
  StreamSubscription<bool>? _availabilitySub;
  RealtimeChannel? _tickChannel;
  int _tickChannelRetries = 0;
  bool _socketHooksRegistered = false;
  bool _lifecycleObserverRegistered = false;
  Timer? _socketCloseGraceTimer;
  bool _appInForeground = true;
  bool _socketOpenActual = false;

  bool _dbProbeInFlight = false;
  bool _dbOk = true;
  bool _dbEverSucceeded = false;
  int? _dbLatencyMs;
  int _dbConsecutiveFailures = 0;
  String? _dbError;
  DateTime? _dbLastCheckedAt;
  DateTime? _dbLastOkAt;
  final List<SystemHealthLatencySample> _dbLatencyHistory =
      <SystemHealthLatencySample>[];

  String _socketState = 'closed';
  bool _socketEverConnected = false;
  DateTime? _socketOpenedAt;
  DateTime? _lastTickAt;

  Map<String, dynamic>? _queueHealth;
  DateTime? _queueCheckedAt;

  ProjectErrorsStatus? _projectErrors;
  ProjectLogsStatus? _projectLogs;

  String? _spIndicator;
  String? _spDescription;
  List<SupabaseComponentStatus> _spComponents = const [];
  List<SupabaseComponentStatus> _spAffectedRegions = const [];
  int _spRegionsTotal = 0;
  List<SupabaseIncidentStatus> _spIncidents = const [];
  DateTime? _spCheckedAt;
  bool _spAvailable = false;

  SystemHealthStatus _lastShownStatus = SystemHealthStatus.checking;
  SystemHealthStatus? _statusBeforeSuspension;
  DateTime? _worseningSince;

  DateTime _updatedAt = DateTime.now();
  SystemHealthSnapshot _current = SystemHealthSnapshot(
    overall: SystemHealthStatus.checking,
    dbOk: true,
    socketState: 'closed',
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
    // A (re)start happens because something is watching the screen, i.e.
    // the app is in the foreground; clear any stale background flag.
    _appInForeground = true;
    _registerSocketHooks();
    if (!_lifecycleObserverRegistered) {
      _lifecycleObserverRegistered = true;
      try {
        WidgetsBinding.instance.addObserver(this);
      } catch (_) {
        // Binding may not be available in pure-Dart test contexts.
      }
    }
    unawaited(_probeDatabase());
    unawaited(_probeQueue());
    unawaited(_probeStatusPage());
    unawaited(_probeProjectErrors());
    unawaited(_probeProjectLogs());
    _dbProbeTimer = Timer.periodic(
      _dbProbeInterval,
      (_) => unawaited(_probeDatabase()),
    );
    _queueProbeTimer = Timer.periodic(
      _queueProbeInterval,
      (_) => unawaited(_probeQueue()),
    );
    _statusPageTimer = Timer.periodic(
      _statusPageInterval,
      (_) => unawaited(_probeStatusPage()),
    );
    _projectErrorsTimer = Timer.periodic(
      _projectErrorsInterval,
      (_) => unawaited(_probeProjectErrors()),
    );
    _projectLogsTimer = Timer.periodic(
      _projectLogsInterval,
      (_) => unawaited(_probeProjectLogs()),
    );
    // Re-probe immediately when the offline manager flips back to available
    // so the dashboard recovers without waiting for the next timer tick.
    _availabilitySub = adminOfflineCacheManager.availabilityStream.listen((
      available,
    ) {
      if (available) {
        unawaited(_probeDatabase());
        unawaited(_probeQueue());
        unawaited(_probeStatusPage());
        unawaited(_probeProjectErrors());
        unawaited(_probeProjectLogs());
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
    _statusPageTimer?.cancel();
    _statusPageTimer = null;
    _projectErrorsTimer?.cancel();
    _projectErrorsTimer = null;
    _projectLogsTimer?.cancel();
    _projectLogsTimer = null;
    _socketCloseGraceTimer?.cancel();
    _socketCloseGraceTimer = null;
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
        _socketOpenActual = true;
        _socketCloseGraceTimer?.cancel();
        _socketCloseGraceTimer = null;
        _socketState = 'open';
        _socketEverConnected = true;
        _socketOpenedAt = DateTime.now();
        // Fresh reconnect: give the tick subscription a clean retry budget
        // and re-establish it if retries were exhausted while backgrounded.
        _tickChannelRetries = 0;
        if (_listeners > 0 && _tickChannel == null) _ensureTickChannel();
        _emit();
      });
      realtime.onClose((_) {
        _socketOpenActual = false;
        _socketCloseGraceTimer?.cancel();
        _socketCloseGraceTimer = null;
        // While the app is suspended the realtime client is killed by the
        // OS and auto-reconnects on resume. Never display 'closed' for
        // that — timers also expire during suspension and would fire on
        // resume before the client has had any time to reconnect.
        // Displayed state stays 'open'; the close grace is re-armed by the
        // resume handler instead.
        if (!_appInForeground) return;
        _armCloseGrace();
      });
    } catch (_) {
      // Realtime hooks are an enhancement; the periodic probes still run.
    }
  }

  /// Starts the close-grace countdown: 'closed' is only displayed after
  /// [_statusChangeGrace] of *foreground* time without a connection.
  void _armCloseGrace() {
    _socketCloseGraceTimer?.cancel();
    _socketCloseGraceTimer = Timer(_statusChangeGrace, () {
      _socketCloseGraceTimer = null;
      // Re-check: the app may have been backgrounded while the timer ran,
      // or the client may have reconnected.
      if (!_appInForeground || _socketOpenActual) return;
      _socketState = 'closed';
      _emit();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      // Revert any degradation that was tracked while nothing was on
      // screen (probe failures against the suspended network, grace that
      // expired invisibly) — the user must never see a verdict worse
      // than the one that was visible when they left.
      final before = _statusBeforeSuspension;
      _statusBeforeSuspension = null;
      if (before != null &&
          _severity(_lastShownStatus) > _severity(before)) {
        _lastShownStatus = before;
        _worseningSince = null;
      }
      // Drop any grace timer that may have expired (or be mid-flight)
      // around the suspension, then give the realtime client a full grace
      // window of foreground time to auto-reconnect before 'closed' can
      // be displayed — regardless of how long the app was backgrounded.
      _socketCloseGraceTimer?.cancel();
      _socketCloseGraceTimer = null;
      if (_listeners > 0 && !_socketOpenActual && _socketEverConnected) {
        _armCloseGrace();
      }
      // Snap the UI back to the reverted verdict immediately, then probe
      // so the display recovers to a fresh value instead of sitting on
      // whatever the suspended app last saw.
      if (_listeners > 0) {
        _emit();
        unawaited(_probeDatabase());
      }
    } else {
      // inactive / hidden / paused / detached: nothing is on screen.
      _appInForeground = false;
      _statusBeforeSuspension = _lastShownStatus;
      _socketCloseGraceTimer?.cancel();
      _socketCloseGraceTimer = null;
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
    if (!ok && !_appInForeground) {
      // The app is suspended and the OS has cut the network — a failed
      // probe here says nothing about Supabase. Keep the last known state;
      // the resume handler re-probes immediately.
      return;
    }
    _dbLastCheckedAt = DateTime.now();
    if (ok) {
      _dbOk = true;
      _dbEverSucceeded = true;
      _dbConsecutiveFailures = 0;
      _dbError = null;
      _dbLastOkAt = _dbLastCheckedAt;
      _dbLatencyMs = stopwatch.elapsedMilliseconds;
      _dbLatencyHistory.add(
        SystemHealthLatencySample(at: _dbLastCheckedAt!, ms: _dbLatencyMs!),
      );
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

  /// Polls `admin_get_health_errors()`: recent edge-function failures,
  /// cron task failures, and app-reported errors for THIS project. On
  /// failure the last known data is kept (same pattern as the queue probe).
  Future<void> _probeProjectErrors() async {
    if (_listeners == 0 || _projectErrorsProbeInFlight) return;
    _projectErrorsProbeInFlight = true;
    try {
      final res = await Supabase.instance.client
          .rpc('admin_get_health_errors')
          .timeout(const Duration(seconds: 8));
      if (res is! Map || _listeners == 0) return;
      final map = Map<String, dynamic>.from(res);
      int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      DateTime? asTime(Object? v) => v == null ? null : DateTime.tryParse('$v');
      final tasks = <String>[
        if (map['cron_last_failed_tasks'] is List)
          for (final t in map['cron_last_failed_tasks'] as List)
            '$t',
      ];
      _projectErrors = ProjectErrorsStatus(
        checkedAt: asTime(map['checked_at']) ?? DateTime.now(),
        edgeFailed15m: asInt(map['edge_failed_15m']),
        edgeLastFailedAt: asTime(map['edge_last_failed_at']),
        edgeLastError: map['edge_last_error']?.toString(),
        cronFailed1h: asInt(map['cron_failed_1h']),
        cronLastFailedAt: asTime(map['cron_last_failed_at']),
        cronLastFailedTasks: tasks,
        appErrors15m: asInt(map['app_errors_15m']),
        appLastErrorAt: asTime(map['app_last_error_at']),
        appLastSource: map['app_last_source']?.toString(),
        appLastMessage: map['app_last_message']?.toString(),
      );
      _emit();
    } catch (_) {
      // Informational; keep the last known value.
    } finally {
      _projectErrorsProbeInFlight = false;
    }
  }

  /// True when recent project failures exceed the alert thresholds —
  /// drives the overall banner (degraded only, never down).
  bool get _projectErrorsAlert => _projectErrors?.alert ?? false;

  /// Polls the `project-logs-health` edge function: sign-ins and auth
  /// failures (ClickHouse auth logs) plus disk/API usage (Management API).
  /// On failure the last known data is kept (same pattern as the queue
  /// probe); a `configured: false` response (no `SUPABASE_ACCESS_TOKEN`)
  /// is a valid state and replaces the last known value so the screen
  /// shows the setup hint instead of stale metrics.
  Future<void> _probeProjectLogs() async {
    if (_listeners == 0 || _projectLogsProbeInFlight) return;
    _projectLogsProbeInFlight = true;
    try {
      final res = await Supabase.instance.client.functions
          .invoke('project-logs-health')
          .timeout(const Duration(seconds: 25));
      if (_listeners == 0) return;
      var data = res.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {
          return;
        }
      }
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
      DateTime? asTime(Object? v) => v == null ? null : DateTime.tryParse('$v');
      final warnings = <String>[
        if (map['warnings'] is List)
          for (final w in map['warnings'] as List) '$w',
      ];
      _projectLogs = ProjectLogsStatus(
        checkedAt: asTime(map['checked_at']) ?? DateTime.now(),
        configured: map['configured'] == true,
        signins15m: asInt(map['signins_15m']),
        signinsLastAt: asTime(map['signins_last_at']),
        authErrors15m: asInt(map['auth_errors_15m']),
        authLastErrorAt: asTime(map['auth_last_error_at']),
        authLastErrorAction: map['auth_last_error_action']?.toString(),
        authLastErrorMessage: map['auth_last_error_message']?.toString(),
        diskUsedBytes: asInt(map['disk_used_bytes']),
        diskSizeBytes: asInt(map['disk_size_bytes']),
        diskAvailBytes: asInt(map['disk_avail_bytes']),
        apiRequestsCount: asInt(map['api_requests_count']),
        warnings: warnings,
      );
      _emit();
    } catch (_) {
      // Informational; keep the last known value.
    } finally {
      _projectLogsProbeInFlight = false;
    }
  }

  /// True when auth failures or disk usage exceed the alert thresholds —
  /// drives the overall banner (degraded only, never down).
  bool get _projectLogsAlert => _projectLogs?.alert ?? false;

  /// Polls Supabase's official Statuspage API (status.supabase.com). Two
  /// endpoints: summary (overall indicator + active incidents) and
  /// components (named platform components + per-region statuses).
  /// On failure the last known data is kept; [spAvailable] reflects the
  /// outcome of the most recent attempt.
  Future<void> _probeStatusPage() async {
    if (_listeners == 0 || _statusPageProbeInFlight) return;
    _statusPageProbeInFlight = true;
    try {
      // Full URLs, not Uri.resolve on the base: resolve() would treat 'v2'
      // as a file segment and replace it (…/api/summary.json → 404).
      final responses = await Future.wait([
        http
            .get(Uri.parse('https://status.supabase.com/api/v2/summary.json'))
            .timeout(const Duration(seconds: 8)),
        http
            .get(Uri.parse('https://status.supabase.com/api/v2/components.json'))
            .timeout(const Duration(seconds: 8)),
      ]);
      if (_listeners == 0) return;
      if (responses.any((r) => r.statusCode != 200)) {
        throw http.ClientException(
          'status page HTTP '
          '${responses.map((r) => r.statusCode).join('/')}',
        );
      }
      final summary = jsonDecode(responses[0].body);
      final components = jsonDecode(responses[1].body);
      if (summary is! Map || components is! Map) return;

      final status = summary['status'];
      _spIndicator = status is Map ? status['indicator']?.toString() : null;
      _spDescription = status is Map ? status['description']?.toString() : null;

      // Active incidents (summary only lists unresolved ones).
      final incidents = <SupabaseIncidentStatus>[];
      final rawIncidents = summary['incidents'];
      if (rawIncidents is List) {
        for (final item in rawIncidents) {
          if (item is! Map) continue;
          if (item['status']?.toString() == 'resolved') continue;
          DateTime? updated;
          try {
            updated = DateTime.tryParse(item['updated_at']?.toString() ?? '');
          } catch (_) {}
          // Statuspage uses 'name' for the incident title (and some pages
          // also expose 'title'); shortlink is often absent in summary.json.
          final title = (item['name'] ?? item['title'])?.toString() ?? '';
          final shortlink = item['shortlink']?.toString();
          incidents.add(
            SupabaseIncidentStatus(
              title: title,
              impact: item['impact']?.toString() ?? '',
              status: item['status']?.toString() ?? '',
              shortlink: (shortlink == null || shortlink.isEmpty)
                  ? 'https://status.supabase.com'
                  : shortlink,
              updatedAt: updated,
            ),
          );
        }
      }
      _spIncidents = incidents;

      // Components: named platform rows vs AWS-region rows. A region can
      // appear once per service; keep its worst status.
      final named = <SupabaseComponentStatus>[];
      final regionSeverity = <String, int>{};
      final rawComponents = components['components'];
      if (rawComponents is List) {
        for (final item in rawComponents) {
          if (item is! Map) continue;
          final name = item['name']?.toString() ?? '';
          final compStatus = item['status']?.toString() ?? 'operational';
          if (name.isEmpty) continue;
          if (_regionNamePattern.hasMatch(name)) {
            // Always record the region (even when operational, sev 0) so
            // the total is correct; keep its worst status across services.
            final sev = _componentSeverity(compStatus);
            regionSeverity.update(
              name,
              (prev) => sev > prev ? sev : prev,
              ifAbsent: () => sev,
            );
          } else if (item['group'] != true) {
            named.add(
              SupabaseComponentStatus(name: name, status: compStatus),
            );
          }
        }
      }
      _spComponents = named;
      _spRegionsTotal = regionSeverity.length;
      const sevToStatus = {
        1: 'maintenance',
        2: 'degraded_performance',
        3: 'partial_outage',
        4: 'major_outage',
      };
      _spAffectedRegions = [
        for (final entry in regionSeverity.entries)
          if (entry.value > 0)
            SupabaseComponentStatus(
              name: entry.key,
              status: sevToStatus[entry.value] ?? 'degraded_performance',
            ),
      ]..sort(
        (a, b) => _componentSeverity(b.status).compareTo(
          _componentSeverity(a.status),
        ),
      );

      _spAvailable = true;
      _spCheckedAt = DateTime.now();
      _emit();
    } catch (_) {
      // Keep the last known status-page data and its timestamp; only report
      // unavailable when nothing has ever been fetched successfully.
      _spAvailable = _spIndicator != null;
      _emit();
    } finally {
      _statusPageProbeInFlight = false;
    }
  }

  SystemHealthStatus _computeOverall() {
    final now = DateTime.now();

    // Official Supabase verdict takes priority: a major/critical incident
    // on their side is "down" regardless of what our probes see.
    final indicator = _spIndicator;
    if (indicator == 'major' || indicator == 'critical') {
      return SystemHealthStatus.down;
    }

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
    final openedAt = _socketOpenedAt;
    // Heartbeat staleness only counts once the socket has been open long
    // enough to have received a tick — right after (re)connect (e.g. app
    // resume) the previous tick is naturally old and must not alarm.
    if (tick != null &&
        openedAt != null &&
        now.difference(openedAt) > _heartbeatStaleAfter &&
        now.difference(tick) > _heartbeatStaleAfter) {
      degraded = true;
    }
    if (_queueHealth?['alert'] == true) degraded = true;
    if (_projectErrorsAlert) degraded = true;
    if (_projectLogsAlert) degraded = true;
    if (indicator == 'minor' || indicator == 'maintenance') degraded = true;

    if (degraded) return SystemHealthStatus.degraded;
    if (!_dbEverSucceeded) return SystemHealthStatus.checking;
    return SystemHealthStatus.healthy;
  }

  /// Applies the anti-flap grace window: worsening transitions must persist
  /// for [_statusChangeGrace] before being displayed; improvements pass
  /// through immediately. While a worsening is pending, the last confirmed
  /// status is held so brief transients (app resume, one failed probe) are
  /// invisible instead of flashing a neutral or alarming state.
  SystemHealthStatus _applyStatusGrace(SystemHealthStatus raw) {
    final now = DateTime.now();
    if (_severity(raw) <= _severity(_lastShownStatus)) {
      _worseningSince = null;
      _lastShownStatus = raw;
      return raw;
    }
    _worseningSince ??= now;
    if (now.difference(_worseningSince!) >= _statusChangeGrace) {
      _lastShownStatus = raw;
      return raw;
    }
    return _lastShownStatus;
  }

  void _emit() {
    if (_listeners == 0) return;
    _updatedAt = DateTime.now();
    _current = SystemHealthSnapshot(
      overall: _applyStatusGrace(_computeOverall()),
      dbOk: _dbOk,
      dbLatencyMs: _dbLatencyMs,
      dbLastCheckedAt: _dbLastCheckedAt,
      dbLastOkAt: _dbLastOkAt,
      dbConsecutiveFailures: _dbConsecutiveFailures,
      dbError: _dbError,
      dbLatencyHistory: List<SystemHealthLatencySample>.unmodifiable(
        _dbLatencyHistory,
      ),
      socketState: _socketState,
      socketEverConnected: _socketEverConnected,
      socketOpenedAt: _socketOpenedAt,
      lastTickAt: _lastTickAt,
      queueHealth: _queueHealth,
      queueCheckedAt: _queueCheckedAt,
      projectErrors: _projectErrors,
      projectLogs: _projectLogs,
      spIndicator: _spIndicator,
      spDescription: _spDescription,
      spComponents: List<SupabaseComponentStatus>.unmodifiable(_spComponents),
      spAffectedRegions: List<SupabaseComponentStatus>.unmodifiable(
        _spAffectedRegions,
      ),
      spRegionsTotal: _spRegionsTotal,
      spIncidents: List<SupabaseIncidentStatus>.unmodifiable(_spIncidents),
      spCheckedAt: _spCheckedAt,
      spAvailable: _spAvailable,
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
