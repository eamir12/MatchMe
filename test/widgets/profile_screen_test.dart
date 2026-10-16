import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/screens/profile/profile_screen.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/utils/profile_sync_result.dart';
import 'package:matchme/widgets/app_recovery_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'test-user';

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
    genderPreferences: const {},
    agePreferences: const {},
    lifestyleFilters: const {},
    familyFilters: const {},
    religionFilters: const {},
    heightPreferences: const {},
    photos: const [],
  );
}

class _StubProfileSyncStateNotifier extends ProfileSyncStateNotifier {
  _StubProfileSyncStateNotifier(this.initialState) : super(_userId);

  final ProfileSyncState initialState;

  @override
  ProfileSyncState build() => initialState;
}

class _StubProfileSyncService extends ProfileSyncService {
  _StubProfileSyncService(super.ref, this.onSync);

  final void Function(String userId, String source) onSync;

  @override
  Future<ProfileSyncResult> syncProfile(
    String userId, {
    String source = '',
  }) async {
    onSync(userId, source);
    return const ProfileSyncResult(
      status: ProfileSyncStatus.synced,
      cacheAvailable: true,
      cacheUpdated: true,
    );
  }
}

class _TestUnitSystem extends UnitSystem {
  @override
  Future<bool> build() async => false;
}

/// ProfileScreen keeps the rating realtime listener alive so the signed-in
/// user's own rating updates immediately. The real notifier schedules a
/// periodic poll timer, which the widget tester rejects as a leaked timer, so
/// tests use this timer-free stub.
class _NoopRatingSummaryRealtimeNotifier
    extends RatingSummaryRealtimeNotifier {
  @override
  int build() => 0;
}

class _StubAppConfigNotifier extends AppConfigNotifier {
  @override
  Map<String, String> build() => const {
    'ads.external.enabled': 'false',
    'ads.internal.enabled': 'false',
    'ads.display_order': 'external_first',
  };
}

Widget _buildApp({
  required ProfileSyncState syncState,
  required void Function(String userId, String source) onSync,
  bool online = true,
}) {
  return ProviderScope(
    overrides: [
      localizationProvider.overrideWithValue(LocalizationState.loading()),
      unitSystemProvider.overrideWith(_TestUnitSystem.new),
      localUserProfileProvider(
        _userId,
      ).overrideWith((ref) => Stream.value(_profile())),
      profileSyncStateProvider(
        _userId,
      ).overrideWith(() => _StubProfileSyncStateNotifier(syncState)),
      profileSyncProvider.overrideWith(
        (ref) => _StubProfileSyncService(ref, onSync),
      ),
      allIntentsProvider.overrideWith((ref) async => const []),
      allInterestsProvider.overrideWith((ref) async => const []),
      genderOptionsProvider.overrideWith((ref) async => const []),
      languageOptionsProvider.overrideWith((ref) async => const []),
      userRatingSummaryProvider(_userId).overrideWith(
        (ref) async => const UserRatingSummary(
          ratedByCount: 0,
          q1Avg: null,
          q2Avg: null,
          q3Avg: null,
          q4Avg: null,
          q5Avg: null,
          overallAvg: null,
        ),
      ),
      ratingQuestionsProvider.overrideWith(
        (ref) async => const <RatingQuestion>[],
      ),
      ratingSummaryRealtimeProvider.overrideWith(
        _NoopRatingSummaryRealtimeNotifier.new,
      ),
      appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
      externalAdsRealtimeProvider.overrideWith((ref) {}),
      externalAdsEnabledProvider.overrideWithValue(false),
      internalAdsEnabledProvider.overrideWithValue(false),
      adDisplayOrderProvider.overrideWithValue('external_first'),
      connectivityProvider.overrideWithValue(AsyncData(online)),
    ],
    child: const MaterialApp(home: ProfileScreen()),
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
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('[]', 200);
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _fakeAccessToken(),
    );
  });

  testWidgets('Profile renders a failed refresh without a banner', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _buildApp(
        syncState: const ProfileSyncState(
          result: ProfileSyncResult(
            status: ProfileSyncStatus.failed,
            cacheAvailable: true,
          ),
        ),
        onSync: (_, source) => calls.add(source),
      ),
    );
    await tester.pumpAndSettle();

    // The banner is gone, so there is no retry affordance on this screen.
    // Cached content still renders, which is the point of the change.
    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(find.text('Profile data may be out of date'), findsNothing);
    expect(find.textContaining('Test User'), findsWidgets);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Profile hides the banner for a fresh cached profile', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        syncState: const ProfileSyncState(
          result: ProfileSyncResult(
            status: ProfileSyncStatus.synced,
            cacheAvailable: true,
          ),
        ),
        onSync: (_, _) {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Profile renders cached data without a mount-time sync', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _buildApp(
        syncState: const ProfileSyncState(),
        onSync: (_, source) => calls.add(source),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Test User'), findsWidgets);
    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Profile does not warn about being offline on its own', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _buildApp(
        syncState: const ProfileSyncState(),
        onSync: (_, source) => calls.add(source),
        online: false,
      ),
    );
    await tester.pumpAndSettle();

    // Offline is a legitimate state (the app bar already reports it), so the
    // stale banner only appears once a refresh actually failed with cache.
    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Profile never shows the stale banner', (tester) async {
    // The "Profile data may be out of date" banner was removed from the
    // profile screen on 2026-09-28. A failed refresh with a cached profile is
    // still a supported state, and it must not surface a red banner here.
    final calls = <String>[];
    await tester.pumpWidget(
      _buildApp(
        syncState: const ProfileSyncState(
          result: ProfileSyncResult(
            status: ProfileSyncStatus.failed,
            cacheAvailable: true,
          ),
        ),
        onSync: (_, source) => calls.add(source),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(find.text('Profile data may be out of date'), findsNothing);
    // Cached content is still rendered underneath.
    expect(find.textContaining('Test User'), findsWidgets);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Profile shows no stale banner while syncing', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _buildApp(
        syncState: const ProfileSyncState(
          isSyncing: true,
          result: ProfileSyncResult(
            status: ProfileSyncStatus.failed,
            cacheAvailable: true,
          ),
        ),
        onSync: (_, source) => calls.add(source),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
