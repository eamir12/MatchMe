// Regression tests for the chat-translation toggle flicker:
// enabling/disabling translation must never blank incoming bubbles.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/screens/chats/chat_screen.dart';

ChatMessageModel _incomingMessage({String id = 'message-1'}) {
  return ChatMessageModel(
    id: id,
    matchId: 'match-1',
    senderId: 'peer-user',
    contentOriginal: 'Hola',
    createdAt: DateTime(2026, 1, 1, 12),
  );
}

class _EnabledTranslationNotifier extends TranslationNotifier {
  @override
  TranslationStates build() => const {'match-1': 'en'};
}

Widget _wrap(
  FutureOr<String> Function(Ref ref, String arg) createTranslation, {
  ChatMessageModel? message,
}) {
  return ProviderScope(
    overrides: [
      localizationProvider.overrideWithValue(LocalizationState.loading()),
      translationProvider.overrideWith(_EnabledTranslationNotifier.new),
      translationFamilyProvider.overrideWith(createTranslation),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: MessageBubbleTestWrapper(
          message: message ?? _incomingMessage(),
          isMe: false,
        ),
      ),
    ),
  );
}

Finder _richTextWith(String text) {
  return find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == text,
  );
}

void main() {
  testWidgets(
    'incoming bubble shows the original while its translation is pending',
    (tester) async {
      // Translation enabled, but no result yet (e.g. just toggled on and
      // the provider is still re-evaluating). The bubble must render the
      // original instead of collapsing to zero height.
      final pending = Completer<String>();
      await tester.pumpWidget(_wrap((ref, params) => pending.future));
      await tester.pump();

      expect(_richTextWith('Hola'), findsOneWidget);
    },
  );

  testWidgets(
    'incoming bubble keeps its previous translation while reloading',
    (tester) async {
      // First resolve a translation, then re-trigger the family (as the
      // toggle/version bump does) with a hanging future. The resolved text
      // must stay on screen — previously the bubble blanked out until the
      // new value arrived.
      await tester.pumpWidget(
        _wrap((ref, params) {
          final version = ref.watch(translationVersionProvider);
          if (version == 0) return 'Hello';
          return Completer<String>().future;
        }),
      );
      await tester.pump();
      expect(_richTextWith('Hello'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MessageBubbleTestWrapper)),
        listen: false,
      );
      container.read(translationVersionProvider.notifier).increment();
      // Let the 100ms debounce fire and the reload settle.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(_richTextWith('Hello'), findsOneWidget);
    },
  );

  testWidgets(
    'incoming bubble renders the cached translation before the provider emits',
    (tester) async {
      // A fresh family instance's first frame is always AsyncLoading even
      // when the in-memory cache already holds the result. Without the
      // synchronous peek the bubble flashed the original text before the
      // provider's first emission (toggle back on / remount flicker).
      final message = _incomingMessage(id: 'message-peek');
      debugSeedTranslationCache(
        messageId: message.id,
        targetLanguage: 'en',
        text: message.contentOriginal,
        translation: 'Hello',
      );
      final pending = Completer<String>();
      await tester.pumpWidget(
        _wrap((ref, params) => pending.future, message: message),
      );

      // First frame: provider still loading, cached translation on screen
      // (the original stays visible as the muted secondary line by design).
      expect(_richTextWith('Hello'), findsOneWidget);
      expect(_richTextWith('Hola'), findsOneWidget);

      pending.complete('Hello');
      await tester.pump();
      expect(_richTextWith('Hello'), findsOneWidget);
    },
  );

  test('seedTranslationCacheFromMessages bridges cached translations', () {
    final message = ChatMessageModel(
      id: 'message-seed',
      matchId: 'match-1',
      senderId: 'peer-user',
      contentOriginal: 'Buenos dias',
      contentTranslated: 'Good morning',
      translatedLang: 'en',
      detectedSourceLanguage: 'es',
      createdAt: DateTime(2026, 1, 1, 12),
    );

    expect(
      peekCachedTranslation(
        messageId: message.id,
        targetLanguage: 'en',
        text: message.contentOriginal,
      ),
      isNull,
    );

    final seeded = seedTranslationCacheFromMessages(
      messages: [message],
      matchId: 'match-1',
      targetLanguage: 'en',
    );

    expect(seeded, 1);
    expect(
      peekCachedTranslation(
        messageId: message.id,
        targetLanguage: 'en',
        text: message.contentOriginal,
      ),
      'Good morning',
    );
  });

  test('seedTranslationCacheFromMessages skips untrusted rows', () {
    ChatMessageModel row({
      required String id,
      String? translated,
      String? translatedLang,
      String? sourceLang,
      DateTime? editedAt,
    }) {
      return ChatMessageModel(
        id: id,
        matchId: 'match-1',
        senderId: 'peer-user',
        contentOriginal: 'Hola',
        contentTranslated: translated,
        translatedLang: translatedLang,
        detectedSourceLanguage: sourceLang,
        editedAt: editedAt,
        createdAt: DateTime(2026, 1, 1, 12),
      );
    }

    final seeded = seedTranslationCacheFromMessages(
      messages: [
        row(
          id: 'seed-edited',
          translated: 'Hello',
          translatedLang: 'en',
          sourceLang: 'es',
          editedAt: DateTime(2026, 1, 2),
        ),
        row(
          id: 'seed-same-language',
          translated: 'Hola',
          translatedLang: 'en',
          sourceLang: 'en',
        ),
        row(
          id: 'seed-wrong-target',
          translated: 'Hallo',
          translatedLang: 'de',
          sourceLang: 'es',
        ),
        row(id: 'seed-no-translation', sourceLang: 'es'),
      ],
      matchId: 'match-1',
      targetLanguage: 'en',
    );

    expect(seeded, 0);
    for (final id in [
      'seed-edited',
      'seed-same-language',
      'seed-wrong-target',
      'seed-no-translation',
    ]) {
      expect(
        peekCachedTranslation(
          messageId: id,
          targetLanguage: 'en',
          text: 'Hola',
        ),
        isNull,
      );
    }
  });
}
