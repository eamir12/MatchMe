// App-wide view of live meet-up tool alerts across every match.
//
// The inbox realtime channel already delivers one row per tool event
// (wave, beacon, Spot card, proposal, place-change request) with the
// recipient's localized title/body, so this notifier only filters, ages and
// groups those rows — and drops the OS cards for the events that stopped being
// news. Nothing here requests or stores location.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/mobile_local_notification_service.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:matchme/utils/meetup_alert_card.dart';

export 'package:matchme/utils/meetup_alert_card.dart'
    show
        kMeetupAlertBeacon,
        kMeetupAlertKinds,
        kMeetupAlertPlaceChange,
        kMeetupAlertProposal,
        kMeetupAlertSignal,
        kMeetupAlertSpot;

class MeetupAlert {
  final String id;
  final String matchId;
  final String senderId;
  final String kind;
  final String gesture;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime expiresAt;

  const MeetupAlert({
    required this.id,
    required this.matchId,
    required this.senderId,
    required this.kind,
    required this.gesture,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.expiresAt,
  });
}

class MeetupAlertsState {
  final List<MeetupAlert> alerts;
  final DateTime now;

  const MeetupAlertsState({this.alerts = const [], required this.now});

  MeetupAlert? get latest => alerts.isEmpty ? null : alerts.first;

  Map<String, MeetupAlert> get latestByMatch {
    final byMatch = <String, MeetupAlert>{};
    for (final alert in alerts) {
      byMatch.putIfAbsent(alert.matchId, () => alert);
    }
    return byMatch;
  }
}

/// What one pass over the inbox says the OS cards and the unread state are
/// allowed to forget. Pure, so the rule can be read and tested on its own.
class MeetupAlertCardPlan {
  const MeetupAlertCardPlan({
    required this.dismissed,
    required this.staleIds,
    required this.unreadIds,
    required this.dismissedIds,
  });

  /// Rows whose card is no longer news: the recipient read or removed the row,
  /// or its live window closed with nobody acting on it.
  final List<NotificationInboxItem> dismissed;

  /// Unread rows past their live window. Settling them as read is what clears
  /// the app-icon, bell and Matches badges: nothing on the server expires an
  /// unread tool row (`cleanup_expired_meetups` deletes the live tool rows and
  /// leaves the inbox alone), so the row would keep counting forever.
  final List<String> staleIds;

  /// Rows still unread and still news — the baseline the next pass compares
  /// against to notice that one of them was seen.
  final Set<String> unreadIds;

  /// Rows whose card this process has already dropped, still present in the
  /// inbox. Hand it back as `alreadyDismissedIds` on the next pass.
  final Set<String> dismissedIds;
}

MeetupAlertCardPlan planMeetupAlertCards({
  required List<NotificationInboxItem> items,
  required Map<String, Duration> ttl,
  required Set<String> previouslyUnreadIds,
  required Set<String> alreadyDismissedIds,
  required DateTime now,
}) {
  final dismissed = <NotificationInboxItem>[];
  final staleIds = <String>[];
  final unreadIds = <String>{};
  // Passing over a row twice is the normal case (the inbox, the ticker and the
  // config read all re-run the sweep), and the write that settles a stale row
  // lands asynchronously. Without this memory every re-pass would drop the
  // same card again and re-issue the same read update.
  final carried = <String>{};
  for (final row in items) {
    final alreadyDropped = alreadyDismissedIds.contains(row.id);
    if (alreadyDropped) carried.add(row.id);
    final kind = row.data['kind']?.toString() ?? row.type;
    if (row.deletedAt != null || row.readAt != null) {
      // Seen (or swiped away) since the last pass: the event it announced is
      // over, so its card goes with it. A row the server superseded is the
      // exception: a newer signal replaced it, which is what should clear the
      // bell, not a reason to withdraw a card for something that did happen.
      if (!alreadyDropped &&
          previouslyUnreadIds.contains(row.id) &&
          ttl.containsKey(kind) &&
          row.data['superseded'] != true) {
        dismissed.add(row);
        carried.add(row.id);
      }
      continue;
    }
    final window = ttl[kind];
    if (window == null) continue;
    if (row.createdAt.add(window).isAfter(now)) {
      unreadIds.add(row.id);
      continue;
    }
    if (alreadyDropped) continue;
    dismissed.add(row);
    staleIds.add(row.id);
    carried.add(row.id);
  }
  return MeetupAlertCardPlan(
    dismissed: dismissed,
    staleIds: staleIds,
    unreadIds: unreadIds,
    dismissedIds: carried,
  );
}

class MeetupAlertsNotifier extends Notifier<MeetupAlertsState> {
  Timer? _ticker;
  Map<String, Duration> _ttl = kMeetupAlertDefaultTtl;
  bool _ttlLoaded = false;

