import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:hive/hive.dart';
import 'dart:io' as io;
import 'package:matchme/widgets/emoji_widget.dart';

void main() {
  testWidgets('Reaction picker bottom sheet opens and shows emojis', (WidgetTester tester) async {
    // Initialize Hive for tests (use system temp dir)
    final testDir = io.Directory.systemTemp.createTempSync('hive_test_');
    Hive.init(testDir.path);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Consumer(builder: (context, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showReactionPicker(context, ref, initialMatchId: 'match1', initialMessageId: 'm1', allEmojis: ['❤️','🎉']),
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
    expect(find.byWidgetPredicate((w) => w is EmojiWidget && (w).emoji == '❤️'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is EmojiWidget && (w).emoji == '🎉'), findsOneWidget);

    // cleanup
    testDir.deleteSync(recursive: true);
  });
}
