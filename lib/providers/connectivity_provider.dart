// lib/providers/connectivity_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum ConnectivityHealthStatus { online, degraded, offline }

class ConnectivityHealth {
  final ConnectivityHealthStatus status;
  final bool hasNetworkTransport;
  final bool backendReachable;
  final int consecutiveProbeFailures;
  final int consecutiveProbeSuccesses;

  const ConnectivityHealth({
    required this.status,
    required this.hasNetworkTransport,
    required this.backendReachable,
    required this.consecutiveProbeFailures,
    required this.consecutiveProbeSuccesses,
  });

  bool get isOnline => status != ConnectivityHealthStatus.offline;
  bool get isBackendHealthy => status == ConnectivityHealthStatus.online;
}

class ConnectivityMonitorConfig {
  final Duration probeTimeout;
  final Duration healthyProbeInterval;
  final Duration suspectProbeInterval;
  final int degradedProbeFailures;
  final int offlineTransportFailures;
  final int onlineProbeSuccesses;

  const ConnectivityMonitorConfig({
    this.probeTimeout = const Duration(seconds: 5),
    this.healthyProbeInterval = const Duration(seconds: 10),
    this.suspectProbeInterval = const Duration(seconds: 3),
    this.degradedProbeFailures = 2,
    this.offlineTransportFailures = 2,
    this.onlineProbeSuccesses = 2,
  });
}

Future<bool> _checkInternetConnectivity(Duration timeout) async {
  try {
    final dynamic resp = await Supabase.instance.client.rpc('health_check').timeout(timeout);
    if (resp == null) return false;

    Map<String, dynamic>? m;
    if (resp is Map) {
      try {
        m = Map<String, dynamic>.from(resp);
      } catch (_) {
        m = null;
      }
    }

    if (m != null) {
      final dynamic okVal = m['ok'];
      if (okVal is bool) return okVal;
      if (okVal is String) return okVal.toLowerCase() == 'true';
      return false;
    }

    if (resp is bool) return resp;

    return false;
  } catch (_) {
    return false;
  }
}

Future<ConnectivityHealth> getCurrentConnectivityHealth({
  ConnectivityMonitorConfig config = const ConnectivityMonitorConfig(),
}) async {
  final initialResults = await Connectivity().checkConnectivity();
  final hasTransport = !initialResults.contains(ConnectivityResult.none);
  if (!hasTransport) {
    return const ConnectivityHealth(
      status: ConnectivityHealthStatus.offline,
      hasNetworkTransport: false,
      backendReachable: false,
      consecutiveProbeFailures: 0,
      consecutiveProbeSuccesses: 0,
    );
  }
  final backendReachable = await _checkInternetConnectivity(config.probeTimeout);
  return ConnectivityHealth(
    status: backendReachable
        ? ConnectivityHealthStatus.online
        : ConnectivityHealthStatus.degraded,
    hasNetworkTransport: true,
    backendReachable: backendReachable,
    consecutiveProbeFailures: backendReachable ? 0 : 1,
    consecutiveProbeSuccesses: backendReachable ? 1 : 0,
  );
}

Stream<ConnectivityHealth> createConnectivityHealthStream({
  ConnectivityMonitorConfig config = const ConnectivityMonitorConfig(),
}) async* {
  final controller = StreamController<ConnectivityHealth>();
  bool disposed = false;
  int transportDownStreak = 0;
  int probeFailureStreak = 0;
  int probeSuccessStreak = 0;
  ConnectivityHealthStatus currentStatus = ConnectivityHealthStatus.degraded;
  String? lastSignature;
  Timer? probeTimer;
  bool probing = false;

  void safeAdd(ConnectivityHealth value) {
    if (disposed || controller.isClosed) return;
    final signature =
        '${value.status.name}|${value.hasNetworkTransport}|${value.backendReachable}|${value.consecutiveProbeFailures}|${value.consecutiveProbeSuccesses}';
    if (signature == lastSignature) return;
    lastSignature = signature;
    try {
      controller.add(value);
    } catch (_) {}
  }

  void scheduleNextProbe(Duration interval, Future<void> Function() run) {
    probeTimer?.cancel();
    probeTimer = Timer(interval, () {
      run();
    });
  }

  Future<void> sample([List<ConnectivityResult>? transportResults]) async {
    if (disposed || probing) return;
    probing = true;
    try {
      final results = transportResults ?? await Connectivity().checkConnectivity();
      final hasTransport = !results.contains(ConnectivityResult.none);
      bool backendReachable = false;

      if (!hasTransport) {
        transportDownStreak += 1;
        probeFailureStreak = 0;
        probeSuccessStreak = 0;
      } else {
        transportDownStreak = 0;
        backendReachable = await _checkInternetConnectivity(config.probeTimeout);
        if (backendReachable) {
          probeSuccessStreak += 1;
          probeFailureStreak = 0;
        } else {
          probeFailureStreak += 1;
          probeSuccessStreak = 0;
        }
      }

      if (!hasTransport &&
          transportDownStreak >= config.offlineTransportFailures) {
        currentStatus = ConnectivityHealthStatus.offline;
      } else if (hasTransport &&
          backendReachable &&
          probeSuccessStreak >= config.onlineProbeSuccesses) {
        currentStatus = ConnectivityHealthStatus.online;
      } else if (hasTransport &&
          (!backendReachable ||
              probeFailureStreak >= config.degradedProbeFailures)) {
        currentStatus = ConnectivityHealthStatus.degraded;
      }

      safeAdd(
        ConnectivityHealth(
          status: currentStatus,
          hasNetworkTransport: hasTransport,
          backendReachable: backendReachable,
          consecutiveProbeFailures: probeFailureStreak,
          consecutiveProbeSuccesses: probeSuccessStreak,
        ),
      );

      final nextInterval = currentStatus == ConnectivityHealthStatus.online
          ? config.healthyProbeInterval
          : config.suspectProbeInterval;
      scheduleNextProbe(nextInterval, sample);
    } finally {
      probing = false;
    }
  }

  final connectivitySubscription =
      Connectivity().onConnectivityChanged.listen((results) {
    sample(results);
  });

  unawaited(sample());

  yield* controller.stream;

  disposed = true;
  await connectivitySubscription.cancel();
  probeTimer?.cancel();
  if (!controller.isClosed) {
    await controller.close();
  }
}

final connectivityHealthProvider = StreamProvider<ConnectivityHealth>((ref) {
  return createConnectivityHealthStream();
});

final connectivityProvider = StreamProvider<bool>((ref) {
  return createConnectivityHealthStream()
      .map((health) => health.isOnline)
      .distinct();
});
