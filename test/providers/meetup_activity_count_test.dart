import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_activity.dart';
import 'package:matchme/providers/meetup_activity_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _StubMeetupActivity extends MeetupActivityNotifier {
  _StubMeetupActivity(this.rows);

  final Map<String, MeetupActivity> rows;

  @override
  Map<String, MeetupActivity> build() => rows;
}

class _StubInbox extends NotificationInboxNotifier {
  _StubInbox(this.items);

  final List<NotificationInboxItem> items;

  @override
  NotificationInboxState build() => NotificationInboxState(
    items: items,
    unreadCount: items.where((item) => item.isUnread).length,
  );
}

NotificationInboxItem _toolRow({
  required String kind,
  required String matchId,
  bool read = false,
}) {
  return NotificationInboxItem(
    id: '$kind-$matchId',
    type: kind,
    title: 'Title',
    body: 'Body',
    data: {'kind': kind, 'matchId': matchId},
    createdAt: DateTime(2026, 10, 20, 12),
    readAt: read ? DateTime(2026, 10, 20, 12, 1) : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The stubbed notifier still constructs MeetupService, which reads the
    // Supabase client.
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      debug: false,
    );
  });

  MeetupActivity activity(String kind, {required bool own}) =>
      MeetupActivity(topKind: kind, topOwn: own, toolCount: 1);

  ProviderContainer containerWith(
    Map<String, MeetupActivity> rows, {
    List<NotificationInboxItem> inbox = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        meetupActivityProvider.overrideWith(() => _StubMeetupActivity(rows)),
        notificationInboxProvider.overrideWith(() => _StubInbox(inbox)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('counts their unseen live tools only', () {
    final container = containerWith(
      {
        'their-wave': activity(MeetupActivityKind.wave, own: false),
        'their-live': activity(MeetupActivityKind.live, own: false),
        'own-beacon': activity(MeetupActivityKind.beacon, own: true),
        'active-meetup': activity(MeetupActivityKind.active, own: false),
        'unknown-kind': activity('', own: false),
      },
      inbox: [
        _toolRow(kind: 'meetup_signal', matchId: 'their-wave'),
        _toolRow(kind: 'location_share', matchId: 'their-live'),
        _toolRow(kind: 'meetup_beacon', matchId: 'own-beacon'),
        _toolRow(kind: 'meetup_proposal', matchId: 'active-meetup'),
        _toolRow(kind: 'meetup_signal', matchId: 'unknown-kind'),
      ],
    );

    expect(container.read(incomingMeetupActivityCountProvider), 2);
  });

  test('viewed tools stop counting before they expire', () {
    final container = containerWith(
      {
        'their-spot': activity(MeetupActivityKind.spot, own: false),
        'their-wave': activity(MeetupActivityKind.wave, own: false),
      },
      inbox: [
        _toolRow(kind: 'meetup_spot', matchId: 'their-spot', read: true),
        _toolRow(kind: 'meetup_signal', matchId: 'their-wave', read: true),
      ],
    );

    expect(container.read(incomingMeetupActivityCountProvider), 0);
  });

  test('an unread row for another match does not count this one', () {
    final container = containerWith(
      {'their-spot': activity(MeetupActivityKind.spot, own: false)},
      inbox: [_toolRow(kind: 'meetup_spot', matchId: 'other-match')],
    );

    expect(container.read(incomingMeetupActivityCountProvider), 0);
  });

  test('a non-tool unread row does not count as meet-up activity', () {
    final container = containerWith(
      {'their-spot': activity(MeetupActivityKind.spot, own: false)},
      inbox: [_toolRow(kind: 'chat_message', matchId: 'their-spot')],
    );

    expect(container.read(incomingMeetupActivityCountProvider), 0);
  });

  test('is zero when nothing is live', () {
    final container = containerWith(const {});

    expect(container.read(incomingMeetupActivityCountProvider), 0);
  });
}
