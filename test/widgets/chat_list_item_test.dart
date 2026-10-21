import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/widgets/chat_list_item.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('en');
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      debug: false,
    );
  });

  testWidgets(
    'chat item keeps the cached name while profile data is unavailable',
    (tester) async {
      final chat = ChatModel(
        matchId: 'match-1',
        otherUserId: 'other-user',
        otherUserName: 'Alex M.',
        lastMessage: 'Hello\u2800there',
        lastMessageId: 'message-1',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 0,
      );
      final l10n = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {},
        supportedLanguages: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(l10n),
            otherUserProfileProvider(
              chat.otherUserId,
            ).overrideWith((ref) => Future<UserProfile?>.value(null)),
          ],
          child: MaterialApp(
            home: Scaffold(body: ChatListItem(chat: chat)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alex M.'), findsOneWidget);
      expect(find.text('Hello there'), findsOneWidget);
      final preview = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == 'Hello there',
        ),
      );
      final previewSpan = preview.text as TextSpan;
      final styledMessageSpans = <TextSpan>[];
      previewSpan.visitChildren((span) {
        if (span is TextSpan &&
            span.text?.contains('Hello there') == true &&
            span.style != null) {
          styledMessageSpans.add(span);
        }
        return true;
      });
      expect(styledMessageSpans, isNotEmpty);
      final messageStyle = styledMessageSpans.first.style!;
      expect(messageStyle.letterSpacing, 0);
      expect(messageStyle.wordSpacing, 0);
      expect(messageStyle.inherit, isFalse);
      // Regression: a preview style without a font family makes the emoji
      // fallback the preferred font, and Apple Color Emoji (iOS) resolves
      // the space glyph from there, widening every word gap on iOS.
      expect(messageStyle.fontFamily, isNotNull);
      expect(messageStyle.fontFamilyFallback, isNotNull);
      expect(preview.textAlign, TextAlign.start);
      expect(preview.textDirection, TextDirection.ltr);
      expect(find.text('Loading'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unread badge announces its message count', (tester) async {
    final chat = ChatModel(
      matchId: 'match-2',
      otherUserId: 'other-user-2',
      otherUserName: 'Sam M.',
      lastMessage: 'Hey',
      lastMessageId: 'message-2',
      lastMessageAt: DateTime(2026, 1, 1),
      unreadCount: 3,
    );
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          otherUserProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Future<UserProfile?>.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListItem(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('3 unread messages'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets(
    'unread badge waits for a pending translation instead of arriving first',
    (tester) async {
      final chat = ChatModel(
        matchId: 'match-pending-tx',
        otherUserId: 'other-user-pending-tx',
        otherUserName: 'Bella V.',
        lastMessage: 'Hola!',
        lastMessageId: 'message-pending-tx',
        lastMessageSenderId: 'other-user-pending-tx',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 1,
        translationEnabled: true,
        lastMessageSourceLanguage: 'es',
        lastMessageTranslated: null,
      );
      final l10n = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {},
        supportedLanguages: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(l10n),
            otherUserProfileProvider(
              chat.otherUserId,
            ).overrideWith((ref) => Future<UserProfile?>.value(null)),
          ],
          child: MaterialApp(
            home: Scaffold(body: ChatListItem(chat: chat)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // While the translation is in flight the row must not show the unread
      // badge on its own, and must not fall back to the untranslated text.
      expect(find.bySemanticsLabel('1 unread messages'), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.text('Hola!'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'translated preview and unread badge reveal together on the age line',
    (tester) async {
      final chat = ChatModel(
        matchId: 'match-tx-ready',
        otherUserId: 'other-user-tx-ready',
        otherUserName: 'Bella V.',
        lastMessage: 'Hola!',
        lastMessageId: 'message-tx-ready',
        lastMessageSenderId: 'other-user-tx-ready',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 1,
        translationEnabled: true,
        lastMessageSourceLanguage: 'es',
        lastMessageTranslated: 'How are you?',
        // The translation was produced for the language of the UI.
        lastMessageTranslatedTargetLanguage: 'en',
      );
      final l10n = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {},
        supportedLanguages: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(l10n),
            otherUserProfileProvider(chat.otherUserId).overrideWith(
              (ref) => Future<UserProfile?>.value(
                UserProfile.fromMap({
                  'id': chat.otherUserId,
                  'name': 'Bella Valentine',
                  'dateOfBirth': '2000-01-01',
                }),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(body: ChatListItem(chat: chat)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('How are you?'), findsOneWidget);
      expect(find.bySemanticsLabel('1 unread message'), findsOneWidget);

      // The badge shares the age/gender line instead of owning a row under
      // the timestamp: both centers sit on the same vertical position.
      final badgeCenter = tester.getCenter(find.text('1'));
      final ageCenter = tester.getCenter(find.textContaining('Age:'));
      expect((badgeCenter.dy - ageCenter.dy).abs() <= 6, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  // Regression: a chat row rendered the base64 content_translated_encrypted
  // blob when decryption could not run. A message must never be shown in its
  // encrypted form because the user cannot read it.
  const leakedBlob =
      'cjFa3e0sBTRmfbIsI3+KQjIucTxiZilNIMLVbSdx3peeLUf04vAd6Krj3QcOa4PULKyKDxgFOoOBVN3HzXcIaZlHZ8=';

  // Regression: the name used to share its line with the timestamp, whose
  // full "21 באוקטובר 2026 · 3:27 אחר הצהריים" stamp took most of the row
  // and left the name a sliver — every name that was not one short word
  // spilled onto a second line, and a longer one painted over the line
  // below it. The name now owns its own band, so it can never be squeezed
  // by the timestamp.
  testWidgets('the name owns its own band and never shares a line with the timestamp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final chat = ChatModel(
      matchId: 'match-long-name',
      otherUserId: 'other-user-long-name',
      otherUserName: 'Aleksandra Konstantinova V.',
      lastMessage: 'Hey',
      lastMessageId: 'message-long-name',
      lastMessageAt: DateTime(2015, 3, 15),
      unreadCount: 0,
    );
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          otherUserProfileProvider(chat.otherUserId).overrideWith(
            (ref) => Future<UserProfile?>.value(
              UserProfile.fromMap({
                'id': chat.otherUserId,
                'name': 'Aleksandra Konstantinova V.',
                'dateOfBirth': '2000-01-01',
              }),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListItem(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nameFinder = find.textContaining('Aleksandra Konstantinova V.');
    expect(nameFinder, findsOneWidget);

    // The timestamp lives in the metadata band below the name, so the two
    // can never overlap horizontally.
    final stampFinder = find.text('March 15, 2015');
    expect(stampFinder, findsOneWidget);
    final nameRect = tester.getRect(nameFinder);
    final stampRect = tester.getRect(stampFinder);
    expect(nameRect.overlaps(stampRect), isFalse);

    // And the name is not squeezed into a sliver: it owns the content
    // column next to the avatar.
    expect(nameRect.width, greaterThan(200));

    // The metadata band (age/gender + timestamp) sits below the name, so a
    // name that needs more than one line can never paint over it.
    final ageRect = tester.getRect(find.textContaining('Age:'));
    expect(nameRect.overlaps(ageRect), isFalse);

    expect(tester.takeException(), isNull);
  });

  // Regression: a long last message used to be painted with `maxLines: 2`
  // and `overflow: visible`, so its third line and beyond spilled over the
  // card below it. The preview is now cut at a word boundary and marked
  // with an ellipsis.
  testWidgets('a long preview is cut at a word boundary and stays in its two lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const longMessage =
        'one two three four five six seven eight nine ten eleven twelve';
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    ChatModel chatWith(String message, String id) => ChatModel(
      matchId: id,
      otherUserId: 'other-user-$id',
      otherUserName: 'Alex M.',
      lastMessage: message,
      lastMessageId: 'message-$id',
      lastMessageAt: DateTime(2015, 3, 15),
      unreadCount: 0,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          otherUserProfileProvider('other-user-short').overrideWith(
            (ref) => Future<UserProfile?>.value(null),
          ),
          otherUserProfileProvider('other-user-long').overrideWith(
            (ref) => Future<UserProfile?>.value(null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ChatListItem(chat: chatWith('Short', 'short')),
                ChatListItem(chat: chatWith(longMessage, 'long')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final shortPreview = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == 'Short',
    );
    final longPreview = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains('…'),
    );
    expect(shortPreview, findsOneWidget);
    expect(longPreview, findsOneWidget);
    final shortHeight = tester.getSize(shortPreview).height;

    final plain = tester.widget<RichText>(longPreview).text.toPlainText();
    expect(plain, endsWith('…'));

    // The cut lands on a word boundary: what is kept is a prefix of the
    // message, and the next character in the original is a space.
    final kept = plain.replaceAll('…', '').trim();
    expect(longMessage.startsWith(kept), isTrue);
    if (kept.length < longMessage.length) {
      expect(longMessage[kept.length], ' ');
    }

    // And the preview never grows past its two lines.
    final longHeight = tester.getSize(longPreview).height;
    expect(longHeight, lessThanOrEqualTo(shortHeight * 2 + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('never renders an undecrypted translation preview', (
    tester,
  ) async {
    final chat = ChatModel(
      matchId: 'match-3',
      otherUserId: 'other-user-3',
      otherUserName: 'Bella V.',
      lastMessage: 'Hola!',
      lastMessageId: 'message-3',
      lastMessageAt: DateTime(2026, 1, 1),
      unreadCount: 0,
      translationEnabled: true,
      lastMessageSourceLanguage: 'es',
      lastMessageTranslated: leakedBlob,
    );
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          otherUserProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Future<UserProfile?>.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListItem(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(leakedBlob), findsNothing);
    expect(find.textContaining('cjFa3e0sBTRmfbIsI3'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('never renders an undecrypted original preview', (tester) async {
    final chat = ChatModel(
      matchId: 'match-4',
      otherUserId: 'other-user-4',
      otherUserName: 'Uri S.',
      lastMessage: leakedBlob,
      lastMessageId: 'message-4',
      lastMessageAt: DateTime(2026, 1, 1),
      unreadCount: 0,
    );
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          otherUserProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Future<UserProfile?>.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListItem(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('cjFa3e0sBTRmfbIsI3'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the decrypted translation when available', (tester) async {
    final chat = ChatModel(
      matchId: 'match-5',
      otherUserId: 'other-user-5',
      otherUserName: 'Bella V.',
      lastMessage: 'Hola!',
      lastMessageId: 'message-5',
      lastMessageAt: DateTime(2026, 1, 1),
      lastMessageSenderId: 'other-user-5',
      unreadCount: 0,
      translationEnabled: true,
      lastMessageSourceLanguage: 'es',
      lastMessageTranslated: 'How are you?',
      // The row only shows a translation that was produced for the language
      // of the UI — that is what the server records when it publishes one.
      lastMessageTranslatedTargetLanguage: 'en',
    );
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          userProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListItem(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('How are you?'), findsOneWidget);
  });

  // The row must never show a translation that was not produced for the
  // language of the UI — and it must not fall back to the untranslated
  // original either: the preview stays blank until the right translation
  // lands.
  testWidgets('hides a translation that was not made for the UI language', (
    tester,
  ) async {
    final chat = ChatModel(
      matchId: 'match-5-other-target',
      otherUserId: 'other-user-5',
      otherUserName: 'Bella V.',
      lastMessage: 'Hola!',
      lastMessageId: 'message-5-other-target',
      lastMessageAt: DateTime(2026, 1, 1),
      lastMessageSenderId: 'other-user-5',
      unreadCount: 0,
      translationEnabled: true,
      lastMessageSourceLanguage: 'es',
      lastMessageTranslated: 'How are you?',
      lastMessageTranslatedTargetLanguage: 'es',
    );
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          userProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListItem(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('How are you?'), findsNothing);
    expect(find.text('Hola!'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'chat row renders hydrated profile name and photo after initial fallback',
    (tester) async {
      final chat = ChatModel(
        matchId: 'match-hydrated',
        otherUserId: 'other-user-hydrated',
        otherUserName: 'Alex M.',
        lastMessage: 'Hello',
        lastMessageId: 'message-hydrated',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 0,
      );
      final gate = Completer<UserProfile?>();
      final l10n = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {},
        supportedLanguages: const [],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(l10n),
            otherUserProfileProvider(
              chat.otherUserId,
            ).overrideWith((ref) => gate.future),
          ],
          child: MaterialApp(
            home: Scaffold(body: ChatListItem(chat: chat)),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Alex M.'), findsOneWidget);
      expect(find.byType(SignedImage), findsNothing);

      gate.complete(
        UserProfile.fromMap({
          'id': chat.otherUserId,
          'name': 'Alexandra Example',
          'photos': ['https://example.com/avatar.jpg?token=valid'],
          'personal_interests': {
            'friendship': ['hiking'],
          },
        }),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Alexandra E.'), findsOneWidget);
      expect(find.byType(SignedImage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 11));
    },
  );
}
