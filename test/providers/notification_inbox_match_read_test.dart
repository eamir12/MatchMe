import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';

class _StubInboxNotifier extends NotificationInboxNotifier {
  _StubInboxNotifier(this.initialItems);

  final List<NotificationInboxItem> initialItems;

  @override
  NotificationInboxState build() => NotificationInboxState(
    items: initialItems,
    unreadCount: initialItems.where((item) => item.isUnread).length,
  );
}

NotificationInboxItem _row({
  required String id,
  required String type,
  String? kind,
  Map<String, dynamic> extraData = const {},
  bool read = false,
}) {
  return NotificationInboxItem(
    id: id,
    type: type,
    title: 'Title',
    body: 'Body',
    data: {'kind': ?kind, ...extraData},
    createdAt: DateTime(2026, 10, 28, 12),
    readAt: read ? DateTime(2026, 10, 28, 12, 5) : null,
  );
}

ProviderContainer _containerWith(List<NotificationInboxItem> items) {
  final container = ProviderContainer(
    overrides: [
      notificationInboxProvider.overrideWith(() => _StubInboxNotifier(items)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

bool _isRead(ProviderContainer container, String id) {
  return container
          .read(notificationInboxProvider)
          .items
          .firstWhere((item) => item.id == id)
          .readAt !=
      null;
}

void main() {
  test('marks only unread rows of the given kinds for the match', () async {
    final container = _containerWith([
      _row(
        id: 'target',
        type: 'location_share',
        kind: 'location_share',
        extraData: const {'matchId': 'match-1'},
      ),
      _row(
        id: 'other-match',
        type: 'location_share',
        kind: 'location_share',
        extraData: const {'matchId': 'match-2'},
      ),
      _row(
        id: 'already-read',
        type: 'location_share',
        kind: 'location_share',
        extraData: const {'matchId': 'match-1'},
        read: true,
      ),
      _row(
        id: 'other-kind',
        type: 'meetup_spot',
        kind: 'meetup_spot',
        extraData: const {'matchId': 'match-1'},
      ),
    ]);

    await container.read(notificationInboxProvider.notifier).markMatchKindsRead(
      'match-1',
      const {'location_share'},
    );

    expect(_isRead(container, 'target'), isTrue);
    expect(_isRead(container, 'other-match'), isFalse);
    expect(_isRead(container, 'already-read'), isTrue);
    expect(_isRead(container, 'other-kind'), isFalse);
    expect(container.read(notificationInboxProvider).unreadCount, 2);
  });

  test('falls back to the row type when data carries no kind', () async {
    final container = _containerWith([
      _row(
        id: 'match-row',
        type: 'match',
        extraData: const {'matchId': 'match-9'},
      ),
    ]);

    await container.read(notificationInboxProvider.notifier).markMatchKindsRead(
      'match-9',
      const {'match'},
    );

    expect(_isRead(container, 'match-row'), isTrue);
  });

  test('accepts snake_case match_id rows', () async {
    final container = _containerWith([
      _row(
        id: 'snake',
        type: 'location_share',
        kind: 'location_share',
        extraData: const {'match_id': 'match-3'},
      ),
    ]);

    await container.read(notificationInboxProvider.notifier).markMatchKindsRead(
      'match-3',
      const {'location_share'},
    );

    expect(_isRead(container, 'snake'), isTrue);
  });

  test('rows without a match id are never touched', () async {
    final container = _containerWith([
      _row(id: 'general', type: 'location_share', kind: 'location_share'),
    ]);

    await container.read(notificationInboxProvider.notifier).markMatchKindsRead(
      'match-1',
      const {'location_share'},
    );

    expect(_isRead(container, 'general'), isFalse);
  });
}
