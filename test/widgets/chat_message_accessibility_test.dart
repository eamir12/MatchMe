import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/chats/chat_screen.dart';

ChatMessageModel _message() {
  return ChatMessageModel(
    id: 'message-1',
    matchId: 'match-1',
    senderId: 'test-user',
    contentOriginal: 'Hello there',
    createdAt: DateTime(2026, 1, 1, 12),
  );
}

class _TestTranslationNotifier extends TranslationNotifier {
  @override
  TranslationStates build() => <String, String>{};
}

void main() {
  testWidgets('message bubble exposes tap and long-press actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(LocalizationState.loading()),
          translationProvider.overrideWith(_TestTranslationNotifier.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MessageBubbleTestWrapper(message: _message(), isMe: true),
          ),
        ),
      ),
    );
    await tester.pump();

    final semantics = tester.getSemantics(find.bySemanticsLabel('Hello there'));
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(
      semantics.getSemanticsData().hasAction(SemanticsAction.longPress),
      isTrue,
    );

    final bubble = tester.widget<InkWell>(find.byType(InkWell).last);
    expect(bubble.onTap, isNotNull);
    expect(bubble.onLongPress, isNotNull);
    expect(bubble.onDoubleTap, isNotNull);
  });

  testWidgets('message bubble is keyboard focusable', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(LocalizationState.loading()),
          translationProvider.overrideWith(_TestTranslationNotifier.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MessageBubbleTestWrapper(message: _message(), isMe: true),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final focusNode = FocusManager.instance.primaryFocus;
    expect(focusNode?.hasFocus, isTrue);
  });
}
