// lib/providers/connectivity_provider.dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/connectivity_restore_coordinator.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/supabase_reachability.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';

enum ConnectivityHealthStatus { online, degraded, offline }

/// Wraps Connectivity().onConnectivityChanged.listen() defensively.
///
/// The event stream is a *hint* that something changed, used only to trigger
/// an immediate probe; it never decides online/offline. That verdict comes
/// from Supabase reachability alone (see `supabase_reachability.dart`):
/// Supabase is the source of truth for everything this app shows, so a device
/// that cannot complete a round trip with it is offline no matter what the
/// platform transport reports.
///
/// On Windows, connectivity_plus's NetworkManager::StartListen can fail with
/// E_INVALIDARG (-2147024809) when the platform thread is inside certain
/// input-synchronous windows (COM rejects the outgoing Advise). The Dart
/// framework surfaces that as a PlatformException thrown during stream
/// activation, which — with no error handler — becomes an uncaught
/// exception that crashes the app. Connectivity is non-critical: the
/// monitor probes Supabase on its own timer, so a failed event stream
/// just means we lose change notifications.
StreamSubscription<List<ConnectivityResult>>? listenConnectivityChanged(
  void Function(List<ConnectivityResult> results) onData,
) {
  try {
    return Connectivity().onConnectivityChanged.listen(
      onData,
      onError: (e) => debugPrint('🌐 [CONNECTIVITY] Event stream error: $e'),
      cancelOnError: false,
    );
  } catch (e) {
    debugPrint(
      '🌐 [CONNECTIVITY] Failed to start connectivity event stream: $e',
    );
    return null;
  }
}

class ConnectivityHealth {
  final ConnectivityHealthStatus status;

  /// The only status input: a completed round trip with Supabase.
  final bool backendReachable;

  /// Last probe failure text, for diagnostics.
  final String? lastProbeDetail;
  final int consecutiveProbeFailures;
  final int consecutiveProbeSuccesses;

  const ConnectivityHealth({
    required this.status,
    required this.backendReachable,
    this.lastProbeDetail,
    this.consecutiveProbeFailures = 0,
    this.consecutiveProbeSuccesses = 0,
  });

  bool get isOnline => backendReachable;
  bool get isBackendHealthy => backendReachable;
  bool get isUiOnline => status != ConnectivityHealthStatus.offline;

  String describe() {
    return '${status.name}(supabase:$backendReachable,failures:$consecutiveProbeFailures,successes:$consecutiveProbeSuccesses'
        '${lastProbeDetail == null ? '' : ',last:$lastProbeDetail'})';
  }
}

class ConnectivityMonitorConfig {
  final Duration probeTimeout;
  final Duration healthyProbeInterval;
  final Duration suspectProbeInterval;
  final Duration offlineReprobeInterval;
  final Duration transientFailureProbeInterval;
  final Duration offlineGracePeriod;
  final Duration resumeGracePeriod;
  final Duration backgroundProbeInterval;
  final Duration backgroundOfflineGracePeriod;
  final int offlineProbeFailures;
  final int onlineProbeSuccesses;

  const ConnectivityMonitorConfig({
    this.probeTimeout = kSupabaseProbeTimeout,
    this.healthyProbeInterval = const Duration(seconds: 10),
    this.suspectProbeInterval = const Duration(seconds: 2),
    this.offlineReprobeInterval = const Duration(seconds: 5),
    this.transientFailureProbeInterval = const Duration(seconds: 3),
    this.offlineGracePeriod = const Duration(seconds: 20),
    this.resumeGracePeriod = const Duration(seconds: 12),
    this.backgroundProbeInterval = const Duration(seconds: 20),
    this.backgroundOfflineGracePeriod = const Duration(seconds: 60),
    this.offlineProbeFailures = 4,
    this.onlineProbeSuccesses = 2,
  });
}

void _connectivityLog(String message) =>
    debugPrint('🌐 [CONNECTIVITY] $message');

