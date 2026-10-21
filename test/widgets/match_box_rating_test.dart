// Regression test for the rating placement on a match card
// (lib/widgets/match_box.dart):
//
// The rating used to sit at the top-right of the card, next to the name,
// and took ~60px of the name's column — so a name that was not one short
// word wrapped onto a second line. It now rides on the meta line (age ·
// gender), which is two short tokens, and the name gets the whole column.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _currentUserId = 'rating-viewer';
const _otherUserId = 'rating-partner';
const _longName = 'Aleksandra Konstantinova V.';

String _accessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': _currentUserId, 'iat': now, 'exp': now + 3600})}.sig';
}

UserProfile _profile(String id, String name) {
  return UserProfile.fromMap({
    'id': id,
    'name': name,
    'photos': <String>[],
    'personal_interests': <String, List<String>>{},
    'dateOfBirth': '2000-01-01',
    'gender': 'male',
  });
}

LocalizationState _l10n() => LocalizationState(
  currentLocale: const Locale('en'),
  textDirection: TextDirection.ltr,
  strings: const {'generalUnknown': 'Unknown'},
  supportedLanguages: const [],
);

/// The localization provider is a notifier provider; the auth flow asks it
/// to sync the language after a session is restored.
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
  });

  testWidgets('the rating shares the meta line with the age and gender', (
    tester,
  ) async {
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _accessToken(),
    );
    final now = DateTime.now();
    final match = MatchModel(
      id: 'rating-match',
      userAId: _currentUserId,
      userBId: _otherUserId,
      otherUserId: _otherUserId,
      matchedIntent: 'friendship',
      matchType: 'manual_test',
      createdAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWith(() => _TestLocalization(_l10n())),
          otherUserProfileProvider(
            _otherUserId,
          ).overrideWith((ref) => Future.value(_profile(_otherUserId, _longName))),
          userProfileProvider(
            _currentUserId,
          ).overrideWith((ref) => Stream.value(_profile(_currentUserId, 'Viewer'))),
          userChatIdsProvider(
            _currentUserId,
          ).overrideWith((ref) => Stream.value(<String>{})),
          recentChatsProvider(_currentUserId).overrideWith(
            (ref) => Stream.value([]),
          ),
          matchExpiryNowProvider.overrideWith((ref) => Stream.value(now)),
          userRatingSummaryProvider(_otherUserId).overrideWith(
            (ref) async => const UserRatingSummary(
              ratedByCount: 3,
              q1Avg: null,
              q2Avg: null,
              q3Avg: null,
              q4Avg: null,
              q5Avg: null,
              overallAvg: 4.5,
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: MatchBox(match: match)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The rating is painted.
    final rating = find.text('4.5');
    expect(rating, findsOneWidget);

    // The meta line carries the age and the gender.
    final meta = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains('·'),
    );
    expect(meta, findsOneWidget);

    // Both live on the same row.
    final ratingRect = tester.getRect(rating);
    final metaRect = tester.getRect(meta);
    expect(
      (ratingRect.center.dy - metaRect.center.dy).abs(),
      lessThan(6),
      reason: 'the rating must ride on the meta line, not on the name row',
    );

    // And the name keeps its own row above them, with the whole column to
    // itself.
    final name = find.textContaining(_longName);
    expect(name, findsOneWidget);
    final nameRect = tester.getRect(name);
    expect(nameRect.overlaps(ratingRect), isFalse);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 51));
  });
}


