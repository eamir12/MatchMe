// lib/services/pinned_location_gate.dart
// Shared gate for EVERY GPS writer (Dart + native).
//
// While a pinned home-base location is active, no live location may be
// accessed or sent to Supabase. Only the online heartbeat continues.
//
// Contract across platforms. These constants are the RAW on-device keys
// (verbatim): native Android reads them from the FlutterSharedPreferences
// XML file and native iOS from UserDefaults, so they must match exactly
// what Dart stores on disk.
//
// CRITICAL SUBTLETY: the legacy SharedPreferences Dart API
// (SharedPreferences.getInstance, used here) prepends 'flutter.' to every
// key argument. That is why the constants below are intentionally
// UNPREFIXED — the stored raw keys come out as exactly
// 'flutter.pinned_location_active' etc. Older builds used 'flutter.'-prefixed
// constants here, which the legacy API stored as double-prefixed
// ('flutter.flutter.…') keys: readable by Dart, INVISIBLE to native code.
// Those legacy rows are migrated on first read (see below), so an active pin
// set by an older build keeps working after upgrade.
//   bool 'flutter.pinned_location_active' (raw)
//   int  'flutter.pinned_location_expires_at_ms' (epoch ms, UTC, raw)
//   String 'flutter.pinned_location_label' (optional, raw)
//
// The Dart provider (pinned_location_provider.dart) is the only writer of
// these keys. Every GPS tick path must call [isActive] first.

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PinnedLocationGate {
  static const String prefsActiveKey = 'pinned_location_active';
  static const String prefsExpiresAtMsKey = 'pinned_location_expires_at_ms';
  static const String prefsLabelKey = 'pinned_location_label';

  // Key arguments understood by pre-migration builds. Passed through the
  // same legacy API they resolve to the double-prefixed raw keys
  // ('flutter.flutter.pinned_location_active', …) that older builds wrote.
  // Read once for migration, then cleared.
  static const String _legacyActiveArg = 'flutter.pinned_location_active';
  static const String _legacyExpiresAtMsArg =
      'flutter.pinned_location_expires_at_ms';
  static const String _legacyLabelArg = 'flutter.pinned_location_label';

  static bool _migrationDone = false;

  /// One-time adoption of pins written by pre-migration builds. Idempotent
  /// and safe to call from every entry point; subsequent calls are a single
  /// boolean check.
  static Future<void> _migrateLegacyKeysIfNeeded() async {
    if (_migrationDone) return;
    _migrationDone = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(prefsActiveKey) == true) {
        await _clearLegacyKeys(prefs);
        return;
      }
      final legacyActive = prefs.getBool(_legacyActiveArg) ?? false;
      if (!legacyActive) {
        await _clearLegacyKeys(prefs);
        return;
      }
      final legacyExp = prefs.getInt(_legacyExpiresAtMsArg) ?? 0;
      if (legacyExp <= DateTime.now().toUtc().millisecondsSinceEpoch) {
        await _clearLegacyKeys(prefs);
        return;
      }
      final legacyLabel = prefs.getString(_legacyLabelArg);
      await prefs.setBool(prefsActiveKey, true);
      await prefs.setInt(prefsExpiresAtMsKey, legacyExp);
      if (legacyLabel != null && legacyLabel.trim().isNotEmpty) {
        await prefs.setString(prefsLabelKey, legacyLabel.trim());
      }
      _cachedActive = true;
      _cachedExpiresMs = legacyExp;
      await _clearLegacyKeys(prefs);
    } catch (_) {}
  }

  static Future<void> _clearLegacyKeys(SharedPreferences prefs) async {
    try {
      await prefs.setBool(_legacyActiveArg, false);
    } catch (_) {}
    try {
      await prefs.remove(_legacyExpiresAtMsArg);
    } catch (_) {}
    try {
      await prefs.remove(_legacyLabelArg);
    } catch (_) {}
  }

  // In-memory fallback so hot paths still gate correctly if prefs I/O fails.
  static bool _cachedActive = false;
  static int? _cachedExpiresMs;

  /// Local cache check. No GPS, no network. Expired entries self-clear so
  /// GPS resumes even before the next server reconcile.
  static Future<bool> isActive() async {
    try {
      await _migrateLegacyKeysIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getBool(prefsActiveKey) ?? false;
      if (!active) {
        _cachedActive = false;
        return false;
      }
      final exp = prefs.getInt(prefsExpiresAtMsKey) ?? 0;
      if (exp <= DateTime.now().toUtc().millisecondsSinceEpoch) {
        try {
          await prefs.setBool(prefsActiveKey, false);
        } catch (_) {}
        _cachedActive = false;
        _cachedExpiresMs = null;
        return false;
      }
      _cachedActive = true;
      _cachedExpiresMs = exp;
      return true;
    } catch (_) {
      return _cachedActive;
    }
  }

  /// Synchronous fast-path for very hot loops. Prefer [isActive] (it also
  /// self-clears expired entries). Unknown expiry is treated as active:
  /// fail closed, never leak GPS.
  static bool get isActiveCached {
    if (!_cachedActive) return false;
    final exp = _cachedExpiresMs;
    if (exp == null) return true;
    return exp > DateTime.now().toUtc().millisecondsSinceEpoch;
  }

  static Future<void> writePinCache({
    required DateTime expiresAt,
    String? label,
  }) async {
    _cachedActive = true;
    _cachedExpiresMs = expiresAt.toUtc().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsActiveKey, true);
      await prefs.setInt(prefsExpiresAtMsKey, _cachedExpiresMs!);
      if (label != null && label.trim().isNotEmpty) {
        await prefs.setString(prefsLabelKey, label.trim());
      } else {
        await prefs.remove(prefsLabelKey);
      }
      // Drop any pre-migration rows so a stale double-prefixed pin can
      // never be resurrected by a future migration pass.
      await _clearLegacyKeys(prefs);
    } catch (_) {}
  }

  static Future<void> clearPinCache() async {
    _cachedActive = false;
    _cachedExpiresMs = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsActiveKey, false);
      await prefs.remove(prefsExpiresAtMsKey);
      await prefs.remove(prefsLabelKey);
      // A lingering pre-migration active row would otherwise resurrect the
      // pin on the next migration pass after an upgrade.
      await _clearLegacyKeys(prefs);
    } catch (_) {}
  }

  /// Server truth (slow path, no GPS involved). Returns null when there is
  /// no signed-in user or the row cannot be read.
  static Future<
    ({
      bool active,
      DateTime? expiresAt,
      String? label,
      double? lat,
      double? lng,
    })?
  >
  fetchServerState() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return null;
      final row = await Supabase.instance.client
          .from('user_locations')
          .select('is_pinned,pinned_expires_at,pinned_label,latitude,longitude')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) {
        return (
          active: false,
          expiresAt: null,
          label: null,
          lat: null,
          lng: null,
        );
      }
      final exp = DateTime.tryParse(
        (row['pinned_expires_at'] ?? '').toString(),
      );
      final active =
          (row['is_pinned'] == true) &&
          exp != null &&
          exp.isAfter(DateTime.now().toUtc());
      return (
        active: active,
        expiresAt: exp,
        label: (row['pinned_label'] as String?)?.trim().isEmpty == true
            ? null
            : (row['pinned_label'] as String?)?.trim(),
        lat: (row['latitude'] as num?)?.toDouble(),
        lng: (row['longitude'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Read the locally cached pin label/expiry (memory + disk, no network).
  /// Used for instant UI startup; [isActive] should be checked first.
  static Future<({DateTime? expiresAt, String? label})> readCachePrefs() async {
    try {
      await _migrateLegacyKeysIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      final expMs = prefs.getInt(prefsExpiresAtMsKey);
      final label = prefs.getString(prefsLabelKey);
      DateTime? expiresAt;
      if (expMs != null && expMs > 0) {
        expiresAt = DateTime.fromMillisecondsSinceEpoch(expMs, isUtc: true);
      }
      return (
        expiresAt: expiresAt,
        label: label?.trim().isEmpty == true ? null : label?.trim(),
      );
    } catch (_) {
      return (expiresAt: null, label: null);
    }
  }
}