  /// Unread tool rows seen by the previous pass. A row that leaves that set was
  /// read or deleted — the recipient saw the tool — so its OS card goes too.
  Set<String> _unreadToolRowIds = const {};

  /// Tool rows whose OS card this process already dropped. Ids leave it when
  /// the row itself leaves the inbox.
  Set<String> _dismissedToolRowIds = const {};

  @override
  MeetupAlertsState build() {
    // This callback also runs when the provider rebuilds (inbox changes), not
    // only on final dispose. Clearing the field lets _syncTicker restart the
    // ticker in the rebuild; leaving it set would make the banner's countdown
    // and expiry freeze for good after the first inbox update.
    ref.onDispose(() {
      _ticker?.cancel();
      _ticker = null;
    });
    final items = ref.watch(notificationInboxProvider).items;
    if (!_ttlLoaded) {
      _loadTtl();
    }
    final now = DateTime.now();
    final alerts = _activeAlerts(items, now);
    _clearSettledCards(items, now);
    _syncTicker(alerts.isNotEmpty);
    return MeetupAlertsState(alerts: alerts, now: now);
  }

  Future<void> _loadTtl() async {
    _ttlLoaded = true;
    final seconds = await appConfigService.getInt(
      'meetup.wave_expiry_seconds',
      defaultValue: 60,
    );
    final beaconSeconds = await appConfigService.getInt(
      'meetup.beacon_expiry_seconds',
      defaultValue: 120,
    );
    final spotMinutes = await appConfigService.getInt(
      'meetup.spot_card_expiry_minutes',
      defaultValue: 120,
    );
    final proposalMinutes = await appConfigService.getInt(
      'meetup.proposal_expiry_minutes',
      defaultValue: 240,
    );
    if (ref.mounted) {
      _ttl = {
        kMeetupAlertSignal: Duration(seconds: seconds),
        kMeetupAlertBeacon: Duration(seconds: beaconSeconds),
        kMeetupAlertSpot: Duration(minutes: spotMinutes),
        kMeetupAlertProposal: Duration(minutes: proposalMinutes),
        kMeetupAlertPlaceChange: Duration(minutes: proposalMinutes),
      };
      _refresh();
    }
  }

  void _syncTicker(bool active) {
    if (!active) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    if (_ticker?.isActive ?? false) return;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ref.mounted) _refresh();
    });
  }

  void _refresh() {
    final items = ref.read(notificationInboxProvider).items;
    final now = DateTime.now();
    final alerts = _activeAlerts(items, now);
    _clearSettledCards(items, now);
    if (alerts.length != state.alerts.length ||
        now.difference(state.now) >= const Duration(seconds: 1) ||
        !_sameIds(alerts, state.alerts)) {
      state = MeetupAlertsState(alerts: alerts, now: now);
      _syncTicker(alerts.isNotEmpty);
    }
  }

  /// Drops the OS cards of the tool events that stopped being news, and settles
  /// the stale unread rows that keep the app-icon, bell and Matches badges set
  /// after the tool itself is gone.
  ///
  /// The bookkeeping runs in the pass itself, so a row is acted on once even
  /// when several passes see it before the read write lands; the platform calls
  /// and that write are deferred — this also runs while the inbox rebuilds,
  /// where marking a row read would mutate another provider mid-build and trip
  /// Riverpod's modify-during-build assert.
  void _clearSettledCards(List<NotificationInboxItem> items, DateTime now) {
    final plan = planMeetupAlertCards(
      items: items,
      ttl: _ttl,
      previouslyUnreadIds: _unreadToolRowIds,
      alreadyDismissedIds: _dismissedToolRowIds,
      now: now,
    );
    _unreadToolRowIds = plan.unreadIds;
    _dismissedToolRowIds = plan.dismissedIds;
    if (plan.dismissed.isEmpty && plan.staleIds.isEmpty) return;
    Future.microtask(() {
      if (!ref.mounted) return;
      for (final row in plan.dismissed) {
        unawaited(_dismissCard(row));
      }
      if (plan.staleIds.isNotEmpty) {
        unawaited(
          ref
              .read(notificationInboxProvider.notifier)
              .markReadMany(plan.staleIds.toSet()),
        );
      }
    });
  }

  Future<void> _dismissCard(NotificationInboxItem row) async {
    final kind = row.data['kind']?.toString() ?? row.type;
    final cardKey = meetupAlertCardKey(kind, row.data);
    if (cardKey.isNotEmpty) {
      await MobileLocalNotificationService.cancelMeetupCard(cardKey: cardKey);
    }
    // The card the FCM SDK posted while the app was backgrounded or killed is
    // not ours to address by id; it is cancelled by the push's collapse tag.
    final serverTag = meetupAlertServerTag(kind, row.data);
    if (serverTag.isNotEmpty) {
      await BackgroundService.cancelServerCard(serverTag);
    }
  }

  bool _sameIds(List<MeetupAlert> a, List<MeetupAlert> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  List<MeetupAlert> _activeAlerts(
    List<NotificationInboxItem> items,
    DateTime now,
  ) {
    final alerts = <MeetupAlert>[];
    for (final item in items) {
      if (item.readAt != null || item.deletedAt != null) continue;
      final kind = item.data['kind']?.toString() ?? item.type;
      final ttl = _ttl[kind];
      if (ttl == null) continue;
      final expiresAt = item.createdAt.add(ttl);
      if (!expiresAt.isAfter(now)) continue;
      alerts.add(
        MeetupAlert(
          id: item.id,
          matchId:
              item.data['matchId']?.toString() ??
              item.data['match_id']?.toString() ??
              '',
          senderId:
              item.data['senderId']?.toString() ??
              item.data['sender_id']?.toString() ??
              '',
          kind: kind,
          gesture: item.data['gesture']?.toString() ?? '',
          title: item.title,
          body: item.body,
          createdAt: item.createdAt,
          expiresAt: expiresAt,
        ),
      );
    }
    alerts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return alerts;
  }

  /// Marks this match's tool notifications seen: the live alerts (banner and
  /// row indicator clear immediately) and every other unread tool row for the
  /// match. Marking only the TTL-live alerts left an older unread row (e.g. a
  /// wave the user never opened) holding the Matches badge set after the live
  /// tool had been viewed.
  Future<void> clearMatch(String matchId) async {
    final id = matchId.trim();
    if (id.isEmpty) return;
    final ids = state.alerts
        .where((alert) => alert.matchId == id)
        .map((alert) => alert.id)
        .toSet();
    if (ids.isNotEmpty) {
      state = MeetupAlertsState(
        alerts: state.alerts
            .where((alert) => !ids.contains(alert.id))
            .toList(growable: false),
        now: state.now,
      );
    }
    await ref
        .read(notificationInboxProvider.notifier)
        .markMatchKindsRead(id, kMeetupAlertKinds);
  }
}

