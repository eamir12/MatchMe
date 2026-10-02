import 'dart:async';

import 'package:flutter/foundation.dart';

/// Debounces "back online" work so AppConfig, ads, match subscriptions, and
/// dashboard stats do not all refresh in the same frame.
class ConnectivityRestoreCoordinator {
  ConnectivityRestoreCoordinator._();

  static final ConnectivityRestoreCoordinator instance =
      ConnectivityRestoreCoordinator._();

  static const Duration _debounce = Duration(seconds: 2);

  final List<VoidCallback> _listeners = [];
  Timer? _debounceTimer;
  bool _pending = false;
  DateTime? _lastFiredAt;
  static const Duration _minFireInterval = Duration(seconds: 8);

  void Function() addListener(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void scheduleRestore({String reason = 'connectivity'}) {
    _pending = true;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _fireIfDue);
    if (kDebugMode) {
      debugPrint('[ConnectivityRestore] scheduled ($reason)');
    }
  }

  void _fireIfDue() {
    _debounceTimer = null;
    if (!_pending) return;

    final now = DateTime.now();
    if (_lastFiredAt != null &&
        now.difference(_lastFiredAt!) < _minFireInterval) {
      _debounceTimer = Timer(_minFireInterval, _fireIfDue);
      return;
    }

    _pending = false;
    _lastFiredAt = now;

    if (kDebugMode) {
      debugPrint(
        '[ConnectivityRestore] firing ${_listeners.length} listener(s)',
      );
    }

    final snapshot = List<VoidCallback>.from(_listeners);
    for (final listener in snapshot) {
      try {
        listener();
      } catch (e, st) {
        debugPrint('[ConnectivityRestore] listener error: $e\n$st');
      }
    }
  }

  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _listeners.clear();
    _pending = false;
  }
}
