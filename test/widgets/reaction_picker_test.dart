import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/screens/chats/chat_screen.dart';

void main() {
  testWidgets('Reaction picker bottom sheet opens and shows emojis', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Consumer(builder: (context, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showReactionPicker(context, ref, initialMatchId: 'match1', initialMessageId: 'm1'),
                    child: const Text('Open Picker'),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Open Picker'), findsOneWidget);

    await tester.tap(find.text('Open Picker'));
    await tester.pumpAndSettle();

    // Verify that one of the default emojis is visible in the bottom sheet
    expect(find.text('❤️'), findsOneWidget);
    expect(find.text('🎉'), findsOneWidget);
  });
}
