import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/mobile_local_notification_service.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:matchme/utils/meetup_alert_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 11, 1, 12);

NotificationInboxItem _row({
  required String id,
  required String kind,
  required DateTime createdAt,
  DateTime? readAt,
  DateTime? deletedAt,
  bool superseded = false,
  bool withdrawn = false,
}) {
  return NotificationInboxItem(
    id: id,
    type: kind,
    title: 'A wave',
    body: 'Look for this gesture',
    data: {
      'kind': kind,
      'matchId': 'match-1',
      'senderId': 'user-2',
      'meetup_signal_id': id,
      if (superseded) 'superseded': true,
      if (withdrawn) 'withdrawn': true,
    },
    createdAt: createdAt,
    readAt: readAt,
    deletedAt: deletedAt,
  );
}

MeetupAlertCardPlan _plan(
  List<NotificationInboxItem> items, {
  Set<String> previously = const {},
  Set<String> alreadyDismissed = const {},
}) {
  return planMeetupAlertCards(
    items: items,
    ttl: kMeetupAlertDefaultTtl,
    previouslyUnreadIds: previously,
    alreadyDismissedIds: alreadyDismissed,
    now: _now,
  );
}

/// Stands in for the real inbox: records the rows the sweep settles.
class _FakeInboxNotifier extends NotificationInboxNotifier {
  final List<String> settled = [];

  @override
  NotificationInboxState build() => const NotificationInboxState();

  void emit(List<NotificationInboxItem> items) {
    state = NotificationInboxState(
      items: items,
      unreadCount: items.where((item) => item.isUnread).length,
    );
  }

  @override
  Future<void> markReadMany(Set<String> ids) async {
    if (ids.isEmpty) return;
    settled.addAll(ids);
    final items = state.items
        .map(
          (item) => ids.contains(item.id) && item.isUnread
              ? _row(
                  id: item.id,
                  kind: item.type,
                  createdAt: item.createdAt,
                  readAt: DateTime.now(),
                )
              : item,
        )
        .toList();
    state = NotificationInboxState(
      items: items,
      unreadCount: items.where((item) => item.isUnread).length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which tool rows stop being news', () {
    test(
      'a row still inside its window keeps its card and its unread state',
      () {
        final plan = _plan([
          _row(
            id: 'live-1',
            kind: kMeetupAlertSignal,
            createdAt: _now.subtract(const Duration(seconds: 30)),
          ),
        ]);
        expect(plan.dismissed, isEmpty);
        expect(plan.staleIds, isEmpty);
        expect(plan.unreadIds, {'live-1'});
      },
    );

    test('a row whose window closed loses its card', () {
      final plan = _plan([
        _row(
          id: 'stale-1',
          kind: kMeetupAlertSignal,
          createdAt: _now.subtract(const Duration(minutes: 2)),
        ),
      ]);
      expect(plan.dismissed.map((row) => row.id), ['stale-1']);
      // Settling the row is what clears the app-icon and Matches badges: no
      // server path expires an unread tool row.
      expect(plan.staleIds, ['stale-1']);
      expect(plan.unreadIds, isEmpty);
    });

    test('a row the recipient read loses its card once', () {
      final seen = _row(
        id: 'seen-1',
        kind: kMeetupAlertBeacon,
        createdAt: _now.subtract(const Duration(seconds: 10)),
        readAt: _now,
      );
      final plan = _plan([seen], previously: {'seen-1'});
      expect(plan.dismissed.map((row) => row.id), ['seen-1']);
      expect(plan.staleIds, isEmpty);

      // The next pass compares against what this pass reported as unread.
      final next = _plan(
        [seen],
        previously: plan.unreadIds,
        alreadyDismissed: plan.dismissedIds,
      );
      expect(next.dismissed, isEmpty);
    });

    test('a withdrawn signal loses its card even if already read', () {
      final withdrawn = _row(
        id: 'withdrawn-1',
        kind: kMeetupAlertBeacon,
        createdAt: _now.subtract(const Duration(seconds: 30)),
        readAt: _now,
        withdrawn: true,
      );
      final plan = _plan([withdrawn]);

      expect(plan.dismissed.map((row) => row.id), ['withdrawn-1']);
      expect(plan.staleIds, isEmpty);
      expect(plan.unreadIds, isEmpty);
    });

    test('a row the server superseded keeps its card', () {
      // The server marks the alert a newer signal replaced as read, which is
      // what clears the bell. That is not the recipient having seen it, so the
      // card already in the notification shade stays: a wave and a beacon are
      // two things that happened.
      final replaced = _row(
        id: 'beacon-1',
        kind: kMeetupAlertBeacon,
        createdAt: _now.subtract(const Duration(seconds: 30)),
        readAt: _now,
        superseded: true,
      );
      final plan = _plan([replaced], previously: {'beacon-1'});
      expect(plan.dismissed, isEmpty);
      expect(plan.staleIds, isEmpty);
      expect(plan.unreadIds, isEmpty);
    });

    test('a stale row is settled once, not on every pass', () {
      final stale = [
        _row(
          id: 'stale-1',
          kind: kMeetupAlertSignal,
          createdAt: _now.subtract(const Duration(minutes: 2)),
        ),
      ];
      final first = _plan(stale);
      expect(first.staleIds, ['stale-1']);

      // The read write is asynchronous, so the row can still be unread when
      // the next inbox change or config refresh runs the sweep again. Without
      // the memory that is another card drop and another update per pass.
      final again = _plan(stale, alreadyDismissed: first.dismissedIds);
      expect(again.dismissed, isEmpty);
      expect(again.staleIds, isEmpty);

      // Rows that leave the inbox leave the memory with them.
      expect(
        _plan(const [], alreadyDismissed: first.dismissedIds).dismissedIds,
        isEmpty,
      );
    });

    test('a row removed from the inbox loses its card too', () {
      final plan = _plan(
        [
          _row(
            id: 'gone-1',
            kind: kMeetupAlertSpot,
            createdAt: _now.subtract(const Duration(minutes: 1)),
            deletedAt: _now,
          ),
        ],
        previously: {'gone-1'},
      );
      expect(plan.dismissed.map((row) => row.id), ['gone-1']);
    });

    test('the sweep ignores rows that are not meet-up tools', () {
      final plan = _plan(
        [
          _row(id: 'chat-1', kind: 'chat_message', createdAt: _now),
          _row(id: 'expiry-1', kind: 'match_expiry', createdAt: _now),
        ],
        previously: {'chat-1', 'expiry-1'},
      );
      expect(plan.dismissed, isEmpty);
      expect(plan.unreadIds, isEmpty);
    });

    test('a proposal stays news far longer than a wave', () {
      final at = _now.subtract(const Duration(minutes: 90));
      expect(
        _plan([
          _row(id: 'w', kind: kMeetupAlertSignal, createdAt: at),
        ]).staleIds,
        ['w'],
      );
      expect(
        _plan([
          _row(id: 'p', kind: kMeetupAlertProposal, createdAt: at),
        ]).staleIds,
        isEmpty,
      );
    });
  });

