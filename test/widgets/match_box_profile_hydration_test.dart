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

  testWidgets(
    'match card spells out "Verified" next to a verified profile',
    (tester) async {
      final now = DateTime.now();
      final match = MatchModel(
        id: 'verified-match',
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
        strings: const {},
        supportedLanguages: const [],
      );
      final verifiedProfile = UserProfile.fromMap({
        'id': _otherUserId,
        'name': 'Alexandra Example',
        'photos': ['https://example.com/avatar.jpg?token=valid'],
        'is_verified': true,
        // Puts an age on the meta line so the pill has a line to share.
        'date_of_birth': '2000-01-01',
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWith(() => _TestLocalization(l10n)),
            otherUserProfileProvider(
              _otherUserId,
            ).overrideWith((ref) => Future.value(verifiedProfile)),
            userProfileProvider(_currentUserId).overrideWith(
              (ref) => Stream.value(_profile(_currentUserId, 'Viewer Example')),
            ),
            userChatIdsProvider(
              _currentUserId,
            ).overrideWith((ref) => Stream.value(<String>{})),
            recentChatsProvider(_currentUserId).overrideWith(
              (ref) => Stream.value([
                ChatModel.fromJsonRpc({
                  'match_id': 'verified-match',
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
      await tester.pump();

      // The word is the status mark: the photo no longer carries its own
      // check, and the label rides the age/gender line instead of the name.
      expect(find.text('Verified'), findsOneWidget);
      expect(find.byIcon(Icons.verified), findsWidgets);
      expect(find.byIcon(Icons.check_rounded), findsNothing);

      final ageFinder = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.style?.fontSize == 13 &&
            RegExp(r'^\d{1,3}$').hasMatch(widget.data ?? ''),
      );
      expect(ageFinder, findsOneWidget, reason: 'expected an age on the card');

      Wrap? metaWrap;
      tester.element(ageFinder).visitAncestorElements((ancestor) {
        if (ancestor.widget is Wrap) {
          metaWrap = ancestor.widget as Wrap;
          return false;
        }
        return true;
      });
      expect(metaWrap, isNotNull, reason: 'the age sits inside a wrap');
      expect(
        find.descendant(
          of: find.byWidget(metaWrap!),
          matching: find.text('Verified'),
        ),
        findsOneWidget,
        reason: 'Verified must share the age/gender line',
      );

      final verifiedText = tester.widget<Text>(find.text('Verified'));
      expect(verifiedText.style?.fontSize, greaterThanOrEqualTo(12));
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 11));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 51));
    },
  );

  testWidgets(
    'match card keeps age and gender readable on a narrow phone with badges',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now();
      final match = MatchModel(
        id: 'narrow-match',
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
        strings: const {'gender_male': 'Male'},
        supportedLanguages: const [],
      );
      final fullProfile = UserProfile.fromMap({
        'id': _otherUserId,
        'name': 'Eran Example',
        'photos': const ['https://example.com/avatar.jpg?token=valid'],
        'is_verified': true,
        'date_of_birth': '1979-01-01',
        'gender': 'male',
        'profile_completeness': 100,
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWith(() => _TestLocalization(l10n)),
            otherUserProfileProvider(
              _otherUserId,
            ).overrideWith((ref) => Future.value(fullProfile)),
            userProfileProvider(_currentUserId).overrideWith(
              (ref) => Stream.value(_profile(_currentUserId, 'Viewer Example')),
            ),
            userChatIdsProvider(
              _currentUserId,
            ).overrideWith((ref) => Stream.value(<String>{})),
            recentChatsProvider(_currentUserId).overrideWith(
              (ref) => Stream.value([
                ChatModel.fromJsonRpc({
                  'match_id': 'narrow-match',
                  'other_user_id': _otherUserId,
                  'other_user_name': 'Eran Example',
                  'other_user_photos': const <String>[],
                  'last_message_at': now.toIso8601String(),
                }),
              ]),
            ),
            matchExpiryNowProvider.overrideWith(
              (ref) => Stream.value(now),
            ),
            userRatingSummaryProvider(_otherUserId).overrideWith(
              (ref) async => const UserRatingSummary(
                ratedByCount: 3,
                q1Avg: 3.8,
                q2Avg: 3.8,
                q3Avg: 3.8,
                q4Avg: 3.8,
                q5Avg: 3.8,
                overallAvg: 3.8,
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

      final metaFinder = find.text('47  ·  Male');
      expect(metaFinder, findsOneWidget);
      expect(
        tester.getSize(metaFinder).height,
        lessThan(40),
        reason: 'badges must wrap below the age/gender text, not squeeze it '
            'into a one-character-wide column',
      );
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Complete'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 11));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 51));
    },
  );
}
