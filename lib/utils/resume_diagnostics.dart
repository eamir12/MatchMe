import 'dart:math';
import 'package:matchme/services/app_config_service.dart';

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
  }

  static void log(String message) {
    // Logging disabled - no output
  }

  /// Log with a minimum interval per [category] to avoid flooding logs for
  /// frequently-occurring events. By default category is the message itself.
  static Future<void> logThrottled(
    String message, {
    String? category,
    int? minIntervalMs,
  }) async {
    if (!enabled) return;
    final configMinIntervalMs = await (() async {
      try {
        return await appConfigService.getInt(
          'ui.log_throttle_ms',
          defaultValue: 1000,
        );
      } catch (e) {
        return 1000;
      }
    })();
    final effectiveMinIntervalMs = minIntervalMs ?? configMinIntervalMs;
    final key = category ?? message;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastLogMs[key];
    if (last != null && (now - last) < effectiveMinIntervalMs) return;
    _lastLogMs[key] = now;
    log(message);
  }
}
