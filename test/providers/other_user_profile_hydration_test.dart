import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _viewerId = 'profile-hydration-viewer';
const _otherUserId = 'profile-hydration-other';

class _FakeLocalDb extends LocalDbService {
  Map<String, dynamic>? cachedOtherProfile;

  @override
  Future<Map<String, dynamic>?> getOtherUserProfileWithCacheMeta(
    String userId,
  ) async {
    if (userId != _otherUserId || cachedOtherProfile == null) return null;
    return Map<String, dynamic>.from(cachedOtherProfile!);
  }

  @override
  Future<void> saveOtherUserProfile(
    String userId,
    Map<String, dynamic> profileData,
  ) async {
    if (userId == _otherUserId) {
      cachedOtherProfile = Map<String, dynamic>.from(profileData);
    }
  }
}

String _accessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': _viewerId, 'iat': now, 'exp': now + 3600})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var profileRequests = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/v1/user')) {
          return http.Response(
            jsonEncode({
              'id': _viewerId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'viewer@example.com',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/rest/v1/user_profiles')) {
          profileRequests++;
          return http.Response(
            jsonEncode({
              'user_id': _otherUserId,
              'photos': ['https://example.com/avatar.jpg?token=valid'],
              'personal_interests': {
                'friendship': ['hiking', 'music'],
              },
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/rest/v1/users')) {
          profileRequests++;
          return http.Response(
            jsonEncode({'id': _otherUserId, 'name': 'Alexandra Example'}),
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
      accessToken: _accessToken(),
    );
  });

  setUp(() {
    profileRequests = 0;
  });

  test(
    'fresh but incomplete cache hydrates and merges remote name, photo, interests',
    () async {
      final localDb = _FakeLocalDb()
        ..cachedOtherProfile = {
          'id': _otherUserId,
          'name': '',
          'photos': <String>[],
          'personal_interests': <String, dynamic>{},
          'cached_at': DateTime.now().toIso8601String(),
        };
      final container = ProviderContainer(
        overrides: [
          localDbProvider.overrideWithValue(localDb),
          connectivityProvider.overrideWithValue(const AsyncData(true)),
        ],
      );
      addTearDown(container.dispose);

      final hydrated = Completer<UserProfile>();
      final subscription = container.listen<AsyncValue<UserProfile?>>(
        otherUserProfileProvider(_otherUserId),
        (previous, next) {
          final profile = next.asData?.value;
          if (profile != null &&
              profile.name == 'Alexandra Example' &&
              profile.photos.isNotEmpty &&
              profile.personalInterests['friendship']?.length == 2 &&
              !hydrated.isCompleted) {
            hydrated.complete(profile);
          }
        },
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final initial = await container.read(
        otherUserProfileProvider(_otherUserId).future,
      );
      expect(initial?.name, isEmpty);
      expect(profileRequests, 0);

      final result = await hydrated.future.timeout(const Duration(seconds: 5));
      expect(result.name, 'Alexandra Example');
      expect(result.photos, ['https://example.com/avatar.jpg?token=valid']);
      expect(result.personalInterests['friendship'], ['hiking', 'music']);
      expect(profileRequests, 2);
      expect(localDb.cachedOtherProfile?['name'], 'Alexandra Example');
    },
  );
}
