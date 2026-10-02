import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminSessionService {
  AdminSessionService._();

  static bool _explicitUserSignOut = false;

  static void markExplicitUserSignOut() {
    _explicitUserSignOut = true;
  }

  static bool consumeExplicitUserSignOutFlag() {
    final val = _explicitUserSignOut;
    _explicitUserSignOut = false;
    return val;
  }

  static const String _prefsSignOutReasonKey = 'admin_last_sign_out_reason';
  static const String _prefsPersistedSupabaseSessionKey =
      'admin_persisted_supabase_session';
  static const String _prefsSupabaseAuthTokenKey = 'supabase.auth.token';
  static const String _prefsSessionCreatedAtKey = 'admin_session_created_at';

  static bool _recoveredPersistedSessionThisLaunch = false;

  static bool get recoveredPersistedSessionThisLaunch =>
      _recoveredPersistedSessionThisLaunch;

  static bool _recoveryDisabled = false;

  static void disableRecovery() {
    _recoveryDisabled = true;
    _recoveredPersistedSessionThisLaunch = false;
  }

  static Future<void> persistSignOutReason({
    required String reason,
    String? source,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsSignOutReasonKey,
        jsonEncode({
          'reason': reason,
          'source': source,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> getLastSignOutReason() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsSignOutReasonKey);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setSessionCreatedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _prefsSessionCreatedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static Future<DateTime?> getSessionCreatedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_prefsSessionCreatedAtKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  static Future<void> persistCurrentSupabaseSessionSnapshot() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        await clearPersistedSupabaseSessionSnapshot();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsPersistedSupabaseSessionKey,
        jsonEncode({
          'currentSession': session.toJson(),
          'expiresAt': session.expiresAt,
        }),
      );
    } catch (_) {}
  }

  static Future<void> clearPersistedSupabaseSessionSnapshot() async {
    try {
      _recoveredPersistedSessionThisLaunch = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsPersistedSupabaseSessionKey);
      await prefs.remove(_prefsSupabaseAuthTokenKey);
      await prefs.remove(_prefsSignOutReasonKey);
      await prefs.remove(_prefsSessionCreatedAtKey);
    } catch (_) {}
  }

  /// Cooldown guard: prevents re-entry when [setInitialSession] triggers SDK
  /// token refresh which fails and fires a follow-up [signedOut] event,
  /// creating an infinite recovery loop.
  static DateTime? _lastRecoveryAttempt;

  static Future<bool> recoverPersistedSupabaseSession({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_recoveryDisabled) {
      return Supabase.instance.client.auth.currentSession != null;
    }
    if (_lastRecoveryAttempt != null &&
        DateTime.now().difference(_lastRecoveryAttempt!) <
            const Duration(seconds: 10)) {
      return Supabase.instance.client.auth.currentSession != null;
    }
    _lastRecoveryAttempt = DateTime.now();

    try {
      final existingSession = Supabase.instance.client.auth.currentSession;
      if (existingSession != null) return true;

      final prefs = await SharedPreferences.getInstance();
      final candidates = <String>[
        prefs.getString(_prefsPersistedSupabaseSessionKey)?.trim() ?? '',
        prefs.getString(_prefsSupabaseAuthTokenKey)?.trim() ?? '',
      ];

      for (final raw in candidates) {
        if (raw.isEmpty) continue;
        final sessionJson = _extractSupabaseSessionJson(raw);
        if (sessionJson == null) continue;

        try {
          await Supabase.instance.client.auth
              .recoverSession(raw)
              .timeout(timeout);
        } catch (_) {
          try {
            await Supabase.instance.client.auth
                .setInitialSession(sessionJson)
                .timeout(const Duration(seconds: 1));
          } catch (_) {}
        }

        final recoveredSession = Supabase.instance.client.auth.currentSession;
        if (recoveredSession == null) continue;

        _recoveredPersistedSessionThisLaunch = true;
        await persistCurrentSupabaseSessionSnapshot();
        return true;
      }

      return false;
    } catch (_) {
      return Supabase.instance.client.auth.currentSession != null;
    }
  }

  static String? _extractSupabaseSessionJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final currentSession = decoded['currentSession'];
      if (currentSession is Map<String, dynamic>) {
        return jsonEncode(currentSession);
      }
      final session = Session.fromJson(decoded);
      if (session == null) return null;
      return jsonEncode(session.toJson());
    } catch (_) {
      return null;
    }
  }
}
