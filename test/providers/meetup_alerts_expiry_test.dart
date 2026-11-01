import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/match_notification_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeInboxNotifier extends NotificationInboxNotifier {
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
    final items = state.items.map((item) {
      if (!ids.contains(item.id) || !item.isUnread) return item;
      return NotificationInboxItem(
        id: item.id,
        type: item.type,
        title: item.title,
        body: item.body,
        data: item.data,
        createdAt: item.createdAt,
        readAt: DateTime.now(),
        deletedAt: item.deletedAt,
      );
    }).toList();
    state = NotificationInboxState(
      items: items,
      unreadCount: items.where((item) => item.isUnread).length,
    );
  }
}

class _StubMatchNotifications extends MatchNotificationNotifier {
  final List<String> viewed = [];

  @override
  MatchNotificationState build() => MatchNotificationState();

  @override
  void markAsViewed(String matchId) => viewed.add(matchId);
}

NotificationInboxItem _wave({required DateTime createdAt}) {
  return NotificationInboxItem(
    id: 'wave-1',
    type: 'meetup_signal',
    title: 'First L. is signaling: Wave',
    body: 'Look for this gesture so you can spot each other.',
    data: const {
      'kind': 'meetup_signal',
      'matchId': 'match-1',
      'senderId': 'user-2',
      'gesture': 'wave',
    },
    createdAt: createdAt,
  );
}

NotificationInboxItem _spot({required DateTime createdAt}) {
  return NotificationInboxItem(
    id: 'spot-1',
    type: 'meetup_spot',
    title: 'First L. shared a Spot me card',
    body: 'They want you to find them.',
    data: const {
      'kind': 'meetup_spot',
      'matchId': 'match-1',
      'senderId': 'user-2',
    },
    createdAt: createdAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live meet-up alert still expires after the inbox rebuilds', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        notificationInboxProvider.overrideWith(_FakeInboxNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(meetupAlertsProvider, (_, _) {});

    final inbox =
        container.read(notificationInboxProvider.notifier)
            as _FakeInboxNotifier;
    // Only one second of the 60-second wave TTL is left so the test is quick.
    final wave = _wave(
      createdAt: DateTime.now().subtract(const Duration(seconds: 59)),
    );

    inbox.emit([wave]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(container.read(meetupAlertsProvider).alerts, isNotEmpty);

    // Any unrelated inbox update rebuilds MeetupAlertsNotifier. A rebuild that
    // leaves the one-second ticker cancelled freezes the countdown and keeps
    // the banner on screen forever.
    inbox.emit([wave]);
    container.read(meetupAlertsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    expect(container.read(meetupAlertsProvider).alerts, isEmpty);
  });

  test('opening a meet-up surface marks its live alerts seen', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        notificationInboxProvider.overrideWith(_FakeInboxNotifier.new),
        matchNotificationProvider.overrideWith(_StubMatchNotifications.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(meetupAlertsProvider, (_, _) {});
    container.listen(meetupSurfacesProvider, (_, _) {});

    final inbox =
        container.read(notificationInboxProvider.notifier)
            as _FakeInboxNotifier;
    inbox.emit([_wave(createdAt: DateTime.now())]);
    expect(container.read(meetupAlertsProvider).alerts, isNotEmpty);
    expect(container.read(notificationInboxProvider).unreadCount, 1);

    // Opening the chat/hub/plan screen registers the surface; the tool is
    // on screen there, so its alert and unread inbox row must clear.
    container.read(meetupSurfacesProvider.notifier).enter('match-1');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(meetupAlertsProvider).alerts, isEmpty);
    expect(container.read(notificationInboxProvider).unreadCount, 0);
  });

  test(
    'opening a meet-up surface also clears older unread tool rows',
    () async {
      SharedPreferences.setMockInitialValues({});
      final matchNotifications = _StubMatchNotifications();
      final container = ProviderContainer(
        overrides: [
          notificationInboxProvider.overrideWith(_FakeInboxNotifier.new),
          matchNotificationProvider.overrideWith(() => matchNotifications),
        ],
      );
      addTearDown(container.dispose);
      container.listen(meetupAlertsProvider, (_, _) {});
      container.listen(meetupSurfacesProvider, (_, _) {});

      final inbox =
          container.read(notificationInboxProvider.notifier)
              as _FakeInboxNotifier;
      // An older wave nothing ever opened (already past its TTL), plus a live
      // Spot card. Only the Spot card is an alert, but the stale unread row was
      // enough for the Matches badge to keep counting the match after the live
      // alert was cleared.
      inbox.emit([
        _wave(createdAt: DateTime.now().subtract(const Duration(minutes: 10))),
        _spot(createdAt: DateTime.now()),
      ]);
      expect(container.read(meetupAlertsProvider).alerts.length, 1);
      expect(container.read(notificationInboxProvider).unreadCount, 2);

      container.read(meetupSurfacesProvider.notifier).enter('match-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(meetupAlertsProvider).alerts, isEmpty);
      expect(container.read(notificationInboxProvider).unreadCount, 0);
      // The match itself is on screen there, so its new-match banner is seen.
      expect(matchNotifications.viewed, contains('match-1'));
    },
  );

  test('a tool row arriving while a surface is open is marked seen', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        notificationInboxProvider.overrideWith(_FakeInboxNotifier.new),
        matchNotificationProvider.overrideWith(_StubMatchNotifications.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(meetupAlertsProvider, (_, _) {});
    container.listen(meetupSurfacesProvider, (_, _) {});

    final inbox =
        container.read(notificationInboxProvider.notifier)
            as _FakeInboxNotifier;
    container.read(meetupSurfacesProvider.notifier).enter('match-1');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The hub is already open when the Spot card row lands (a delayed realtime
    // insert). The card is on screen, so the late row must not leave the
    // Matches badge set after the user backs out.
    inbox.emit([_spot(createdAt: DateTime.now())]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(meetupAlertsProvider).alerts, isEmpty);
    expect(container.read(notificationInboxProvider).unreadCount, 0);
  });
}
