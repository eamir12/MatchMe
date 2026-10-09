import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/widgets/chat_list_item.dart';
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
        lastMessage: 'Hello there',
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

    expect(find.bySemanticsLabel('3 unread messages'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  // Regression: a chat row rendered the base64 content_translated_encrypted
  // blob when decryption could not run. A message must never be shown in its
  // encrypted form because the user cannot read it.
  const leakedBlob =
      'cjFa3e0sBTRmfbIsI3+KQjIucTxiZilNIMLVbSdx3peeLUf04vAd6Krj3QcOa4PULKyKDxgFOoOBVN3HzXcIaZlHZ8=';

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
}
