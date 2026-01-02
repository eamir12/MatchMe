import 'dart:math';
import 'package:flutter/foundation.dart';

/// Lightweight diagnostic helper used only during investigation of resume/restart issues.
/// Keep this focused and easily removable.
class ResumeDiagnostics {
  // Disabled by default to avoid spamming logs. Use ResumeDiagnostics.setEnabled(true)
  // when actively debugging.
  static bool enabled = false;
  static final String runId = _generateRunId();

  static final Map<String, int> _lastLogMs = {};

  static String _generateRunId() {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rnd = Random().nextInt(9999).toString().padLeft(4, '0');
    return '$now-$rnd';
  }

  static void setEnabled(bool v) {
    enabled = v;
    debugPrint('[RESUME-DIAG][$runId][${DateTime.now().toIso8601String()}] Diagnostics ${v ? 'ENABLED' : 'DISABLED'}');
  }

  static void log(String message) {
    if (!enabled) return;
    final ts = DateTime.now().toIso8601String();
    debugPrint('[RESUME-DIAG][$runId][$ts] $message');
  }

  /// Log with a minimum interval per [category] to avoid flooding logs for
  /// frequently-occurring events. By default category is the message itself.
  static void logThrottled(String message, {String? category, int minIntervalMs = 1000}) {
    if (!enabled) return;
    final key = category ?? message;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastLogMs[key];
    if (last != null && (now - last) < minIntervalMs) return;
    _lastLogMs[key] = now;
    log(message);
  }
}