  group('the notifier', () {
    test(
      'clears a stale unread tool row without the user opening anything',
      () async {
        SharedPreferences.setMockInitialValues({});
        final inbox = _FakeInboxNotifier();
        final container = ProviderContainer(
          overrides: [notificationInboxProvider.overrideWith(() => inbox)],
        );
        addTearDown(container.dispose);
        container.listen(meetupAlertsProvider, (_, _) {});

        // A wave from well outside its window: no banner, and nothing to see.
        inbox.emit([
          _row(
            id: 'stale-1',
            kind: kMeetupAlertSignal,
            createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(container.read(meetupAlertsProvider).alerts, isEmpty);
        // Exactly one read update, however many passes the row went through.
        expect(inbox.settled, ['stale-1']);
        expect(container.read(notificationInboxProvider).unreadCount, 0);
      },
    );

    test(
      'a row the recipient read leaves the alert bar without another write',
      () async {
        SharedPreferences.setMockInitialValues({});
        final inbox = _FakeInboxNotifier();
        final container = ProviderContainer(
          overrides: [notificationInboxProvider.overrideWith(() => inbox)],
        );
        addTearDown(container.dispose);
        container.listen(meetupAlertsProvider, (_, _) {});

        inbox.emit([
          _row(
            id: 'live-1',
            kind: kMeetupAlertSignal,
            createdAt: DateTime.now(),
          ),
        ]);
        expect(container.read(meetupAlertsProvider).alerts, hasLength(1));

        // Reading the row is what opening the meet-up screen ends up doing.
        // Inside its window the sweep has nothing to settle: the card is
        // dropped, no write is issued for a row that is already read.
        inbox.emit([
          _row(
            id: 'live-1',
            kind: kMeetupAlertSignal,
            createdAt: DateTime.now(),
            readAt: DateTime.now(),
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(inbox.settled, isEmpty);
        expect(container.read(meetupAlertsProvider).alerts, isEmpty);
      },
    );
  });

  // The cards themselves: what the sweep hands the platform, on the channel
  // the notification plugin actually uses.
  group('the platform cards', () {
    const pluginChannel = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    final calls = <MethodCall>[];

    List<Map<Object?, Object?>> sent(String method) => calls
        .where((call) => call.method == method)
        .map((call) => Map<Object?, Object?>.from(call.arguments as Map))
        .toList();

    setUp(() {
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pluginChannel, (call) async {
            calls.add(call);
            // The plugin casts the initialise result to a non-nullable bool.
            return call.method == 'initialize' ? true : null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pluginChannel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'a posted card is cancelled under the id it was posted with',
      () async {
        const data = {
          'kind': kMeetupAlertSignal,
          'match_id': 'match-1',
          'sender_id': 'user-2',
        };
        final cardKey = meetupAlertCardKey(kMeetupAlertSignal, data);
        await MobileLocalNotificationService.showMeetupNotification(
          notificationId: cardKey,
          title: 'A wave',
          body: 'Look for this gesture',
          matchId: 'match-1',
          kind: kMeetupAlertSignal,
          expiresIn: kMeetupAlertDefaultTtl[kMeetupAlertSignal],
        );

        final shown = sent('show').single;
        expect(shown['id'], cardKey.hashCode);
        // The live window goes to the system too: Android drops the card at
        // the TTL even if this app never wakes up again.
        expect(
          Map<Object?, Object?>.from(
            shown['platformSpecifics']! as Map,
          )['timeoutAfter'],
          60 * 1000,
        );

        await MobileLocalNotificationService.cancelMeetupCard(cardKey: cardKey);
        expect(sent('cancel').single['id'], shown['id']);
      },
    );

    test('the sweep drops an expired card from the tray', () async {
      SharedPreferences.setMockInitialValues({});
      final inbox = _FakeInboxNotifier();
      final container = ProviderContainer(
        overrides: [notificationInboxProvider.overrideWith(() => inbox)],
      );
      addTearDown(container.dispose);
      container.listen(meetupAlertsProvider, (_, _) {});

      final row = _row(
        id: 'stale-1',
        kind: kMeetupAlertSignal,
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      inbox.emit([row]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cancelled = sent('cancel');
      expect(
        cancelled.any(
          (call) =>
              call['id'] ==
              meetupAlertCardKey(kMeetupAlertSignal, row.data).hashCode,
        ),
        isTrue,
      );
      expect(
        cancelled.any(
          (call) =>
              call['tag'] == meetupAlertServerTag(kMeetupAlertSignal, row.data),
        ),
        isTrue,
      );
      expect(inbox.settled, contains('stale-1'));
    });

    test('withdrawing a live signal cancels its existing tray card', () async {
      SharedPreferences.setMockInitialValues({});
      final inbox = _FakeInboxNotifier();
      final container = ProviderContainer(
        overrides: [notificationInboxProvider.overrideWith(() => inbox)],
      );
      addTearDown(container.dispose);
      container.listen(meetupAlertsProvider, (_, _) {});

      final createdAt = DateTime.now();
      final row = _row(
        id: 'withdrawn-1',
        kind: kMeetupAlertBeacon,
        createdAt: createdAt,
      );
      inbox.emit([row]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sent('cancel'), isEmpty);

      inbox.emit([
        _row(
          id: 'withdrawn-1',
          kind: kMeetupAlertBeacon,
          createdAt: createdAt,
          readAt: DateTime.now(),
          withdrawn: true,
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cancelled = sent('cancel');
      expect(
        cancelled.any(
          (call) =>
              call['id'] ==
              meetupAlertCardKey(kMeetupAlertBeacon, row.data).hashCode,
        ),
        isTrue,
      );
      expect(
        cancelled.any(
          (call) =>
              call['tag'] == meetupAlertServerTag(kMeetupAlertBeacon, row.data),
        ),
        isTrue,
      );
    });

    test('a card inside its window is left alone', () async {
      SharedPreferences.setMockInitialValues({});
      final inbox = _FakeInboxNotifier();
      final container = ProviderContainer(
        overrides: [notificationInboxProvider.overrideWith(() => inbox)],
      );
      addTearDown(container.dispose);
      container.listen(meetupAlertsProvider, (_, _) {});

      inbox.emit([
        _row(id: 'live-1', kind: kMeetupAlertSignal, createdAt: DateTime.now()),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent('cancel'), isEmpty);
    });
  });
}
