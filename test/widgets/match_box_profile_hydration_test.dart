import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _currentUserId = 'match-card-viewer';
const _otherUserId = 'match-card-partner';

String _accessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': _currentUserId, 'iat': now, 'exp': now + 3600})}.sig';
}

UserProfile _profile(
  String id,
  String name, {
  List<String> photos = const [],
  Map<String, List<String>> personalInterests = const {},
}) {
  return UserProfile.fromMap({
    'id': id,
    'name': name,
    'photos': photos,
    'personal_interests': personalInterests,
  });
}

class _TestLocalization extends Localization {
  _TestLocalization(this.testState);

  final LocalizationState testState;

  @override
  LocalizationState build() => testState;

  @override
  Future<void> syncLanguageAfterLogin() async {}
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
              'id': _currentUserId,
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
        return http.Response('[]', 200, request: request);
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _accessToken(),
    );
  });

  testWidgets(
    'match card renders hydrated name, photo, and shared-interest count',
    (tester) async {
      final gate = Completer<UserProfile?>();
      final currentProfile = _profile(
        _currentUserId,
        'Viewer Example',
        personalInterests: {
          'friendship': ['hiking', 'music'],
        },
      );
      final now = DateTime.now();
      final match = MatchModel(
        id: 'hydrated-match',
        userAId: _currentUserId,
        userBId: _otherUserId,
        otherUserId: _otherUserId,
        matchedIntent: 'friendship',
        matchType: 'manual_test',
        createdAt: now,
      );
      final l10n = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {
          'generalUnknown': 'Unknown',
          'sharedInterestsCount': 'Shared interests: {count}',
        },
        supportedLanguages: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWith(() => _TestLocalization(l10n)),
            otherUserProfileProvider(_otherUserId).overrideWith(
              (ref) => gate.future,
            ),
            userProfileProvider(_currentUserId).overrideWith(
              (ref) => Stream.value(currentProfile),
            ),
            userChatIdsProvider(
              _currentUserId,
            ).overrideWith((ref) => Stream.value(<String>{})),
              recentChatsProvider(_currentUserId).overrideWith(
                (ref) => Stream.value([
                  ChatModel.fromJsonRpc({
                    'match_id': 'hydrated-match',
                    'other_user_id': _otherUserId,
                    'other_user_name': 'Alex Example',
                    'other_user_photos': [
                      'https://example.com/cached-avatar.jpg?token=valid',
                    ],
                    'last_message_at': now.toIso8601String(),
                  }),
                ]),
              ),
              matchExpiryNowProvider.overrideWith(
              (ref) => Stream.value(now),
            ),
            userRatingSummaryProvider(_otherUserId).overrideWith(
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
          ],
          child: MaterialApp(
            home: Scaffold(body: MatchBox(match: match)),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Alex E.'), findsOneWidget);
      expect(find.textContaining('Shared interests: 2'), findsNothing);
      expect(find.byType(SignedImage), findsOneWidget);

      gate.complete(
        _profile(
          _otherUserId,
          'Alexandra Example',
          photos: ['https://example.com/avatar.jpg?token=valid'],
          personalInterests: {
            'friendship': ['hiking', 'music'],
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Alexandra E.'), findsOneWidget);
      expect(find.textContaining('Shared interests: 2'), findsOneWidget);
      expect(find.byType(SignedImage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 51));
    },
  );
}