Future<ConnectivityHealth> getCurrentConnectivityHealth({
  ConnectivityMonitorConfig config = const ConnectivityMonitorConfig(),
}) async {
  final probe = await probeSupabaseReachability(
    timeout: config.probeTimeout,
    log: _connectivityLog,
  );
  if (probe.isUnreachable) {
    return ConnectivityHealth(
      status: ConnectivityHealthStatus.offline,
      backendReachable: false,
      lastProbeDetail: probe.toString(),
    );
  }
  return const ConnectivityHealth(
    status: ConnectivityHealthStatus.online,
    backendReachable: true,
    consecutiveProbeSuccesses: 1,
  );
}

Stream<ConnectivityHealth> createConnectivityHealthStream({
  ConnectivityMonitorConfig config = const ConnectivityMonitorConfig(),
}) {
  debugPrint('🌐 [CONNECTIVITY] createConnectivityHealthStream: STARTING');
  bool disposed = false;
  int failureStreak = 0;
  int probeSuccessStreak = 0;
  ConnectivityHealthStatus currentStatus = ConnectivityHealthStatus.degraded;
  ConnectivityHealthStatus? lastEmittedStatus;
  String? lastSignature;
  Timer? probeTimer;
  bool probing = false;

  /// Screen off / background: probe less often but do not stop (screen off != offline).
  bool backgroundMode = false;
  AppLifecycleListener? appLifecycleListener;
  DateTime? lastBackendHealthyAt;
  DateTime? lastResumeAt;
  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;

  final controller = StreamController<ConnectivityHealth>(
    onCancel: () {
      debugPrint('🌐 [CONNECTIVITY] Stream onCancel - cleaning up');
      disposed = true;
      probeTimer?.cancel();
      appLifecycleListener?.dispose();
      connectivitySubscription?.cancel();
    },
  );

  void safeAdd(ConnectivityHealth value) {
    if (disposed || controller.isClosed) return;
    // Dedup on semantic connectivity only (status + Supabase reachability).
    // The streak counters increment on EVERY successful probe, so including
    // them here emitted a new event on each probe (every 10s when healthy,
    // plus immediately on every app resume / window focus). Each emission
    // fanned out to connectivityProvider, ad providers and dashboard stats,
    // rebuilding the home screen for no visible change — a constant source
    // of "twitching" when switching windows on web.
    final signature = '${value.status.name}|${value.backendReachable}';
    if (signature == lastSignature) return;
    lastSignature = signature;
    try {
      if (value.status == ConnectivityHealthStatus.online &&
          lastEmittedStatus != ConnectivityHealthStatus.online) {
        ConnectivityRestoreCoordinator.instance.scheduleRestore(
          reason: 'connectivity-online',
        );
      }
      lastEmittedStatus = value.status;
      controller.add(value);
      // Symmetric, probe-driven recovery: a completed Supabase round trip is
      // proof of life, so flip OfflineCacheManager back online immediately
      // instead of waiting for a health-stream transition + sync round.
      if (value.backendReachable) {
        OfflineCacheManager.instance.setSupabaseAvailability(true);
      }
    } catch (_) {}
  }

  void scheduleNextProbe(Duration interval, Future<void> Function() run) {
    probeTimer?.cancel();
    probeTimer = Timer(interval, () {
      run();
    });
  }

  bool shouldDelayOfflineTransition(
    DateTime now, {
    bool backendReachable = false,
  }) {
    final withinResumeGrace =
        lastResumeAt != null &&
        now.difference(lastResumeAt!) < config.resumeGracePeriod &&
        !backendReachable;
    final offlineGrace = backgroundMode
        ? config.backgroundOfflineGracePeriod
        : config.offlineGracePeriod;
    final withinOfflineGrace =
        lastBackendHealthyAt != null &&
        now.difference(lastBackendHealthyAt!) < offlineGrace;
    return withinResumeGrace || withinOfflineGrace;
  }

  Duration probeIntervalForStatus({
    required ConnectivityHealthStatus status,
    required bool hasPendingFailures,
    int consecutiveFailures = 0,
  }) {
    // Exponential backoff: double interval for every 3 consecutive failures,
    // capped at 60s. This prevents aggressive re-probing when the backend
    // is genuinely down (e.g. deployment, DNS failure).
    Duration applyBackoff(Duration base) {
      if (consecutiveFailures < 3) return base;
      final multiplier =
          1 << ((consecutiveFailures - 3) ~/ 3); // 1x, 2x, 4x, 8x...
      final backedOff = base * multiplier;
      return backedOff > const Duration(seconds: 60)
          ? const Duration(seconds: 60)
          : backedOff;
    }

    if (backgroundMode) {
      return applyBackoff(
        hasPendingFailures
            ? config.transientFailureProbeInterval
            : config.backgroundProbeInterval,
      );
    }
    if (status == ConnectivityHealthStatus.offline) {
      return applyBackoff(config.offlineReprobeInterval);
    }
    if (hasPendingFailures) {
      return applyBackoff(config.transientFailureProbeInterval);
    }
    if (status == ConnectivityHealthStatus.online) {
      return config.healthyProbeInterval;
    }
    return applyBackoff(config.suspectProbeInterval);
  }

  Future<void> sample() async {
    debugPrint(
      '🌐 [CONNECTIVITY] sample() called (disposed=$disposed probing=$probing background=$backgroundMode)',
    );
    if (disposed || probing) return;
    probing = true;
    try {
      // One Supabase round trip decides everything. The first failure after a
      // healthy state is confirmed with a second, larger-budget attempt: that
      // is the transition edge, and it is exactly where a merely slow network
      // must not be turned into a cached-mode app. Later samples in the same
      // streak skip the confirmation (a genuine outage is already established
      // and the extra request only doubles the cost while Supabase is down).
      final probe = await probeSupabaseReachability(
        timeout: config.probeTimeout,
        confirm: failureStreak == 0,
        log: _connectivityLog,
      );
      final backendReachable = probe.isReachable;

      if (backendReachable) {
        failureStreak = 0;
        probeSuccessStreak += 1;
      } else {
        failureStreak += 1;
        probeSuccessStreak = 0;
        // Do NOT pause Realtime here: a single slow/failed probe (Supabase
        // stall, cold start, mobile TLS) must not kill the chat WebSocket.
        // Realtime is paused below only once the monitor actually declares
        // the app offline. Pausing on the first failure disconnected chat
        // delivery for ~10-20s (2 successes + restore debounce to resume)
        // and produced the "one check for a really long time" symptom.
      }

      final now = DateTime.now();
      if (backendReachable) {
        lastBackendHealthyAt = now;
      }

      final wantsOffline = failureStreak >= config.offlineProbeFailures;

      if (wantsOffline) {
        final isWithinResumeGrace =
            lastResumeAt != null &&
            now.difference(lastResumeAt!) < config.resumeGracePeriod;
        final hasSingleFailureOnly = failureStreak == 1;

        if (isWithinResumeGrace && hasSingleFailureOnly) {
          currentStatus = ConnectivityHealthStatus.online;
          debugPrint(
            '🌐 [CONNECTIVITY] Assuming online during resume grace despite probe failure '
            '(failures=$failureStreak)',
          );
        } else {
          currentStatus =
              shouldDelayOfflineTransition(
                now,
                backendReachable: backendReachable,
              )
              ? ConnectivityHealthStatus.degraded
              : ConnectivityHealthStatus.offline;
        }
      } else if (backendReachable &&
          probeSuccessStreak >= config.onlineProbeSuccesses) {
        currentStatus = ConnectivityHealthStatus.online;
      } else if (backendReachable) {
        currentStatus = ConnectivityHealthStatus.degraded;
      } else {
        currentStatus = ConnectivityHealthStatus.degraded;
      }

      debugPrint(
        '🌐 [CONNECTIVITY] Emitting: status=${currentStatus.name} supabase=$backendReachable failures=$failureStreak',
      );

      // Pause Realtime only on a declared offline transition (after
      // offlineProbeFailures + grace), not on transient/degraded blips.
      // pauseAll is idempotent, so re-emitting offline is harmless.
      if (currentStatus == ConnectivityHealthStatus.offline) {
        SupabaseRealtimeManager.instance.pauseAll();
      }

      safeAdd(
        ConnectivityHealth(
          status: currentStatus,
          backendReachable: backendReachable,
          lastProbeDetail: probe.isUnreachable ? probe.toString() : null,
          consecutiveProbeFailures: failureStreak,
          consecutiveProbeSuccesses: probeSuccessStreak,
        ),
      );

      final hasPendingFailures = failureStreak > 0;
      final nextInterval = probeIntervalForStatus(
        status: currentStatus,
        hasPendingFailures: hasPendingFailures,
        consecutiveFailures: failureStreak,
      );
      scheduleNextProbe(nextInterval, sample);
    } catch (e) {
      if (!isExpectedOfflineFailure(e)) {
        debugPrint('🌐 [CONNECTIVITY] Probe error: $e');
      }
      if (!disposed) {
        scheduleNextProbe(config.transientFailureProbeInterval, sample);
      }
    } finally {
      probing = false;
    }
  }

  connectivitySubscription = listenConnectivityChanged((_) {
    // A transport change is only a reason to probe now; the probe itself
    // still has the last word on online/offline.
    sample();
  });

  appLifecycleListener = AppLifecycleListener(
    onPause: () {
      backgroundMode = true;
      debugPrint(
        '🌐 [CONNECTIVITY] App paused (screen off/background) - slower probes, staying active',
      );
      probeTimer?.cancel();
      unawaited(sample());
    },
    onHide: () {
      backgroundMode = true;
      debugPrint(
        '🌐 [CONNECTIVITY] App hidden - slower probes, staying active',
      );
      probeTimer?.cancel();
      unawaited(sample());
    },
    onResume: () {
      if (disposed) return;
      backgroundMode = false;
      lastResumeAt = DateTime.now();
      OfflineCacheManager.instance.noteAppResumed();
      debugPrint(
        '🌐 [CONNECTIVITY] App resumed - immediate reachability probe',
      );
      probeTimer?.cancel();
      unawaited(sample());
    },
  );

  unawaited(sample());
  debugPrint(
    '🌐 [CONNECTIVITY] createConnectivityHealthStream: returning stream',
  );
  return controller.stream;
}

