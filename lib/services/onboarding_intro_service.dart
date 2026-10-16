// Onboarding introduction tour persistence (device + account).
//
// Tracks which tour experiences a member already saw. Two layers:
//  * SharedPreferences (device-local, offline source of truth). The core tour
//    auto-runs once after the profile is complete (MainNavigationScreen checks
//    this on startup and right after the profile wizard finishes); section
//    tours are offered per section via OnboardingSectionPrompt. Finishing,
//    skipping or dismissing both mark the corresponding flag as seen.
//  * users.onboarding_tour_state (jsonb, account-level). Consulted when the
//    local device has no record (fresh install, new device) so the same
//    account never gets the tour auto-shown again on another device, and
//    written best-effort whenever a flag is consumed. Writes merge with the
//    remote copy (seen is sticky) so two devices racing can never un-see.
//
// The local flag is per account (two members sharing a device each get the
// tour on their first login). A null user id falls back to a shared
// device-level key; account-level sync is skipped without a user id.
//
// Failure policy is fail-open on reads (show the tour rather than never) and
// silent on writes (local prefs already recorded the state; the next launch
// backfills the server copy).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OnboardingIntroService {
  OnboardingIntroService._internal();
  static final OnboardingIntroService instance =
      OnboardingIntroService._internal();

  static const String _prefsKeyPrefix = 'onboarding_intro_seen_';
  static const String _prefsKeyNoUser = 'onboarding_intro_seen';
  static const String _prefsSectionKeyPrefix = 'onboarding_section_seen_';
  static const String _serverColumn = 'onboarding_tour_state';
  static const int _stateVersion = 2;

  /// Accounts whose local state was already merged up to the server during
  /// this app run (successful or not — one attempt per run is enough).
  static final Set<String> _serverPushAttemptedUserIds = <String>{};

  /// In-memory server-state cache for this app run. `null` means the fetch
  /// either failed (offline) or found no stored state; either way we do not
  /// retry on every section visit.
  static final Map<String, Map<String, dynamic>?> _serverStateCache =
      <String, Map<String, dynamic>?>{};
  static final Set<String> _serverStateFetchAttempted = <String>{};

  SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      // Supabase not initialized (tests, early bootstrap): local-only.
      return null;
    }
  }

  String _coreKeyFor(String? userId) {
    final id = userId?.trim() ?? '';
    return id.isEmpty ? _prefsKeyNoUser : '$_prefsKeyPrefix$id';
  }

  String _sectionKeyFor(String? userId, String sectionId) {
    final id = userId?.trim() ?? '';
    return id.isEmpty
        ? '$_prefsSectionKeyPrefix$sectionId'
        : '$_prefsSectionKeyPrefix${id}_$sectionId';
  }

  /// Reads a seen-flag that may be stored as a legacy `true` bool or as an
  /// ISO-8601 timestamp string (new writes). Never throws on type mismatch.
  bool _readSeenFlag(SharedPreferences prefs, String key) {
    final value = prefs.get(key);
    if (value is bool) return value;
    if (value is String) return value.trim().isNotEmpty;
    return false;
  }

  String? _readSeenAt(SharedPreferences prefs, String key) {
    final value = prefs.get(key);
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value == true) {
      // Legacy bool: the exact time is unknown. Stamp once and persist the
      // string form so retries (and future launches) push a stable value.
      final stamped = DateTime.now().toUtc().toIso8601String();
      unawaited(prefs.setString(key, stamped));
      return stamped;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Core tour (auto-run once after profile completion).
  // -------------------------------------------------------------------------

  /// True when the core introduction tour was already completed or skipped by
  /// this account on this device — or on any other device (server record).
  /// Storage failures resolve to `false` — the tour will simply be offered
  /// again rather than never.
  Future<bool> hasSeenIntro({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_readSeenFlag(prefs, _coreKeyFor(userId))) {
        // Local says seen: make sure the account-level record exists so a
        // fresh install of the same account on another device stays quiet.
        unawaited(_backfillServerState(userId));
        return true;
      }
    } catch (_) {}

    // No local record: this may still be the same account on a new device.
    final serverState = await _fetchServerState(userId);
    if (serverState != null && serverState['core_seen_at'] is String) {
      await _writeLocalCoreSeen(userId);
      return true;
    }
    return false;
  }

  /// Persists that the core tour was seen (completed or skipped), locally and
  /// (best-effort, merged) on the account.
  Future<void> markIntroSeen({String? userId}) async {
    await _writeLocalCoreSeen(userId);
    unawaited(_pushServerState(userId));
  }

  // -------------------------------------------------------------------------
  // Section tours (offered on first visit, replayable from Settings).
  // -------------------------------------------------------------------------

  /// True when this account already saw (or dismissed the offer for) the
  /// tour of [sectionId] — locally or on any other device.
  Future<bool> hasSeenSection(String sectionId, {String? userId}) async {
    final section = sectionId.trim();
    if (section.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_readSeenFlag(prefs, _sectionKeyFor(userId, section))) {
        return true;
      }
    } catch (_) {}

    final serverState = await _fetchServerState(userId);
    final sections = serverState?['sections'];
    if (sections is Map && sections[section] is String) {
      await _writeLocalSectionSeen(userId, section);
      return true;
    }
    return false;
  }

  /// Persists that the [sectionId] tour was seen, started or dismissed.
  Future<void> markSectionSeen(String sectionId, {String? userId}) async {
    final section = sectionId.trim();
    if (section.isEmpty) return;
    await _writeLocalSectionSeen(userId, section);
    unawaited(_pushServerState(userId));
  }

  // -------------------------------------------------------------------------
  // Local read/write helpers.
  // -------------------------------------------------------------------------

  Future<void> _writeLocalCoreSeen(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _coreKeyFor(userId);
      if (!_readSeenFlag(prefs, key)) {
        await prefs.setString(key, DateTime.now().toUtc().toIso8601String());
      }
    } catch (_) {
      // Non-fatal: the tour may repeat on the next launch.
    }
  }

  Future<void> _writeLocalSectionSeen(String? userId, String sectionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sectionKeyFor(userId, sectionId);
      if (!_readSeenFlag(prefs, key)) {
        await prefs.setString(key, DateTime.now().toUtc().toIso8601String());
      }
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Snapshot of the local seen-state in the server document shape. Only
  /// meaningful for a real account id (per-section keys are namespaced by it).
  Future<Map<String, dynamic>?> _readLocalState(String? userId) async {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final coreSeenAt = _readSeenAt(prefs, _coreKeyFor(userId));
      final sections = <String, String>{};
      final sectionPrefix = '$_prefsSectionKeyPrefix${id}_';
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(sectionPrefix)) continue;
        final section = key.substring(sectionPrefix.length);
        if (section.isEmpty) continue;
        final seenAt = _readSeenAt(prefs, key);
        if (seenAt != null) sections[section] = seenAt;
      }
      if (coreSeenAt == null && sections.isEmpty) return null;
      return {
        'version': _stateVersion,
        'core_seen_at': ?coreSeenAt,
        if (sections.isNotEmpty) 'sections': sections,
      };
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Server read/write (best-effort; never throws).
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>?> _fetchServerState(String? userId) async {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return null;
    if (_serverStateFetchAttempted.contains(id)) return _serverStateCache[id];
    _serverStateFetchAttempted.add(id);

    final client = _client;
    if (client == null) {
      _serverStateCache[id] = null;
      return null;
    }
    try {
      final row = await client
          .from('users')
          .select(_serverColumn)
          .eq('id', id)
          .maybeSingle();
      final raw = row?[_serverColumn];
      final state = raw is Map ? Map<String, dynamic>.from(raw) : null;
      _serverStateCache[id] = state;
      return state;
    } catch (e) {
      debugPrint('[OnboardingIntro] Server state read failed: $e');
      _serverStateCache[id] = null;
      return null;
    }
  }

  /// Pushes the local seen-state to the account, merging with whatever the
  /// server already recorded (seen is sticky — a stale device can never
  /// erase another device's progress). Skips the write when nothing changed.
  Future<void> _pushServerState(String? userId) async {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return;
    final client = _client;
    if (client == null) return;

    try {
      final local = await _readLocalState(userId);
      if (local == null) return;

      Map<String, dynamic>? remote;
      try {
        final row = await client
            .from('users')
            .select(_serverColumn)
            .eq('id', id)
            .maybeSingle();
        final raw = row?[_serverColumn];
        if (raw is Map) remote = Map<String, dynamic>.from(raw);
      } catch (_) {
        // Fall back to the cached copy when the fresh read fails.
        remote = _serverStateCache[id];
      }

      final merged = _mergeStates(remote, local);
      _serverStateCache[id] = merged;
      _serverStateFetchAttempted.add(id);

      if (remote != null && _stateEquals(remote, merged)) return;
      await client.from('users').update({_serverColumn: merged}).eq('id', id);
    } catch (e) {
      debugPrint('[OnboardingIntro] Server state write failed: $e');
    }
  }

  /// One merge attempt per app run for accounts whose local state says "seen"
  /// (covers accounts that saw the tour before the server column existed).
  Future<void> _backfillServerState(String? userId) async {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return;
    if (_serverPushAttemptedUserIds.contains(id)) return;
    _serverPushAttemptedUserIds.add(id);
    await _pushServerState(userId);
  }

  Map<String, dynamic> _mergeStates(
    Map<String, dynamic>? remote,
    Map<String, dynamic> local,
  ) {
    final mergedSections = <String, dynamic>{};
    final remoteSections = remote?['sections'];
    if (remoteSections is Map) {
      remoteSections.forEach((key, value) {
        if (value is String && value.trim().isNotEmpty) {
          mergedSections[key.toString()] = value;
        }
      });
    }
    final localSections = local['sections'];
    if (localSections is Map) {
      localSections.forEach((key, value) {
        if (value is String && value.trim().isNotEmpty) {
          mergedSections.putIfAbsent(key.toString(), () => value);
        }
      });
    }

    final remoteCore = remote?['core_seen_at'];
    final localCore = local['core_seen_at'];
    final coreSeenAt = remoteCore is String && remoteCore.trim().isNotEmpty
        ? remoteCore
        : (localCore is String && localCore.trim().isNotEmpty
              ? localCore
              : null);

    return {
      'version': _stateVersion,
      'core_seen_at': ?coreSeenAt,
      if (mergedSections.isNotEmpty) 'sections': mergedSections,
    };
  }

  bool _stateEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    bool valueEquals(dynamic x, dynamic y) {
      if (x is Map && y is Map) {
        if (x.length != y.length) return false;
        for (final entry in x.entries) {
          if (!y.containsKey(entry.key)) return false;
          if (!valueEquals(entry.value, y[entry.key])) return false;
        }
        return true;
      }
      return x == y;
    }

    return valueEquals(a, b);
  }
}
