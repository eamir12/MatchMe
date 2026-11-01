import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'eran';
const _peerId = 'first-l';
const _matchId = 'match-1';

String _fakeAccessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({'sub': _userId, 'iat': now, 'exp': now + 3600});
  return '$header.$payload.c2ln';
}

LocationShareSession _session({
  required ShareStatus myStatus,
  required ShareStatus otherStatus,
}) {
  return LocationShareSession(
    matchId: _matchId,
    myUserId: _userId,
    otherUserId: _peerId,
    otherUserName: 'First L.',
    myStatus: myStatus,
    otherStatus: otherStatus,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/v1/user')) {
          return http.Response(
            jsonEncode({
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.com',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '[]',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _fakeAccessToken(),
    );
  });

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        // Keep the test off the platform connectivity plugin and its timers.
        connectivityHealthProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('our own signal delete is never announced as the peer stopping', () async {
    final c = container();
    final notifier = c.read(locationShareProvider.notifier);
    notifier.state = _session(
      myStatus: ShareStatus.stopped,
      otherStatus: ShareStatus.unknown,
    );

    await notifier.handleSignalDeleted(
      deletedSharerId: _userId,
      deletedMatchId: _matchId,
    );

    expect(c.read(systemNotificationProvider), isNull);
    expect(notifier.state!.otherStatus, ShareStatus.unknown);
  });

  test('peer signal delete while the peer was sharing announces the stop', () async {
    final c = container();
    final notifier = c.read(locationShareProvider.notifier);
    notifier.state = _session(
      myStatus: ShareStatus.stopped,
      otherStatus: ShareStatus.sharing,
    );

    await notifier.handleSignalDeleted(
      deletedSharerId: _peerId,
      deletedMatchId: _matchId,
    );

    expect(notifier.state!.otherStatus, ShareStatus.stopped);
    expect(
      c.read(systemNotificationProvider)?.text,
      contains('stopped sharing'),
    );
  });

  test('peer signal delete is silent when the peer never shared', () async {
    final c = container();
    final notifier = c.read(locationShareProvider.notifier);
    notifier.state = _session(
      myStatus: ShareStatus.sharing,
      otherStatus: ShareStatus.unknown,
    );

    await notifier.handleSignalDeleted(
      deletedSharerId: _peerId,
      deletedMatchId: _matchId,
    );

    expect(c.read(systemNotificationProvider), isNull);
    expect(notifier.state!.otherStatus, ShareStatus.unknown);
  });

  test('a delete from another match leaves this session untouched', () async {
    final c = container();
    final notifier = c.read(locationShareProvider.notifier);
    notifier.state = _session(
      myStatus: ShareStatus.stopped,
      otherStatus: ShareStatus.sharing,
    );

    await notifier.handleSignalDeleted(
      deletedSharerId: _peerId,
      deletedMatchId: 'another-match',
    );

    expect(c.read(systemNotificationProvider), isNull);
    expect(notifier.state!.otherStatus, ShareStatus.sharing);
  });

  test('duplicate stop events do not re-notify', () async {
    final c = container();
    final notifier = c.read(locationShareProvider.notifier);
    notifier.state = _session(
      myStatus: ShareStatus.stopped,
      otherStatus: ShareStatus.sharing,
    );

    await notifier.handleSignalDeleted(
      deletedSharerId: _peerId,
      deletedMatchId: _matchId,
    );
    final first = c.read(systemNotificationProvider);
    expect(first?.text, contains('stopped sharing'));

    c.read(systemNotificationProvider.notifier).clear();
    await notifier.handleSignalDeleted(
      deletedSharerId: _peerId,
      deletedMatchId: _matchId,
    );

    expect(c.read(systemNotificationProvider), isNull);
  });
}
