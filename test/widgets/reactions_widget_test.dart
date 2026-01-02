import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/models/chat_message_model.dart';

void main() {
  testWidgets('ReactionRow shows chips', (WidgetTester tester) async {
    final message = ChatMessageModel(
      id: 'm1',
      matchId: 'match1',
      senderId: 'u2',
      contentOriginal: 'hello',
      reactionSummary: {'❤️': 2, '👍': 1},
      myReaction: '❤️',
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

    // Wait for build
    await tester.pumpAndSettle();

    // Verify both chips are present
    expect(find.text('❤️'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    // Ensure the widget builds and chips are present (tapping behavior is covered in integration tests)
    expect(find.byType(ReactionRow), findsOneWidget);
  });
}
