import 'dart:async';
import 'package:geolocator/geolocator.dart';

/// Centralized deduplication for [Geolocator.getCurrentPosition] calls.
///
/// Multiple independent callers (timer ticks, screen mounts, location sharing)
/// can fire simultaneously, each triggering a separate GPS fix.  On mobile this
/// wastes battery; on web it produces the "7 getCurrentPosition calls in 16 s"
/// log flood.  This wrapper ensures that within [_dedupWindow] only one
/// browser/GPS request runs — subsequent callers receive the same result.
class LocationDeduplicator {
  LocationDeduplicator._();

  static DateTime? _lastRequestAt;
  static Completer<Position?>? _pendingRequest;
  static const Duration _dedupWindow = Duration(seconds: 10);

  /// Returns a position, deduplicating concurrent/recent requests.
  ///
  /// [label] is used for logging only (e.g. "timer", "refreshLocation",
  /// "locationShare").  [fetcher] is the actual call to
  /// [Geolocator.getCurrentPosition]; it is only invoked if no recent
  /// request is still in flight or within the dedup window.
  static Future<Position?> getPosition({
    required String label,
    required Future<Position?> Function() fetcher,
  }) async {
    final now = DateTime.now();

    // If a request is currently in-flight, share its result.
    if (_pendingRequest != null && !_pendingRequest!.isCompleted) {
      return _pendingRequest!.future;
    }

    // If a request completed recently, return its cached result.
    if (_lastRequestAt != null &&
        now.difference(_lastRequestAt!) < _dedupWindow) {
      // Return last known position as the best available cached result.
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return last;
      } catch (_) {}
    }

    // Start a new request.
    _lastRequestAt = now;
    _pendingRequest = Completer<Position?>();

    try {
      final position = await fetcher();
      if (!_pendingRequest!.isCompleted) {
        _pendingRequest!.complete(position);
      }
      return position;
    } catch (e) {
      if (!_pendingRequest!.isCompleted) {
        _pendingRequest!.complete(null);
      }
      return null;
    } finally {
      // Keep _pendingRequest alive for the dedup window so that callers
      // arriving within the window can share the completed result.
      Timer(_dedupWindow, () {
        _pendingRequest = null;
      });
    }
  }
}
