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
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/notifications/notification_inbox_screen.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/services/notification_inbox_service.dart';
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

/// An inbox that only serves the rows a test hands it — the real notifier
/// talks to Supabase and the local cache.
class _FakeInboxNotifier extends NotificationInboxNotifier {
  _FakeInboxNotifier(this.items);

  final List<NotificationInboxItem> items;

  @override
  NotificationInboxState build() =>
      NotificationInboxState(items: items, isLoading: false);
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

/// Lays [text] out the way a [Text] with [direction] would and reports whether
/// the trailing punctuation sits to the right of every Latin glyph — the
/// placement a Latin reader expects, and the one every screen of the app
/// produces.
bool _punctuationSitsRightOfName(String text, TextDirection direction) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontSize: 16)),
    textDirection: direction,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: 400);

  double leftOf(int index) => painter
      .getBoxesForSelection(
        TextSelection(baseOffset: index, extentOffset: index + 1),
      )
      .first
      .left;

  var punctuationIndex = -1;
  for (var i = text.length - 1; i >= 0; i--) {
    if ('.!?'.contains(text[i])) {
      punctuationIndex = i;
      break;
    }
  }
  if (punctuationIndex < 0) return false;
  final punctuation = leftOf(punctuationIndex);
  final latinLefts = <double>[
    for (var i = 0; i < text.length; i++)
      if (RegExp(r'[A-Za-z]').hasMatch(text[i])) leftOf(i),
  ];
  if (latinLefts.isEmpty) return false;
  return punctuation > latinLefts.reduce((a, b) => a > b ? a : b);
}

/// The [Text] widget that rendered [needle] (the text may carry the invisible
/// bidi marks the app adds around a name).
Text _textContaining(WidgetTester tester, String needle) {
  final texts = tester.widgetList<Text>(
    find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(needle)),
  );
  expect(texts, isNotEmpty, reason: 'no Text rendered "$needle"');
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
      // The name carries the mark of its own script, so its period stays with
      // the initial whichever direction the surrounding paragraph runs in.
      expect(_periodSitsLeftOfName(name, TextDirection.ltr), isTrue);
      // Without the mark the ambient direction would push the period to the
      // wrong side of the name.
      expect(_periodSitsLeftOfName('דוד ל.', TextDirection.ltr), isFalse);
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

    test(
      'a masked name keeps its period on the right in a Hebrew paragraph',
      () {
        // The name the server stores in the notification inbox: plain text, no
        // direction marks.
        const masked = 'First L.';

        // Marked with the direction of its own script, the period stays glued
        // to the initial even when the surrounding paragraph is right-to-left.
        final marked = masked.withDirectionalMarks();
        expect(
          _punctuationSitsRightOfName(marked, TextDirection.rtl),
          isTrue,
          reason: 'the period must land right of the name, not before it',
        );
        expect(_punctuationSitsRightOfName(masked, TextDirection.rtl), isFalse);
      },
    );

    test('a masked name inside a sentence keeps its period on the right', () {
      const body = 'יש לך התאמה עם First L.';

      final isolated = body.isolateTrailingDisplayName();

      expect(isolated, isNot(body));
      expect(
        _punctuationSitsRightOfName(isolated, TextDirection.rtl),
        isTrue,
        reason: 'the name keeps its period even inside a Hebrew sentence',
      );
      // The sentence itself keeps its own direction.
      expect(isolated.displayTextDirection(), TextDirection.rtl);
    });

    test('a sentence that starts in Hebrew stays right-to-left', () {
      expect(
        'יש לך התאמה עם First L.'.displayTextDirection(),
        TextDirection.rtl,
      );
      expect(
        'You matched with First L.'.displayTextDirection(),
        TextDirection.ltr,
      );
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

  group('notification inbox row', () {
    testWidgets('keeps an English name period on the right in a Hebrew UI', (
      tester,
    ) async {
      // What the server stores for a chat message: the masked sender name as
      // the subject, the message preview as the body.
      final item = NotificationInboxItem(
        id: 'inbox-bidi',
        type: 'chat_message',
        title: 'First L.',
        body: 'Hi!',
        data: const {},
        createdAt: DateTime(2026, 1, 1, 11, 2),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(_l10n(TextDirection.rtl)),
            notificationInboxProvider.overrideWith(
              () => _FakeInboxNotifier([item]),
            ),
          ],
          child: MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(body: NotificationInboxScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The subject is the masked name: it lays out in its own script (LTR)
      // and stays flush with the UI edge.
      final title = _textContaining(tester, 'First L.');
      expect(title.textDirection, TextDirection.ltr);
      expect(title.textAlign, TextAlign.right);
      expect(
        _punctuationSitsRightOfName(title.data!, title.textDirection!),
        isTrue,
        reason: 'the period must land right of the name, not before it',
      );

      // The preview is English too: it must not be flipped by the Hebrew UI.
      final body = _textContaining(tester, 'Hi!');
      expect(body.textDirection, TextDirection.ltr);
      expect(body.textAlign, TextAlign.right);
      expect(
        _punctuationSitsRightOfName('Hi!', body.textDirection!),
        isTrue,
        reason: 'the exclamation mark must stay right of the word',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps a Hebrew sentence right-to-left in a Hebrew UI', (
      tester,
    ) async {
      final item = NotificationInboxItem(
        id: 'inbox-bidi-he',
        type: 'new_match',
        title: 'התאמה חדשה!',
        body: 'יש לך התאמה עם First L.',
        data: const {},
        createdAt: DateTime(2026, 1, 1, 11, 2),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(_l10n(TextDirection.rtl)),
            notificationInboxProvider.overrideWith(
              () => _FakeInboxNotifier([item]),
            ),
          ],
          child: MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(body: NotificationInboxScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final body = _textContaining(tester, 'התאמה עם');
      expect(body.textDirection, TextDirection.rtl);
      expect(body.textAlign, TextAlign.right);
      expect(
        _punctuationSitsRightOfName(body.data!, body.textDirection!),
        isTrue,
        reason: 'the name inside the sentence keeps its period',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
