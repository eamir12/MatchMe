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

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PinnedLocationGate {
  static const String prefsActiveKey = 'pinned_location_active';
  static const String prefsExpiresAtMsKey = 'pinned_location_expires_at_ms';
  static const String prefsLabelKey = 'pinned_location_label';
  static const String _prefsCreatedAtMsKey = 'pinned_location_created_at_ms';
  static const String _pendingPinKey = 'pinned_location_pending_sync';

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
    DateTime? createdAt,
    String? label,
  }) async {
    _cachedActive = true;
    _cachedExpiresMs = expiresAt.toUtc().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsActiveKey, true);
      await prefs.setInt(prefsExpiresAtMsKey, _cachedExpiresMs!);
      if (createdAt != null) {
        await prefs.setInt(
          _prefsCreatedAtMsKey,
          createdAt.toUtc().millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove(_prefsCreatedAtMsKey);
      }
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
      await prefs.remove(_prefsCreatedAtMsKey);
      await prefs.remove(prefsLabelKey);
      await prefs.remove('pinned_location_latitude');
      await prefs.remove('pinned_location_longitude');
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
      DateTime? createdAt,
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
          .select('is_pinned,pinned_expires_at,pinned_created_at,pinned_label,latitude,longitude')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) {
        return (
          active: false,
          expiresAt: null,
          createdAt: null,
          label: null,
          lat: null,
          lng: null,
        );
      }
      final exp = DateTime.tryParse(
        (row['pinned_expires_at'] ?? '').toString(),
      );
      final created = DateTime.tryParse(
        (row['pinned_created_at'] ?? '').toString(),
      );
      final active =
          (row['is_pinned'] == true) &&
          exp != null &&
          exp.isAfter(DateTime.now().toUtc());
      return (
        active: active,
        expiresAt: exp,
        createdAt: created,
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
  static Future<({DateTime? expiresAt, DateTime? createdAt, String? label})>
  readCachePrefs() async {
    try {
      await _migrateLegacyKeysIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      final expMs = prefs.getInt(prefsExpiresAtMsKey);
      final createdMs = prefs.getInt(_prefsCreatedAtMsKey);
      final label = prefs.getString(prefsLabelKey);
      DateTime? expiresAt;
      if (expMs != null && expMs > 0) {
        expiresAt = DateTime.fromMillisecondsSinceEpoch(expMs, isUtc: true);
      }
      return (
        expiresAt: expiresAt,
        createdAt: createdMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(createdMs, isUtc: true),
        label: label?.trim().isEmpty == true ? null : label?.trim(),
      );
    } catch (_) {
      return (expiresAt: null, createdAt: null, label: null);
    }
  }

  /// Persist an offline pin request so it can be completed after reconnect,
  /// including after the app is restarted.
  static Future<void> writePendingPin({
    required String userId,
    required DateTime expiresAt,
    required DateTime createdAt,
    String? label,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _pendingPinKey,
      jsonEncode({
        'action': 'pin',
        'user_id': userId,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'label': label?.trim().isEmpty == true ? null : label?.trim(),
      }),
    );
  }

  /// Store an extension as a target expiry so retries are idempotent even if
  /// Supabase applied the previous request but its response was lost.
  static Future<void> writePendingExtension({
    required String userId,
    required DateTime expiresAt,
    required DateTime createdAt,
    required Duration extra,
    String? label,
  }) async {
    final existing = await readPendingPin();
    if (existing != null && existing.action == 'pin') {
      await writePendingPin(
        userId: userId,
        expiresAt: expiresAt,
        createdAt: existing.createdAt,
        label: label,
      );
      return;
    }
    final totalExtra = existing != null && existing.action == 'extend'
        ? existing.extraSeconds + extra.inSeconds
        : extra.inSeconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _pendingPinKey,
      jsonEncode({
        'action': 'extend',
        'user_id': userId,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'extra_seconds': totalExtra,
        'label': label?.trim().isEmpty == true ? null : label?.trim(),
      }),
    );
  }

  static Future<({
    String userId,
    String action,
    DateTime expiresAt,
    DateTime createdAt,
    String? label,
    int extraSeconds,
  })?> readPendingPin() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingPinKey);
    if (raw == null) return null;
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid pending pinned-location request');
    }
    final userId = json['user_id'];
    final expiresAt = DateTime.tryParse(json['expires_at']?.toString() ?? '');
    final parsedCreatedAt = DateTime.tryParse(
      json['created_at']?.toString() ?? '',
    );
    if (userId is! String ||
        userId.isEmpty ||
        expiresAt == null) {
      throw const FormatException('Invalid pending pinned-location request');
    }
    final action = json['action']?.toString() ?? 'pin';
    if (action != 'pin' && action != 'extend') {
      throw const FormatException('Invalid pending pinned-location action');
    }
    final extraSeconds = json['extra_seconds'];
    if (action == 'extend' &&
        (extraSeconds is! int || extraSeconds < 60)) {
      throw const FormatException('Invalid pending pinned-location extension');
    }
    final rawLabel = json['label'];
    return (
      userId: userId,
      action: action,
      expiresAt: expiresAt.toUtc(),
      createdAt:
          parsedCreatedAt?.toUtc() ??
          expiresAt.toUtc().subtract(const Duration(days: 14)),
      label: rawLabel is String && rawLabel.trim().isNotEmpty
          ? rawLabel.trim()
          : null,
      extraSeconds: action == 'extend' ? extraSeconds as int : 0,
    );
  }

  static Future<void> clearPendingPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingPinKey);
  }
}
