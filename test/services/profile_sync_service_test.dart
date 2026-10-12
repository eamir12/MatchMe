import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/utils/profile_sync_result.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'test-user';

class _FakeLocalDb extends LocalDbService {
  final Map<String, Map<String, dynamic>> profiles = {};

  @override
  Future<Map<String, dynamic>?> getLocalProfile(String userId) async {
    final profile = profiles[userId];
    return profile == null ? null : Map<String, dynamic>.from(profile);
  }

  @override
  Future<void> saveLocalProfile(
    String userId,
    Map<String, dynamic> profileData,
  ) async {
    profiles[userId] = Map<String, dynamic>.from(profileData);
  }
}

String _fakeAccessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({'sub': _userId, 'iat': now, 'exp': now + 3600});
  return '$header.$payload.c2ln';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var userRequestCount = 0;
  var requestGate = Completer<void>();
  var requestStarted = Completer<void>();

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
        if (request.url.path.contains('/rest/v1/user_profiles')) {
          return http.Response(
            jsonEncode({
              'user_id': _userId,
              'photos': <String>[],
              'approved_primary_photos': <String>[],
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.contains('/rest/v1/users')) {
          userRequestCount++;
          if (!requestStarted.isCompleted) {
            requestStarted.complete();
          }
          await requestGate.future;
          return http.Response(
            jsonEncode({
              'id': _userId,
              'name': 'Test User',
              'preferred_language': 'en',
              'subscription_tier': 'free',
              'is_profile_complete': true,
              'match_radius_default': 10,
              'gps_interval_default': 60,
              'smart_gps_throttling_enabled': false,
              'shared_event_matching_enabled': false,
              'shared_movement_matching_enabled': false,
              'retro_matching_enabled': false,
              'retro_retention_hours': 24,
              'editable_profile_fields': <String>[],
              'is_verified': false,
              'verification_status': 'unverified',
              'referral_code': null,
              'credits': 0,
              'created_at': null,
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('[]', 200, request: request);
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _fakeAccessToken(),
    );
  });

  setUp(() {
    userRequestCount = 0;
    requestGate = Completer<void>();
    requestStarted = Completer<void>();
  });

  ProviderContainer makeContainer(
    _FakeLocalDb localDb, {
    required bool online,
  }) {
    final container = ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(localDb),
        connectivityProvider.overrideWithValue(AsyncData(online)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'offline sync reports the cached profile without a REST request',
    () async {
      final localDb = _FakeLocalDb()
        ..profiles[_userId] = <String, dynamic>{'id': _userId};
      final container = makeContainer(localDb, online: false);

      final result = await container
          .read(profileSyncProvider)
          .syncProfile(_userId, source: 'test-offline');

      expect(result.status, ProfileSyncStatus.offline);
      expect(result.cacheAvailable, isTrue);
      expect(result.cacheUpdated, isFalse);
      expect(userRequestCount, 0);
    },
  );

  test(
    'concurrent syncs share one request and later syncs can start',
    () async {
      final localDb = _FakeLocalDb();
      final container = makeContainer(localDb, online: true);
      final service = container.read(profileSyncProvider);

      final first = service.syncProfile(_userId, source: 'test-first');
      await requestStarted.future;
      final second = service.syncProfile(_userId, source: 'test-second');

      expect(identical(first, second), isTrue);
      expect(userRequestCount, 1);

      requestGate.complete();
      final results = await Future.wait([first, second]);
      expect(
        results.map((result) => result.status),
        everyElement(ProfileSyncStatus.synced),
      );
      expect(localDb.profiles.containsKey(_userId), isTrue);

      await Future<void>.delayed(Duration.zero);
      requestGate = Completer<void>();
      requestStarted = Completer<void>();
      // A later sync must be able to start a fresh request once the previous
      // one completed. Use a debounce-bypass source — a plain source would be
      // skipped for 5s after the successful sync above.
      final third = service.syncProfile(
        _userId,
        source: 'manual-review-request',
      );
      await requestStarted.future;
      requestGate.complete();
      final thirdResult = await third;
      expect(thirdResult.status, ProfileSyncStatus.synced);
      expect(userRequestCount, 2);
    },
  );

  test(
    'invalidating a user cancels the old generation and starts fresh',
    () async {
      final localDb = _FakeLocalDb();
      final container = makeContainer(localDb, online: true);
      final service = container.read(profileSyncProvider);

      final first = service.syncProfile(_userId, source: 'test-old');
      await requestStarted.future;
      service.invalidateUser(_userId);
      requestStarted = Completer<void>();
      final second = service.syncProfile(_userId, source: 'test-new');
      await requestStarted.future;

      expect(identical(first, second), isFalse);
      expect(userRequestCount, 2);
      requestGate.complete();

      final firstResult = await first;
      final secondResult = await second;
      expect(firstResult.status, ProfileSyncStatus.cancelled);
      expect(secondResult.status, ProfileSyncStatus.synced);
    },
  );

  test('profile sync state can be reset for account changes', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(profileSyncStateProvider(_userId).notifier);

    notifier.completed(
      const ProfileSyncResult(
        status: ProfileSyncStatus.failed,
        cacheAvailable: true,
      ),
    );
    expect(container.read(profileSyncStateProvider(_userId)).showStale, isTrue);

    notifier.reset();
    final resetState = container.read(profileSyncStateProvider(_userId));
    expect(resetState.result, isNull);
    expect(resetState.isSyncing, isFalse);
    expect(resetState.showStale, isFalse);
  });
}
