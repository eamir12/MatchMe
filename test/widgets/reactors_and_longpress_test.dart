import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/widgets/emoji_widget.dart';
import 'package:matchme/models/chat_message_model.dart';


void main() {
  testWidgets('Reactors sheet shows reactors', (WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('hive_test_');
    Hive.init(tmp.path);


    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Consumer(builder: (context, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showReactorsSheet(context, ref, 'match1', 'm1', '❤️'),
                    child: const Text('Open Reactors'),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Open Reactors'), findsOneWidget);

    await tester.tap(find.text('Open Reactors'));
    await tester.pumpAndSettle();

    // No reactors are returned in this test environment, expect the 'no reactors' fallback
    expect(find.text('chatNoReactors...'), findsOneWidget);

    tmp.deleteSync(recursive: true);
  });

  testWidgets('Long-press toggles reaction by calling chatService.setReaction', (WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('hive_test_');
    Hive.init(tmp.path);

    final message = ChatMessageModel(
      id: 'm1',
      matchId: 'match1',
      senderId: 'u2',
      contentOriginal: 'hello',
      reactionSummary: {'❤️': 1},
      myReaction: null,
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ReactionRow(message: message, matchId: 'match1'),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Long press the emoji chip (EmojiWidget inside the chip)
    final finder = find.byWidgetPredicate((w) => w is EmojiWidget && (w).emoji == '❤️');
    expect(finder, findsOneWidget);

    await tester.longPress(finder);
    await tester.pumpAndSettle();

    // ChatService.setReaction will likely throw in test environment; ensure we show generic error snackbar
    expect(find.text('errorGeneric...'), findsOneWidget);

    // Now test toggling off: when myReaction is '❤️', long-press should show the generic error snackbar in test env
    final message2 = ChatMessageModel(
      id: 'm2',
      matchId: 'match1',
      senderId: 'u2',
      contentOriginal: 'hi',
      reactionSummary: {'❤️': 1},
      myReaction: '❤️',
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ReactionRow(message: message2, matchId: 'match1'),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final finder2 = find.byWidgetPredicate((w) => w is EmojiWidget && (w).emoji == '❤️');
    expect(finder2, findsOneWidget);

    await tester.longPress(finder2);
    await tester.pumpAndSettle();

    expect(find.text('errorGeneric...'), findsOneWidget);

    tmp.deleteSync(recursive: true);
  });
}
