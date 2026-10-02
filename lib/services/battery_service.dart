import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Simple battery info model
class BatteryInfo {
  final int level; // 0-100
  final BatteryState state;

  BatteryInfo({required this.level, required this.state});
}

/// BatteryService polls battery level and listens for charging state changes.
/// Use [stream] to get updates whenever a change is detected.
class BatteryService {
  final Battery _battery = Battery();
  final StreamController<BatteryInfo> _controller =
      StreamController.broadcast();

  Timer? _pollTimer;
  int? _lastLevel;
  BatteryState? _lastState;
  bool _disposed = false;
  bool _started = false;
  _BatteryServiceLifecycleObserver? _lifecycleObserver;

  /// If [autoStart] is false (used by tests), the internal polling/listeners won't be started.
  BatteryService({bool autoStart = true}) {
    if (autoStart) _init();
    _attachLifecycleObserver();
  }
  Stream<BatteryInfo> get stream => _controller.stream;

  void _init() {
    if (_disposed || _started) return;
    unawaited(_pollOnce());
    _startPolling();
    _started = true;
  }

  Future<void> _pollOnce() async {
    if (_disposed) return;
    try {
      final level = (await _battery.batteryLevel).toInt();
      final state = await _battery.batteryState;
      _emitIfChanged(level, state);
    } catch (_) {}
  }

  void _startPolling() {
    if (_disposed) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final level = (await _battery.batteryLevel).toInt();
        final state = await _battery.batteryState;
        _emitIfChanged(level, state);
      } catch (e) {
        // ignore
        if (kDebugMode) print('BatteryService poll error: $e');
      }
    });
  }

  void _emitIfChanged(int level, BatteryState state) {
    if (_disposed) return;
    if (_lastLevel == level && _lastState == state) return;
    _lastLevel = level;
    _lastState = state;
    try {
      _controller.add(BatteryInfo(level: level, state: state));
    } catch (_) {}
  }

  void _attachLifecycleObserver() {
    if (_disposed) return;
    try {
      final binding = WidgetsBinding.instance;
      if (_lifecycleObserver != null) return;
      _lifecycleObserver = _BatteryServiceLifecycleObserver(
        onState: _handleLifecycleState,
      );
      binding.addObserver(_lifecycleObserver!);
    } catch (_) {}
  }

  void _handleLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _init();
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stop();
    }
  }

  void _stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _started = false;
  }

  Future<BatteryInfo> getBatteryInfo() async {
    final level = (await _battery.batteryLevel).toInt();
    final state = await _battery.batteryState;
    return BatteryInfo(level: level, state: state);
  }

  Future<bool> isBatteryLow({int threshold = 15}) async {
    try {
      final level = (await _battery.batteryLevel).toInt();
      return level <= threshold;
    } catch (_) {
      return false; // if we can't read it, assume not low
    }
  }

  Future<bool> isCharging() async {
    try {
      final state = await _battery.batteryState;
      return state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      if (_lifecycleObserver != null) {
        WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
      }
    } catch (_) {}
    _lifecycleObserver = null;
    _stop();
    _controller.close();
  }
}

/// Provider wrapper for BatteryService so other code can obtain the shared instance via Riverpod
final batteryServiceProvider = Provider<BatteryService>((ref) {
  final service = BatteryService();
  ref.onDispose(service.dispose);
  return service;
});

class _BatteryServiceLifecycleObserver extends WidgetsBindingObserver {
  final void Function(AppLifecycleState state) onState;
  _BatteryServiceLifecycleObserver({required this.onState});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onState(state);
  }
}
