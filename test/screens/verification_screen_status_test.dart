import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/voice_guidance_provider.dart';
import 'package:matchme/screens/profile/verification_screen.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/utils/profile_sync_result.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'test-user';

const _verificationPhotoPath = 'test-user/verification.jpg';

/// The payload the server returns for an auto-rejected verification.
const _rejectedPayload = <String, dynamic>{
  'is_verified': false,
  'verification_status': 'rejected',
  'verification_auto_rejected': true,
  'verification_similarity_score': 0.12,
  'verification_photo_path': _verificationPhotoPath,
  'verification_ai_analysis': <String, dynamic>{
    'reasoning':
        'The verification photo shows an entirely different individual (a man) '
        'compared to the profile photo (a woman).',
    'mismatchRegions': <Map<String, dynamic>>[
      <String, dynamic>{
        'feature': 'eyes',
        'description': 'Eye shape does not match.',
        'profileBox': <String, dynamic>{
          'x': 0.3,
          'y': 0.4,
          'width': 0.2,
          'height': 0.1,
        },
        'verificationBox': <String, dynamic>{
          'x': 0.3,
          'y': 0.4,
          'width': 0.2,
          'height': 0.1,
        },
      },
    ],
  },
};

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
    activeModes: const ['romamic'],
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
    photos: const ['test-user/profile.jpg'],
    verificationStatus: 'rejected',
  );
}

class _StubProfileSyncService extends ProfileSyncService {
  _StubProfileSyncService(super.ref);

  @override
  Future<ProfileSyncResult> syncProfile(
    String userId, {
    String source = '',
  }) async {
    return const ProfileSyncResult(
      status: ProfileSyncStatus.synced,
      cacheAvailable: true,
      cacheUpdated: true,
    );
  }
}

/// The real notifier schedules an asynchronous prefs load, which leaves a
/// pending timer behind when the test ends.
class _StubVoiceGuidanceNotifier extends VoiceGuidanceEnabledNotifier {
  @override
  bool build() => false;
}

/// Counts how often the text is handed to the translation service.
class _CountingTranslationService implements TranslationService {
  int calls = 0;
  final List<String> texts = <String>[];

  @override
  Future<String> identifyLanguage(String text) async => 'en';

  @override
  Future<String> translateText(
    String text,
    String sourceLang,
    String targetLang, {
    String? recipientGender,
    String? speakerGender,
  }) async {
    calls++;
    texts.add(text);
    return 'translated: $text';
  }

  @override
  Future<bool> isModelDownloaded(String langCode) async => true;

  @override
  Future<bool> downloadModel(String langCode) async => true;

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Completer for the server answer, so the test can hold the network back
  /// and prove the screen renders from the on-device copy alone.
  Completer<void>? gate;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      // The screen must find the rejection on disk, exactly as it was left
      // there by the last successful read from the server.
      'verification_status_cache_$_userId': jsonEncode(_rejectedPayload),
    });
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
        if (request.url.path.endsWith('/rest/v1/users')) {
          // The server copy of the status: held back on purpose.
          await gate?.future;
          return http.Response(
            jsonEncode(_rejectedPayload),
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
    // No speech in a test: the screen announces its content out loud.
    await VoiceGuidanceService.instance.setEnabled(false);
  });

  setUp(() {
    gate = Completer<void>();
  });

  /// Lets the held-back request finish so no timer outlives the test.
  Future<void> releaseServer(WidgetTester tester) async {
    if (gate != null && !gate!.isCompleted) {
      gate!.complete();
    }
    await tester.pump();
    // Flush the timeout that guards the request, so no timer is left over.
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }

  Widget buildApp({
    Locale locale = const Locale('en'),
    TranslationService? translationService,
  }) {
    return ProviderScope(
      overrides: [
        localizationProvider.overrideWithValue(
          LocalizationState(
            currentLocale: locale,
            textDirection: TextDirection.ltr,
            strings: const {},
            supportedLanguages: const [],
          ),
        ),
        if (translationService != null)
          translationServiceProvider.overrideWithValue(translationService),
        userProfileProvider(
          _userId,
        ).overrideWith((ref) => Stream.value(_profile())),
        profileSyncProvider.overrideWith((ref) => _StubProfileSyncService(ref)),
        voiceGuidanceEnabledProvider.overrideWith(
          _StubVoiceGuidanceNotifier.new,
        ),
      ],
      child: const MaterialApp(home: VerificationScreen()),
    );
  }

  testWidgets(
    'the rejection details are on screen before the server answers',
    (tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pump();

      // The server has not answered yet — the screen must already show the
      // full result from the on-device copy.
      expect(
        find.text(
          'AI detected that the verification photo does not match your profile photo.',
        ),
        findsOneWidget,
      );
      expect(find.text('AI Analysis'), findsOneWidget);
      expect(
        find.textContaining('entirely different individual'),
        findsOneWidget,
      );
      expect(find.text('Verification photo'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SignedImage && widget.source == _verificationPhotoPath,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await releaseServer(tester);
    },
  );

  testWidgets('the cached rejection survives a restart of the screen', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    // Leave the screen and come back: the rejection is still fully visible
    // without waiting for the server.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.text('AI Analysis'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SignedImage && widget.source == _verificationPhotoPath,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await releaseServer(tester);
  });

  testWidgets('the rejection text is sent to the translator only once', (
    tester,
  ) async {
    final service = _CountingTranslationService();

    await tester.pumpWidget(
      buildApp(locale: const Locale('he'), translationService: service),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // One request for the AI analysis, one for the single mismatch region.
    expect(service.calls, 2);
    expect(
      service.texts,
      containsAll(<String>[
        'The verification photo shows an entirely different individual (a man) '
            'compared to the profile photo (a woman).',
        'Eye shape does not match.',
      ]),
    );

    // Leaving the screen and coming back must not send the text again.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(
      buildApp(locale: const Locale('he'), translationService: service),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      service.calls,
      2,
      reason: 'the cached translation must be reused, not sent again',
    );
    expect(tester.takeException(), isNull);

    await releaseServer(tester);
  });
}
