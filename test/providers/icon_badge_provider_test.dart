import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/icon_badge_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';

NotificationInboxItem _item({required String id, DateTime? readAt}) {
  return NotificationInboxItem(
    id: id,
    type: 'chat_message',
    title: 'New message',
    body: 'Hi',
    data: const {'matchId': 'match-1'},
    createdAt: DateTime(2026, 10, 20, 12),
    readAt: readAt,
  );
}

void main() {
  test('one unread notification produces a badge of 1', () {
    final inbox = NotificationInboxState(
      items: [_item(id: 'n1')],
      unreadCount: 1,
    );

    expect(iconBadgeValueFor(userId: 'user-1', inbox: inbox), 1);
  });

  test('read notifications do not count', () {
    final inbox = NotificationInboxState(
      items: [_item(id: 'n1', readAt: DateTime(2026, 10, 20, 12, 1))],
      unreadCount: 0,
    );

    expect(iconBadgeValueFor(userId: 'user-1', inbox: inbox), 0);
  });

  test('initial loading keeps the server-set badge instead of stamping 0', () {
    const inbox = NotificationInboxState(isLoading: true);

    expect(iconBadgeValueFor(userId: 'user-1', inbox: inbox), isNull);
  });

  test('cached rows are used while the refresh is still loading', () {
    final inbox = NotificationInboxState(
      items: [_item(id: 'n1')],
      unreadCount: 1,
      isLoading: true,
    );

    expect(iconBadgeValueFor(userId: 'user-1', inbox: inbox), 1);
  });

  test('signed-out users have no badge', () {
    final inbox = NotificationInboxState(
      items: [_item(id: 'n1')],
      unreadCount: 1,
    );

    expect(iconBadgeValueFor(userId: '', inbox: inbox), 0);
  });
}
