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
// The core tour is a ONE-TIME experience for the whole ACCOUNT, not for a
// device: the decision is taken from the account record (and, when the
// database provides it, from an atomic server-side claim), so switching
// devices can never show it a second time. When the account state cannot be
// established at all (offline, server error) the tour is NOT launched: a
// one-time tour that shows up twice is worse than one that shows up late —
// and it can always be replayed from Settings → App tour.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The outcome of the one-time core-tour launch decision.
enum CoreTourLaunchDecision {
  /// The account has never seen the tour — launch it now.
  launch,

  /// The tour was already seen, on this device or on another one.
  alreadySeen,

  /// The account state could not be established (offline, server error).
  ///
  /// The tour is not launched: a one-time tour must never be shown twice.
  unknown,
}

class OnboardingIntroService {
  OnboardingIntroService._internal();
  static final OnboardingIntroService instance =
      OnboardingIntroService._internal();

  static const String _prefsKeyPrefix = 'onboarding_intro_seen_';
  static const String _prefsKeyNoUser = 'onboarding_intro_seen';
  static const String _prefsSectionKeyPrefix = 'onboarding_section_seen_';
  static const String _serverColumn = 'onboarding_tour_state';
  static const int _stateVersion = 2;

  /// Server-side RPC that atomically claims the one-time core tour.
  ///
  /// Deployed by supabase/migrations/20262141000000_add_onboarding_tour_claim.sql.
  /// When the function is missing (the migration has not been applied yet) the
  /// service falls back to reading and writing the account record directly.
  static const String _claimRpc = 'claim_onboarding_core_tour';

  /// How long the claim may take before the account state counts as unknown.
  static const Duration _serverTimeout = Duration(seconds: 8);

  /// Accounts whose local state was already merged up to the server during
  /// this app run (successful or not — one attempt per run is enough).
  static final Set<String> _serverPushAttemptedUserIds = <String>{};

  /// In-memory server-state cache for this app run. `null` means the fetch
  /// either failed (offline) or found no stored state; either way we do not
  /// retry on every section visit.
  static final Map<String, Map<String, dynamic>?> _serverStateCache =
      <String, Map<String, dynamic>?>{};

  /// Accounts whose server state was fetched successfully during this run.
  static final Set<String> _serverStateFetched = <String>{};

  /// Accounts whose server-state fetch failed during this run. A failed
  /// fetch is retried once (the launch decision may not run on a guess).
  static final Set<String> _serverStateFetchFailed = <String>{};

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
  // Core tour (auto-run once per ACCOUNT, after profile completion).
  // -------------------------------------------------------------------------

  /// True when this device already consumed the core tour for [userId].
  ///
  /// The cheap, offline check: it never touches the network and it is what
  /// keeps the account lookup off the critical path for a returning member.
  Future<bool> hasSeenCoreTourLocally({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _readSeenFlag(prefs, _coreKeyFor(userId));
    } catch (_) {
      return false;
    }
  }

  /// Decides whether the one-time core tour may auto-launch for this account.
  ///
  /// The ACCOUNT is the unit of truth, not the device: a member who saw the
  /// tour on one device never sees it again on another one. The decision is
  /// therefore taken from the account record — and, where the database
  /// provides it, from an atomic server-side claim, so two devices racing
  /// for the very first launch cannot both win.
  ///
  /// When the account state cannot be established at all (offline, server
  /// error) the answer is [CoreTourLaunchDecision.unknown] and the tour is
  /// NOT launched: a one-time tour that shows up twice is worse than one
  /// that never shows up. It can always be replayed from Settings.
  Future<CoreTourLaunchDecision> decideCoreTourLaunch({
    String? userId,
  }) async {
    // 1. This device already consumed the tour — no network call needed.
    if (await hasSeenCoreTourLocally(userId: userId)) {
      // Make sure the account-level record exists so a fresh install of the
      // same account on another device stays quiet.
      unawaited(_backfillServerState(userId));
      return CoreTourLaunchDecision.alreadySeen;
    }

    // 2. Without an account there is nothing to claim and nothing to show.
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return CoreTourLaunchDecision.alreadySeen;

    final client = _client;
    if (client == null) return CoreTourLaunchDecision.unknown;

    // 3. Ask the account. The claim is atomic on the server.
    try {
      final granted = await client
          .rpc(_claimRpc)
          .timeout(_serverTimeout);
      if (granted is bool) {
        if (granted) {
          await _writeLocalCoreSeen(userId);
        }
        return granted
            ? CoreTourLaunchDecision.launch
            : CoreTourLaunchDecision.alreadySeen;
      }
      debugPrint(
        '[OnboardingIntro] Unexpected claim payload: ${granted.runtimeType}',
      );
    } catch (e) {
      if (!_isMissingRpcError(e)) {
        debugPrint('[OnboardingIntro] Core tour claim failed: $e');
        return CoreTourLaunchDecision.unknown;
      }
      // The claim RPC is not deployed yet — fall back to the account record.
    }

    return _decideCoreTourLaunchFromAccountRecord(userId, client);
  }