final connectivityHealthProvider = StreamProvider<ConnectivityHealth>((ref) {
  return createConnectivityHealthStream();
});

/// Bumped whenever OfflineCacheManager.isSupabaseAvailable flips, so
/// connectivityProvider recomputes even when the health stream itself did
/// not emit (e.g. forks caused by a forced offline elsewhere).
class _AvailabilityVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state += 1;
}

final availabilityVersionProvider =
    NotifierProvider<_AvailabilityVersionNotifier, int>(
  _AvailabilityVersionNotifier.new,
);

final _availabilityBridgeProvider = Provider<void>((ref) {
  void bump(bool _) {
    ref.read(availabilityVersionProvider.notifier).bump();
  }

  OfflineCacheManager.instance.onAvailabilityChanged = bump;
  ref.onDispose(() {
    if (OfflineCacheManager.instance.onAvailabilityChanged == bump) {
      OfflineCacheManager.instance.onAvailabilityChanged = null;
    }
  });
});

final connectivityProvider = Provider<AsyncValue<bool>>((ref) {
  final prefs = ref.watch(userPreferencesProvider);
  OfflineCacheManager.instance.setForceOnline(prefs.backgroundMatchingMode);
  ref.watch(_availabilityBridgeProvider);
  ref.watch(availabilityVersionProvider);
  final healthAsync = ref.watch(connectivityHealthProvider);
  return healthAsync.whenData(
    (health) =>
        health.isOnline && OfflineCacheManager.instance.isSupabaseAvailable,
  );
});
