import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/screens/settings/match_preferences_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _fakeAccessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) {
    return base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  }

  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({'sub': 'test-user', 'iat': now, 'exp': now + 3600});
  return '$header.$payload.c2ln';
}

UserProfile _profile() {
  return UserProfile(
    id: 'test-user',
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

class _TestUnitSystem extends UnitSystem {
  @override
  Future<bool> build() async => false;
}

class _TestProfileEditNotifier extends ProfileEditNotifier {
  _TestProfileEditNotifier(this.profile);

  final UserProfile profile;
  static int saveCalls = 0;

  @override
  AsyncValue<UserProfile?> build(String userId) => AsyncData(profile);

  @override
  Future<void> updateGenderAgePreferences(
    Map<String, List<String>> genderPreferences,
    Map<String, List<double>> agePreferences,
  ) async {
    saveCalls++;
  }

  @override
  Future<void> updateLifestyleFilters(
    Map<String, Map<String, dynamic>> filters,
  ) async {}

  @override
  Future<void> updateFamilyFilters(
    Map<String, Map<String, dynamic>> filters,
  ) async {}

  @override
  Future<void> updateReligionFilters(
    Map<String, Map<String, dynamic>> filters,
  ) async {}

  @override
  Future<void> updateHeightPreferences(
    Map<String, Map<String, dynamic>> prefs,
  ) async {}
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
              'id': 'test-user',
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

  testWidgets(
    'an invalid active gender preference blocks the write and explains why',
    (tester) async {
      _TestProfileEditNotifier.saveCalls = 0;
      final profile = _profile();
      final l10n = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {
          'intent.romantic': 'Romantic',
          'settingsCopyFromProfile': 'Copy from profile',
          'settingsPreferredGenders': 'Preferred genders',
          'Female': 'Female',
          'profileWizardGenderPreferenceRequired':
              'Please select at least one preferred gender for {intent}.',
        },
        supportedLanguages: [AppLanguage(code: 'en', displayName: 'English')],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(l10n),
            mainIntentsProvider.overrideWithValue([
              AppIntent(
                id: 1,
                key: 'romantic',
                translationKey: 'intent.romantic',
                sortOrder: 0,
                isSocial: true,
              ),
            ]),
            genderOptionsProvider.overrideWith(
              (ref) async => [
                {'key': 'female', 'displayKey': 'Female'},
              ],
            ),
            profileOptionsProvider.overrideWith((ref) async => const []),
            unitSystemProvider.overrideWith(_TestUnitSystem.new),
            userProfileProvider(
              'test-user',
            ).overrideWith((ref) => Stream.value(profile)),
            profileEditProvider(
              'test-user',
            ).overrideWith(() => _TestProfileEditNotifier(profile)),
          ],
          child: const MaterialApp(home: MatchPreferencesScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The screen has no Save button: every control commits itself. While
      // the preferences are invalid nothing may be written, and the reason
      // has to be explained.
      await tester.tap(find.text('Copy from profile'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Please select at least one preferred gender for Romantic.'),
        findsWidgets,
      );
      expect(_TestProfileEditNotifier.saveCalls, 0);
      expect(
        find.bySemanticsLabel(
          'Please select at least one preferred gender for Romantic.',
        ),
        findsWidgets,
      );
    },
  );

  testWidgets('selecting a gender commits the preferences immediately', (
    tester,
  ) async {
    _TestProfileEditNotifier.saveCalls = 0;
    final profile = _profile();
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {
        'intent.romantic': 'Romantic',
        'settingsCopyFromProfile': 'Copy from profile',
        'settingsPreferredGenders': 'Preferred genders',
        'Female': 'Female',
        'profileWizardGenderPreferenceRequired':
            'Please select at least one preferred gender for {intent}.',
      },
      supportedLanguages: [AppLanguage(code: 'en', displayName: 'English')],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          mainIntentsProvider.overrideWithValue([
            AppIntent(
              id: 1,
              key: 'romantic',
              translationKey: 'intent.romantic',
              sortOrder: 0,
              isSocial: true,
            ),
          ]),
          genderOptionsProvider.overrideWith(
            (ref) async => [
              {'key': 'female', 'displayKey': 'Female'},
            ],
          ),
          profileOptionsProvider.overrideWith((ref) async => const []),
          unitSystemProvider.overrideWith(_TestUnitSystem.new),
          userProfileProvider(
            'test-user',
          ).overrideWith((ref) => Stream.value(profile)),
          profileEditProvider(
            'test-user',
          ).overrideWith(() => _TestProfileEditNotifier(profile)),
        ],
        child: const MaterialApp(home: MatchPreferencesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // There is no Save button on this screen.
    expect(find.text('Save'), findsNothing);

    await tester.tap(find.text('Female'));
    await tester.pump();
    await tester.pump();

    expect(_TestProfileEditNotifier.saveCalls, 1);
  });
}
