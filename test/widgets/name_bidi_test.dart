import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/widgets/chat_list_item.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _currentUserId = 'bidi-viewer';
const _otherUserId = 'bidi-partner';

const _hebrewName = 'דוד ליאור';
const _latinName = 'John Doe';

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

LocalizationState _l10n(TextDirection direction) => LocalizationState(
  currentLocale: Locale(direction == TextDirection.rtl ? 'he' : 'en'),
  textDirection: direction,
  strings: const {'generalUnknown': 'Unknown'},
  supportedLanguages: const [],
);

/// Lays [name] out the way a [Text] with [direction] would and reports
/// whether the trailing period sits left of every Hebrew glyph — the
/// placement a Hebrew reader expects, and the one the matched profile
/// screen produces.
bool _periodSitsLeftOfName(String name, TextDirection direction) {
  final painter = TextPainter(
    text: TextSpan(text: name, style: const TextStyle(fontSize: 16)),
    textDirection: direction,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: 400);

  double leftOf(int index) => painter
      .getBoxesForSelection(
        TextSelection(baseOffset: index, extentOffset: index + 1),
      )
      .first
      .left;

  final period = leftOf(name.indexOf('.'));
  final hebrewLefts = <double>[
    for (var i = 0; i < name.length; i++)
      if (name.codeUnitAt(i) >= 0x0590 && name.codeUnitAt(i) <= 0x05FF)
        leftOf(i),
  ];
  if (hebrewLefts.isEmpty) return false;
  return period < hebrewLefts.reduce((a, b) => a < b ? a : b);
}

Text _nameText(WidgetTester tester, String name) {
  final texts = tester.widgetList<Text>(
    find.byWidgetPredicate((w) => w is Text && w.data == name),
  );
  expect(
    texts,
    isNotEmpty,
    reason: 'no Text rendered the display name "$name"',
  );
  return texts.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('en');
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
    // No session here: with a signed-in user the chat row subscribes to the
    // realtime typing channel (and its expiry timers), which the row tests do
    // not want. The match card test signs in itself, since it needs a user id.
  });

  group('name layout helper', () {
    test('a Hebrew name lays out RTL so its period stays with the initial', () {
      final name = _hebrewName.formatAsFirstNameLastInitial();
      final layout = name.displayTextLayout(TextDirection.ltr);

      expect(layout.textDirection, TextDirection.rtl);
      expect(layout.textAlign, TextAlign.left);
      expect(
        _periodSitsLeftOfName(name, layout.textDirection),
        isTrue,
        reason: 'the period must land left of the name, not past its end',
      );
      // The direction the UI language used to impose gets the placement wrong,
      // which is why the name cannot simply inherit the ambient direction.
      expect(_periodSitsLeftOfName(name, TextDirection.ltr), isFalse);
    });

    test('a Hebrew name keeps its right edge in a Hebrew UI', () {
      final layout = _hebrewName
          .formatAsFirstNameLastInitial()
          .displayTextLayout(TextDirection.rtl);

      expect(layout.textDirection, TextDirection.rtl);
      expect(layout.textAlign, TextAlign.right);
    });

    test('a Latin name lays out LTR in both UI directions', () {
      final name = _latinName.formatAsFirstNameLastInitial();

      final inEnglishUi = name.displayTextLayout(TextDirection.ltr);
      expect(inEnglishUi.textDirection, TextDirection.ltr);
      expect(inEnglishUi.textAlign, TextAlign.left);

      final inHebrewUi = name.displayTextLayout(TextDirection.rtl);
      expect(inHebrewUi.textDirection, TextDirection.ltr);
      expect(inHebrewUi.textAlign, TextAlign.right);
    });
  });

  group('recent chats row', () {
    testWidgets('lays a Hebrew name out RTL in an English UI', (tester) async {
      final chat = ChatModel(
        matchId: 'bidi-chat-ltr',
        otherUserId: _otherUserId,
        otherUserName: 'Alex Example',
        lastMessage: 'Hello',
        lastMessageId: 'message-ltr',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 0,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(_l10n(TextDirection.ltr)),
            otherUserProfileProvider(
              _otherUserId,
            ).overrideWith((ref) => Future<UserProfile?>.value(_profile(
              _otherUserId,
              _hebrewName,
            ))),
          ],
          child: MaterialApp(
            home: Scaffold(body: ChatListItem(chat: chat)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final name = _hebrewName.formatAsFirstNameLastInitial();
      final text = _nameText(tester, name);
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textAlign, TextAlign.left);
      expect(_periodSitsLeftOfName(name, text.textDirection!), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps a Hebrew name right-aligned in a Hebrew UI', (
      tester,
    ) async {
      final chat = ChatModel(
        matchId: 'bidi-chat-rtl',
        otherUserId: _otherUserId,
        otherUserName: 'Alex Example',
        lastMessage: 'שלום',
        lastMessageId: 'message-rtl',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 0,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(_l10n(TextDirection.rtl)),
            otherUserProfileProvider(
              _otherUserId,
            ).overrideWith((ref) => Future<UserProfile?>.value(_profile(
              _otherUserId,
              _hebrewName,
            ))),
          ],
          child: MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(body: ChatListItem(chat: chat)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final name = _hebrewName.formatAsFirstNameLastInitial();
      final text = _nameText(tester, name);
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textAlign, TextAlign.right);
      expect(_periodSitsLeftOfName(name, text.textDirection!), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('recent matches card', () {
    testWidgets('lays a Hebrew name out RTL in an English UI', (tester) async {
      await Supabase.instance.client.auth.setSession(
        'test-refresh-token',
        accessToken: _accessToken(),
      );
      final now = DateTime.now();
      final match = MatchModel(
        id: 'bidi-match',
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
            localizationProvider.overrideWith(
              () => _TestLocalization(_l10n(TextDirection.ltr)),
            ),
            otherUserProfileProvider(
              _otherUserId,
            ).overrideWith((ref) => Future.value(_profile(_otherUserId, _hebrewName))),
            userProfileProvider(
              _currentUserId,
            ).overrideWith((ref) => Stream.value(_profile(_currentUserId, 'Viewer Example'))),
            userChatIdsProvider(
              _currentUserId,
            ).overrideWith((ref) => Stream.value(<String>{})),
            recentChatsProvider(_currentUserId).overrideWith(
              (ref) => Stream.value([
                ChatModel.fromJsonRpc({
                  'match_id': 'bidi-match',
                  'other_user_id': _otherUserId,
                  'other_user_name': 'Alex Example',
                  'other_user_photos': <String>[],
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

      final name = _hebrewName.formatAsFirstNameLastInitial();
      final text = _nameText(tester, name);
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textAlign, TextAlign.left);
      expect(_periodSitsLeftOfName(name, text.textDirection!), isTrue);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 11));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 51));
    });
  });
}
