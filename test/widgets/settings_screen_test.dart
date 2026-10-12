import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/screens/settings/settings_screen.dart';
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

class _TestProfileEditNotifier extends ProfileEditNotifier {
  _TestProfileEditNotifier(this.profile);

  final UserProfile profile;

  @override
  AsyncValue<UserProfile?> build(String userId) => AsyncData(profile);

  @override
  Future<void> loadInitialProfile({bool applyWizardDraft = false}) async {}
}

class _TestUserPreferencesNotifier extends UserPreferencesNotifier {
  @override
  UserPreferencesState build() => UserPreferencesState.defaults();
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
      profileEditProvider(
        _userId,
      ).overrideWith(() => _TestProfileEditNotifier(_profile())),
      profileSyncStateProvider(
        _userId,
      ).overrideWith(() => _StubProfileSyncStateNotifier(syncState)),
      profileSyncProvider.overrideWith(
        (ref) => _StubProfileSyncService(ref, onSync),
      ),
      connectivityProvider.overrideWithValue(AsyncData(online)),
      appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
      userPreferencesProvider.overrideWith(_TestUserPreferencesNotifier.new),
    ],
    child: const MaterialApp(home: SettingsScreen()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Accent of the settings menu card that leads with [icon]: the card's
  /// gradient is painted entirely from the category accent.
  Color cardAccent(WidgetTester tester, IconData icon) {
    final card = tester
        .widgetList<Container>(
          find.ancestor(of: find.byIcon(icon), matching: find.byType(Container)),
        )
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).gradient != null,
        );
    final gradient = (card.decoration! as BoxDecoration).gradient!;
    return (gradient as LinearGradient).colors.first;
  }

  /// Text color of a section header.
  Color? headerAccent(WidgetTester tester, String title) =>
      tester.widget<Text>(find.text(title)).style?.color;

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

  testWidgets('Settings never shows the stale profile banner', (tester) async {
    // The "Profile data may be out of date" banner was removed from the
    // settings screen. A failed refresh with a cached profile is still a
    // supported state, and it must not surface a red banner here.
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
    await tester.pump();

    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(find.text('Profile data may be out of date'), findsNothing);
    expect(
      find.textContaining('Showing the last saved version.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings hides the banner for a fresh cached profile', (
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
    await tester.pump();

    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings does not warn about being offline on its own', (
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
    await tester.pump();
    calls.clear();

    // The app bar already reports the connection state, so offline alone must
    // not raise the stale banner; only a failed refresh with cache does.
    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings shows no stale banner while syncing', (tester) async {
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
    calls.clear();

    expect(find.byType(AppRecoveryBanner), findsNothing);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings gives each category one accent, header included', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(syncState: const ProfileSyncState(), onSync: (_, _) {}),
    );
    await tester.pump();
    await tester.pump();

    final general = cardAccent(tester, Icons.school_outlined); // App tour
    final generalDisplay = cardAccent(tester, Icons.settings_display);
    final matching = cardAccent(tester, Icons.favorite_border);
    final matchingPrefs = cardAccent(tester, Icons.people_alt_outlined);

    // Every card inside a category shares that category's accent…
    expect(generalDisplay, general);
    expect(matchingPrefs, matching);
    // …and different categories are visually distinct.
    expect(matching, isNot(general));

    // Section headers are tinted with their own category's accent (the card
    // gradient carries the same hue at a low alpha).
    expect(
      headerAccent(tester, 'General')?.withValues(alpha: 1),
      general.withValues(alpha: 1),
    );
    expect(
      headerAccent(tester, 'Matching & discovery')?.withValues(alpha: 1),
      matching.withValues(alpha: 1),
    );

    expect(tester.takeException(), isNull);
  });
}
