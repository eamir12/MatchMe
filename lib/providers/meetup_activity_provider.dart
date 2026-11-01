// App-wide live/pending meet-up activity for the match cards.
//
// One aggregate RPC and one Realtime channel serve every match card, instead
// of opening a channel per match. Home and Matches both watch the same
// provider, so the indicator stays consistent across screens.
//
// The map is fail-closed: unknown matches and RPC errors show no indicator,
// and the last known map is kept while offline.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/meetup_activity.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/meetup_service.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final meetupActivityProvider =
    NotifierProvider.autoDispose<
      MeetupActivityNotifier,
      Map<String, MeetupActivity>
    >(MeetupActivityNotifier.new);

/// The activity for one card, or null when that match has nothing live.
final meetupActivityForMatchProvider = Provider.autoDispose
    .family<MeetupActivity?, String>((ref, matchId) {
      return ref.watch(meetupActivityProvider)[matchId];
    });

/// Inbox row kinds written for an incoming meet-up tool. Every tool event
/// lands in the inbox, so the unread row is what tells "not seen yet" apart
/// from "still live". Live location keeps its own older type.
const Set<String> _incomingToolInboxKinds = {
  'meetup_signal',
  'meetup_beacon',
  'meetup_spot',
  'meetup_proposal',
  'meetup_place_change',
  'location_share',
};

/// Matches whose other side has a live/pending tool the user has not seen
/// yet, for the Matches tab badge. This is the tab-level echo of the incoming
/// banners: an active meet-up is shared state rather than a new signal, and
/// your own tools never count.
///
/// Seen-ness comes from the inbox row every incoming tool writes: viewing the
/// tool (opening the chat, the hub or the inbox row) marks that row read, so
/// the badge clears then instead of staying set until the tool expires.
final incomingMeetupActivityCountProvider = Provider.autoDispose<int>((ref) {
  final activity = ref.watch(meetupActivityProvider);
  if (activity.isEmpty) return 0;

  final items = ref.watch(notificationInboxProvider).items;
  final unseenMatchIds = <String>{};
  for (final item in items) {
    if (item.readAt != null || item.deletedAt != null) continue;
    final kind = item.data['kind']?.toString() ?? item.type;
    if (!_incomingToolInboxKinds.contains(kind)) continue;
    final matchId =
        (item.data['matchId'] ?? item.data['match_id'])?.toString().trim() ??
        '';
    if (matchId.isNotEmpty) unseenMatchIds.add(matchId);
  }

  var count = 0;
  for (final entry in activity.entries) {
    final item = entry.value;
    if (item.topOwn ||
        item.topKind.isEmpty ||
        item.topKind == MeetupActivityKind.active) {
      continue;
    }
    if (unseenMatchIds.contains(entry.key)) count++;
  }
  return count;
});

class MeetupActivityNotifier extends Notifier<Map<String, MeetupActivity>> {
  final MeetupService _service = MeetupService();

  RealtimeChannel? _channel;
  String? _channelName;
  Timer? _reloadDebounce;
  Timer? _expiryTimer;
  bool _disposed = false;

  static const List<String> _realtimeTables = [
    'meetup_sessions',
    'meetup_signals',
    'meetup_spot_cards',
    'location_share_signals',
  ];

  @override
  Map<String, MeetupActivity> build() {
    ref.onDispose(() {
      _disposed = true;
      _reloadDebounce?.cancel();
      _reloadDebounce = null;
      _expiryTimer?.cancel();
      _expiryTimer = null;
      final channelName = _channelName;
      if (channelName != null) {
        SupabaseRealtimeManager.instance.unregister(channelName);
      }
      _channelName = null;
      _channel = null;
    });

    Future.microtask(() {
      if (_disposed) return;
      _startRealtime();
      _scheduleRefresh();
    });

    return const {};
  }

  void _startRealtime() {
    if (_disposed || _channel != null) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final channelName = 'meetup-activity:$userId';
    _channelName = channelName;

    // The manager owns the channel lifecycle: it re-creates this subscription
    // after an offline pause, and its restore path catches a socket that
    // dropped without the connectivity layer noticing.
    SupabaseRealtimeManager.instance.register(channelName, () {
      final channel = Supabase.instance.client.channel(channelName);
      for (final table in _realtimeTables) {
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          callback: (_) => _scheduleRefresh(),
        );
      }
      channel.subscribe((status, error) {
        if (_disposed) return;
        if (status == RealtimeSubscribeStatus.subscribed) _scheduleRefresh();
      });
      _channel = channel;
      return channel;
    });
  }

  void _scheduleRefresh() {
    if (_disposed) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_refresh()),
    );
  }

  Future<void> _refresh() async {
    if (_disposed || shouldSkipSupabaseCalls()) return;
    if (Supabase.instance.client.auth.currentUser == null) return;
    try {
      final activity = await _service.loadActivityByMatch();
      if (_disposed) return;
      state = activity;
      _scheduleExpiry(activity.values);
    } catch (_) {
      // Fail closed: keep the last known map so a transient error cannot
      // invent an indicator or make one disappear mid-use.
    }
  }

  /// Signals and proposals expire on a clock, while the cleanup job runs every
  /// ten minutes. Wake up at the nearest expiry so the chip clears on time.
  void _scheduleExpiry(Iterable<MeetupActivity> activity) {
    _expiryTimer?.cancel();
    _expiryTimer = null;

    DateTime? nearest;
    for (final item in activity) {
      final expiry = item.nextExpiry?.toUtc();
      if (expiry == null) continue;
      if (nearest == null || expiry.isBefore(nearest)) nearest = expiry;
    }
    if (nearest == null) return;

    final delay =
        nearest.difference(DateTime.now().toUtc()) + const Duration(seconds: 1);
    _expiryTimer = Timer(
      delay.isNegative ? const Duration(seconds: 1) : delay,
      () {
        if (!_disposed) unawaited(_refresh());
      },
    );
  }
}
