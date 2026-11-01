// Persisted last-good meet-up snapshot per (user, match).
//
// The meet-up provider is autoDispose (deliberate: it owns a realtime
// channel per match), which used to mean every screen entry started from
// zero and blocked the page on a full network loadSnapshot. This cache
// stores the last successful snapshot — an in-memory mirror for the sync
// fast path and an encrypted Hive box that survives restarts — so the
// meet-up screens hydrate instantly and refresh in the background, the
// same stale-while-revalidate pattern the chats and matches lists use.

import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/services/hive_encryption_service.dart';

/// One hydrated snapshot. Expired signals and spot cards are already
/// filtered out; the session is kept verbatim (ended sessions are shown
/// deliberately, and anything stale is corrected by the next refresh).
class MeetupCachedSnapshot {
  final MeetupSession? session;
  final List<MeetupLandmark> landmarks;
  final List<MeetupSignal> signals;
  final List<MeetupSpotCard> spotCards;

  const MeetupCachedSnapshot({
    required this.session,
    required this.landmarks,
    required this.signals,
    required this.spotCards,
  });
}

class MeetupSnapshotCache {
  MeetupSnapshotCache._();

  static final MeetupSnapshotCache instance = MeetupSnapshotCache._();

  static const String _boxName = 'meetup_snapshots';

  final Map<String, MeetupCachedSnapshot> _memory = {};
  Box<String>? _box;

  // Entries are keyed per user so an account switch on the same device
  // never reads another account's meetup data.
  String _key(String userId, String matchId) => '$userId:$matchId';

  /// Synchronous fast path for provider build(): the in-memory mirror of
  /// the last snapshot, or null on cold start.
  MeetupCachedSnapshot? peek(String userId, String matchId) {
    if (userId.isEmpty || matchId.isEmpty) return null;
    return _memory[_key(userId, matchId)];
  }

  /// Cold-start path: opens the encrypted box, reads the entry and warms
  /// the in-memory mirror. Returns null when nothing usable is stored.
  Future<MeetupCachedSnapshot?> load(String userId, String matchId) async {
    if (userId.isEmpty || matchId.isEmpty) return null;
    final key = _key(userId, matchId);
    final hot = _memory[key];
    if (hot != null) return hot;
    try {
      _box ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_boxName);
      final raw = _box!.get(key);
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return null;
      final snapshot = _decode(data);
      if (snapshot == null) return null;
      _memory[key] = snapshot;
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  /// Stores the last good snapshot. Fire-and-forget from the provider.
  Future<void> save({
    required String userId,
    required String matchId,
    required MeetupSession? session,
    required List<MeetupLandmark> landmarks,
    required List<MeetupSignal> signals,
    required List<MeetupSpotCard> spotCards,
  }) async {
    if (userId.isEmpty || matchId.isEmpty) return;
    final snapshot = _filter(
      session: session,
      landmarks: landmarks,
      signals: signals,
      spotCards: spotCards,
      currentUserId: userId,
    );
    _memory[_key(userId, matchId)] = snapshot;
    try {
      _box ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_boxName);
      await _box!.put(
        _key(userId, matchId),
        jsonEncode({
          'session': snapshot.session?.toJson(),
          'landmarks': snapshot.landmarks.map((e) => e.toJson()).toList(),
          'signals': snapshot.signals.map((e) => e.toJson()).toList(),
          'spot_cards': snapshot.spotCards.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Cache write failures must never break the meet-up flow.
    }
  }

  MeetupCachedSnapshot _filter({
    required MeetupSession? session,
    required List<MeetupLandmark> landmarks,
    required List<MeetupSignal> signals,
    required List<MeetupSpotCard> spotCards,
    required String currentUserId,
  }) {
    final liveSignals = signals
        .where((signal) => !signal.isExpired)
        .toList(growable: false);
    final liveCards = spotCards
        .where((card) {
          if (card.isDeleted || card.isExpired) return false;
          if (card.senderId == currentUserId) return true;
          return card.hiddenAt == null;
        })
        .toList(growable: false);
    return MeetupCachedSnapshot(
      session: session,
      landmarks: landmarks,
      signals: liveSignals,
      spotCards: liveCards,
    );
  }

  MeetupCachedSnapshot? _decode(Map<String, dynamic> data) {
    try {
      final sessionJson = data['session'];
      final landmarks = (data['landmarks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MeetupLandmark.fromJson)
          .toList(growable: false);
      final signals = (data['signals'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MeetupSignal.fromJson)
          .where((signal) => !signal.isExpired)
          .toList(growable: false);
      final spotCards = (data['spot_cards'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MeetupSpotCard.fromJson)
          .where((card) => !card.isDeleted && !card.isExpired)
          .toList(growable: false);
      return MeetupCachedSnapshot(
        session: sessionJson is Map<String, dynamic>
            ? MeetupSession.fromJson(sessionJson)
            : null,
        landmarks: landmarks,
        signals: signals,
        spotCards: spotCards,
      );
    } catch (_) {
      return null;
    }
  }

  /// Clears everything (logout / account switch).
  Future<void> clearAll() async {
    _memory.clear();
    try {
      _box ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_boxName);
      await _box!.clear();
    } catch (_) {
      // Best effort: the box is encrypted and keyed per user anyway.
    }
  }
}
