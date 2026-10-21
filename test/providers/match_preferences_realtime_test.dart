import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
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

UserProfile _profile() {
  return UserProfile(
    id: _userId,
    name: 'Test User',
    preferredLanguage: 'en',
    activeModes: const ['romantic'],
    subIntents: const {},
    personalInterests: const {},
    businessInterests: const {},
    languagesKnown: const {},
    subscriptionTier: 'free',
    isProfileComplete: true,
    matchRadiusDefault: 10,
    gpsIntervalDefault: 60,
    smartGpsThrottlingEnabled: false,
    sharedEventMatchingEnabled: false,
    sharedMovementMatchingEnabled: false,
    editableProfileFields: const [],
    genderPreferences: const {
      'romantic': ['female'],
    },
    agePreferences: const {
      'romantic': [25.0, 35.0],
    },
    lifestyleFilters: const {},
    familyFilters: const {},
    religionFilters: const {},
    heightPreferences: const {},
    photos: const [],
  );
}

class _TestProfileEditNotifier extends ProfileEditNotifier {
  _TestProfileEditNotifier(this.profile);

  final UserProfile profile;

  @override
  AsyncValue<UserProfile?> build(String userId) => AsyncData(profile);
}

/// The preferred age range lives in `user_profiles.intent_preferences`, not on
/// the `users` row. A change made on another device has to reach this
/// device's profile state - otherwise the two devices keep showing different
/// age ranges until the next cold start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLocalDb localDb;
  late Map<String, dynamic> remoteIntentPreferences;

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
              'intent_preferences': remoteIntentPreferences,
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
    localDb = _FakeLocalDb();
    remoteIntentPreferences = {
      'gender_preferences': {
        'romantic': ['female'],
      },
      'age_preferences': {
        'romantic': [30.0, 45.0],
      },
    };
  });

  test('a remote age range reaches the local profile', () async {
    final container = ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(localDb),
        profileEditProvider(
          _userId,
        ).overrideWith(() => _TestProfileEditNotifier(_profile())),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(profileEditProvider(_userId).notifier);

    await notifier.reconcileMatchPreferences();

    final updated = notifier.state.value;
    expect(updated, isNotNull);
    expect(updated!.agePreferences['romantic'], [30.0, 45.0]);
    // The rest of the preferences are left alone.
    expect(updated.genderPreferences['romantic'], ['female']);
    // The local cache is kept in step so the screen and the matching queries
    // read the new values without another round-trip.
    expect(
      localDb.profiles[_userId]?['age_preferences'],
      containsPair('romantic', [30.0, 45.0]),
    );
  });

  test('a partial remote payload does not clear the other preferences', () async {
    // Only the age range is present - the other groups must survive.
    remoteIntentPreferences = {
      'age_preferences': {
        'romantic': [30.0, 45.0],
      },
    };

    final container = ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(localDb),
        profileEditProvider(
          _userId,
        ).overrideWith(() => _TestProfileEditNotifier(_profile())),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(profileEditProvider(_userId).notifier);

    await notifier.reconcileMatchPreferences();

    final updated = notifier.state.value;
    expect(updated!.agePreferences['romantic'], [30.0, 45.0]);
    expect(updated.genderPreferences['romantic'], ['female']);
  });
}
