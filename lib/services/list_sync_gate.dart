import 'dart:math';

/// One list fetch decision: everything, or only rows newer than [since].
class ListSyncPlan {
  const ListSyncPlan.full() : since = null;

  const ListSyncPlan.delta(this.since);

  final String? since;

  bool get isFull => since == null;
}

/// Decides between a full list fetch and a watermark delta.
///
/// Startup must stay delta-only: a full reconcile is deferred a minute or two
/// into the session and jittered, so a mass app open does not send every
/// client's full list at once. Deletes are invisible to a watermark, and
/// profile edits do not bump the list row, so the reconcile still has to
/// happen once per [reconcileAfter].
class ListSyncGate {
  ListSyncGate({
    required this.kind,
    this.reconcileAfter = const Duration(hours: 24),
    this.deferredDelay = const Duration(seconds: 60),
    this.jitter = const Duration(seconds: 90),
    Random? random,
  }) : _random = random ?? Random(),
       assert(!jitter.isNegative);

  final String kind;
  final Duration reconcileAfter;
  final Duration deferredDelay;
  final Duration jitter;
  final Random _random;

  /// Per-manager (per app process) schedule; a new process starts clean.
  final Map<String, DateTime> _deferredFullAt = {};

  /// Shared prefix for every persisted cursor key, so sign-out can prune them
  /// without restating each [kind].
  static const keyPrefix = 'list_sync_v1_';

  String watermarkKey(String userId) => '$keyPrefix${kind}_watermark_$userId';

  String fullSyncAtKey(String userId) => '$keyPrefix${kind}_full_at_$userId';

  ListSyncPlan plan({
    required String userId,
    required String? watermark,
    required DateTime? lastFullAt,
    required DateTime now,
  }) {
    if (watermark == null || watermark.isEmpty) {
      return const ListSyncPlan.full();
    }
    final reconcileDue =
        lastFullAt == null || now.difference(lastFullAt) >= reconcileAfter;
    if (!reconcileDue) return ListSyncPlan.delta(watermark);

    final scheduled = _deferredFullAt[userId];
    if (scheduled == null) {
      final jitterSeconds = jitter.inSeconds == 0
          ? 0
          : _random.nextInt(jitter.inSeconds + 1);
      _deferredFullAt[userId] = now.add(
        deferredDelay + Duration(seconds: jitterSeconds),
      );
      return ListSyncPlan.delta(watermark);
    }
    if (now.isBefore(scheduled)) return ListSyncPlan.delta(watermark);
    _deferredFullAt.remove(userId);
    return const ListSyncPlan.full();
  }

  void reset(String userId) => _deferredFullAt.remove(userId);
}

/// Newest `updated_at` in a returned page, as the raw server string.
///
/// Keeping the raw value preserves the server's precision; re-encoding a
/// parsed timestamp can truncate or shift the microsecond part.
String? maxUpdatedAt(Iterable<dynamic> rows) {
  DateTime? newest;
  String? newestRaw;
  for (final row in rows) {
    if (row is! Map) continue;
    final raw = row['updated_at']?.toString();
    if (raw == null || raw.isEmpty) continue;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) continue;
    if (newest == null || parsed.isAfter(newest)) {
      newest = parsed;
      newestRaw = raw;
    }
  }
  return newestRaw;
}