  /// Fallback for databases where the atomic claim RPC is not available yet:
  /// read the account record and, when the account has never seen the tour,
  /// claim it by writing the record.
  Future<CoreTourLaunchDecision> _decideCoreTourLaunchFromAccountRecord(
    String? userId,
    SupabaseClient client,
  ) async {
    final serverState = await _fetchServerState(userId, retryOnFailure: true);
    if (serverState == null) {
      // The account state is unknown (offline / server error). Never launch
      // a one-time tour on a guess.
      return CoreTourLaunchDecision.unknown;
    }
    final coreSeenAt = serverState['core_seen_at'];
    if (coreSeenAt is String && coreSeenAt.trim().isNotEmpty) {
      await _writeLocalCoreSeen(userId);
      return CoreTourLaunchDecision.alreadySeen;
    }
    // Never seen: claim it. The local flag is written first so the account
    // record carries it, then pushed. If the push does not land, the claim is
    // not durable — another device would launch the tour as well — so the
    // local flag is rolled back and the tour is not launched at all.
    await _writeLocalCoreSeen(userId);
    final claimed = await _pushServerState(userId);
    if (!claimed) {
      await _clearLocalCoreSeen(userId);
      return CoreTourLaunchDecision.unknown;
    }
    return CoreTourLaunchDecision.launch;
  }

  /// True when the error means "this RPC does not exist on the server".
  ///
  /// PostgREST answers an unknown function with PGRST202 / 404, which is the
  /// signal to fall back to the account record instead of failing the
  /// launch decision.
  bool _isMissingRpcError(Object error) {
    final text = error.toString();
    if (text.contains('PGRST202')) return true;
    if (text.contains('does not exist')) return true;
    if (text.contains('404')) return true;
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

  /// Rolls the local core flag back.
  ///
  /// Used when the account claim did not reach the server: the tour was not
  /// actually consumed, so this device must not consider it seen either.
  Future<void> _clearLocalCoreSeen(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_coreKeyFor(userId));
    } catch (_) {
      // Non-fatal.
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

  Future<Map<String, dynamic>?> _fetchServerState(
    String? userId, {
    bool retryOnFailure = false,
  }) async {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return null;
    if (_serverStateFetched.contains(id)) return _serverStateCache[id];
    if (!retryOnFailure && _serverStateFetchFailed.contains(id)) {
      return _serverStateCache[id];
    }
    _serverStateFetchFailed.remove(id);

    final client = _client;
    if (client == null) {
      _serverStateCache[id] = null;
      _serverStateFetchFailed.add(id);
      return null;
    }
    try {
      final row = await client
          .from('users')
          .select(_serverColumn)
          .eq('id', id)
          .maybeSingle()
          .timeout(_serverTimeout);
      final raw = row?[_serverColumn];
      final state = raw is Map ? Map<String, dynamic>.from(raw) : null;
      _serverStateCache[id] = state;
      _serverStateFetched.add(id);
      return state;
    } catch (e) {
      debugPrint('[OnboardingIntro] Server state read failed: $e');
      _serverStateCache[id] = null;
      _serverStateFetchFailed.add(id);
      return null;
    }
  }

  /// Pushes the local seen-state to the account, merging with whatever the
  /// server already recorded (seen is sticky — a stale device can never
  /// erase another device's progress). Skips the write when nothing changed.
  ///
  /// Returns whether the account record now holds the local state. A false
  /// result means the claim is NOT durable on the server, so the caller must
  /// not treat the tour as consumed for the whole account.
  Future<bool> _pushServerState(String? userId) async {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return false;
    final client = _client;
    if (client == null) return false;

    try {
      final local = await _readLocalState(userId);
      if (local == null) return false;

      Map<String, dynamic>? remote;
      try {
        final row = await client
            .from('users')
            .select(_serverColumn)
            .eq('id', id)
            .maybeSingle()
            .timeout(_serverTimeout);
        final raw = row?[_serverColumn];
        if (raw is Map) remote = Map<String, dynamic>.from(raw);
      } catch (_) {
        // Fall back to the cached copy when the fresh read fails.
        remote = _serverStateCache[id];
      }

      final merged = _mergeStates(remote, local);
      _serverStateCache[id] = merged;
      _serverStateFetched.add(id);
      _serverStateFetchFailed.remove(id);

      if (remote != null && _stateEquals(remote, merged)) return true;
      await client
          .from('users')
          .update({_serverColumn: merged})
          .eq('id', id)
          .timeout(_serverTimeout);
      return true;
    } catch (e) {
      debugPrint('[OnboardingIntro] Server state write failed: $e');
      return false;
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