final meetupAlertsProvider =
    NotifierProvider<MeetupAlertsNotifier, MeetupAlertsState>(
      MeetupAlertsNotifier.new,
    );

/// Which match's meet-up surfaces are currently on screen (the match chat,
/// the meet-up hub, the Meet-up screen). The global alert bar hides itself
/// while the alert's own match is open in one of them — those surfaces
/// already show the same live state. Reference-counted so a screen pushed on
/// top of another one for the same match does not un-hide the bar when it
/// pops back.
class MeetupSurfacesNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    // A surface stays on screen showing the match's live tools, so a tool row
    // that reaches the inbox after enter() — a delayed realtime insert or a
    // retry — is seen as well. One-time clearing at enter() left that row
    // unread, and the Matches badge came back as soon as the user backed out.
    ref.listen<NotificationInboxState>(notificationInboxProvider, (_, _) {
      if (state.isEmpty) return;
      final openIds = state.keys.toList(growable: false);
      Future.microtask(() {
        if (!ref.mounted) return;
        for (final id in openIds) {
          if (state[id] == null) continue;
          unawaited(ref.read(meetupAlertsProvider.notifier).clearMatch(id));
        }
      });
    });
    return const {};
  }

  void enter(String matchId) {
    final id = matchId.trim();
    if (id.isEmpty) return;
    // Mutations are deferred: these calls come from widget lifecycle hooks
    // (a post-frame callback and dispose), and dispose runs during tree
    // finalization, where a synchronous provider mutation trips Riverpod's
    // modify-during-build assert — which would abort the screen's dispose
    // midway and leak its timers and subscriptions. Microtasks run after the
    // frame in scheduling order, so paired enter/exit keep their sequence.
    Future.microtask(() {
      if (!ref.mounted) return;
      final next = Map<String, int>.of(state);
      next[id] = (next[id] ?? 0) + 1;
      state = next;
      // The chat, the hub and the Meet-up screen display the live tools
      // themselves, so opening one is seeing them: clear the same alerts the
      // global bar would (read inbox rows included, which also clears the
      // Matches and inbox badges).
      unawaited(ref.read(meetupAlertsProvider.notifier).clearMatch(id));
      // The match itself is on screen here too, so its new-match/extension
      // banner is seen: that count feeds the same Matches badge.
      ref.read(matchNotificationProvider.notifier).markAsViewed(id);
    });
  }

  void exit(String matchId) {
    final id = matchId.trim();
    if (id.isEmpty) return;
    Future.microtask(() {
      if (!ref.mounted) return;
      final count = state[id];
      if (count == null) return;
      final next = Map<String, int>.of(state);
      if (count <= 1) {
        next.remove(id);
      } else {
        next[id] = count - 1;
      }
      state = next;
    });
  }
}

final meetupSurfacesProvider =
    NotifierProvider<MeetupSurfacesNotifier, Map<String, int>>(
      MeetupSurfacesNotifier.new,
    );
