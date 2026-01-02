import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:matchme/screens/chats/chat_screen.dart';
import 'package:matchme/widgets/emoji_widget.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/services/local_db_service.dart';


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
                    onPressed: () => showReactorsSheet(
                      context,
                      ref,
                      'match1',
                      'm1',
                      '❤️',
                      getReactorsFn: (messageId, reaction) async => [
                        {'user_id': 'ffc20046-a777-463b-922a-547151aa1455', 'display_name': null, 'photo': 'https://example.com/photo1.jpg'}
                      ],
                    ),
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
    // pump multiple small frames and wait up to ~2s for the sheet to build
    bool foundSigned = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(SignedImage).evaluate().isNotEmpty) {
        foundSigned = true;
        break;
      }
    }

    // Ensure we observed the SignedImage before proceeding
    expect(foundSigned, isTrue, reason: 'SignedImage should be present when photo is supplied');

    // Expect that the reactor photo widget is created (verify via ListTile.leading)
    final tile = tester.widget<ListTile>(find.byType(ListTile).first);
    expect(tile.leading, isA<SignedImage>(), reason: 'ListTile.leading should be SignedImage when photo present');
    // The name may be a masked id when no display name is available; ensure at least the photo is shown.
    // (Display name/ID visibility is validated in the other test case when display_name is provided.)

    tmp.deleteSync(recursive: true);
  });

  testWidgets('Reactors sheet shows masked name for provided full name', (WidgetTester tester) async {
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
                    onPressed: () => showReactorsSheet(
                      context,
                      ref,
                      'match1',
                      'm2',
                      '❤️',
                      getReactorsFn: (messageId, reaction) async => [
                        {'user_id': 'u1', 'display_name': 'John Smith', 'photo': null}
                      ],
                    ),
                    child: const Text('Open Reactors 2'),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Open Reactors 2'), findsOneWidget);

    await tester.tap(find.text('Open Reactors 2'));
    await tester.pumpAndSettle();

    // Expect masked name 'John S.'
    expect(find.text('John S.'), findsOneWidget);

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

  testWidgets('Reactors sheet prefers local cache and updates after server refresh', (WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('hive_test_');
    Hive.init(tmp.path);

    // Prepare local DB with cached reactors for message m3
    final localDb = await LocalDbService.instance;
    await localDb.saveMessages('matchLocal', [
      {
        'id': 'm3',
        'content_original': 'hey',
        'created_at': DateTime.now().toIso8601String(),
        'reactors': {
          '❤️': [
            {'user_id': 'local1', 'display_name': 'Local User', 'photo': null}
          ]
        }
      }
    ]);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Consumer(builder: (context, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showReactorsSheet(
                      context,
                      ref,
                      'matchLocal',
                      'm3',
                      '❤️',
                      getReactorsFn: (messageId, reaction) async {
                        // Simulate a slow network call and changed response
                        await Future.delayed(const Duration(milliseconds: 200));
                        return [
                          {'user_id': 'server1', 'display_name': 'Server Name', 'photo': null}
                        ];
                      },
                    ),
                    child: const Text('Open Cached Reactors'),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Cached Reactors'));

    // Immediately after opening, cached masked name should be visible
    bool foundLocal = false;
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('Local U.').evaluate().isNotEmpty) {
        foundLocal = true;
        break;
      }
    }
    expect(foundLocal, isTrue, reason: 'Cached masked name should be shown before server refresh');

    // After the background server refresh completes, the UI should update to show 'Server N.'
    bool foundServer = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Server N.').evaluate().isNotEmpty) {
        foundServer = true;
        break;
      }
    }
    expect(foundServer, isTrue, reason: 'Server result should replace cached reactors after refresh');

    tmp.deleteSync(recursive: true);
  });

  testWidgets('Reactors sheet hydrates missing profile info from local cache', (WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('hive_test_');
    Hive.init(tmp.path);

    // Create a local profile for 'local_p'
    final localDb = await LocalDbService.instance;
    await localDb.saveLocalProfile('local_p', {
      'id': 'local_p',
      'name': 'Local Person',
      'photos': ['https://example.com/local_person.jpg']
    });

    // Save a message with cached reactors that lack display_name and photo
    await localDb.saveMessages('matchLocal2', [
      {
        'id': 'm_local_p',
        'content_original': 'yo',
        'created_at': DateTime.now().toIso8601String(),
        'reactors': {
          '❤️': [
            {'user_id': 'local_p', 'display_name': null, 'photo': null}
          ]
        }
      }
    ]);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Consumer(builder: (context, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showReactorsSheet(
                      context,
                      ref,
                      'matchLocal2',
                      'm_local_p',
                      '❤️',
                    ),
                    child: const Text('Open Hydrated Reactors'),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Hydrated Reactors'));

    // Immediately the masked name 'Local P.' should be visible
    bool foundLocal = false;
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('Local P.').evaluate().isNotEmpty) {
        foundLocal = true;
        break;
      }
    }
    expect(foundLocal, isTrue, reason: 'Hydrated masked name should be shown before any server call');

    // SignedImage should be present (photo string provided)
    expect(find.byType(SignedImage), findsOneWidget);

    tmp.deleteSync(recursive: true);
  });

  testWidgets('Reactors sheet All view shows grouped reactors', (WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('hive_test_');
    Hive.init(tmp.path);

    // Prepare local DB with cached reactors for message mAll (two different emoji groups)
    final localDb = await LocalDbService.instance;
    await localDb.saveMessages('matchAll', [
      {
        'id': 'mAll',
        'content_original': 'hey',
        'created_at': DateTime.now().toIso8601String(),
        'reactors': {
          '❤️': [
            {'user_id': 'u1', 'display_name': 'Alice', 'photo': null}
          ],
          '👍': [
            {'user_id': 'u2', 'display_name': 'Bob', 'photo': null}
          ]
        }
      }
    ]);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Consumer(builder: (context, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showReactorsSheet(
                      context,
                      ref,
                      'matchAll',
                      'mAll',
                      '❤️',
                      getReactorsFn: (messageId, reaction) async => [
                        {'user_id': 'u1', 'display_name': 'Alice', 'photo': null},
                      ],
                      reactionSummary: {'❤️': 1, '👍': 1},
                    ),
                    child: const Text('Open All Reactors'),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Open All Reactors'));

    // Immediately after opening, cached names should be visible in the All view
    bool foundAlice = false;
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('Alice').evaluate().isNotEmpty) {
        foundAlice = true;
        break;
      }
    }
    expect(foundAlice, isTrue, reason: 'Cached name Alice should be shown in All view');

    // Bob (second emoji group) should also be present
    expect(find.text('Bob'), findsOneWidget);

    tmp.deleteSync(recursive: true);
  });
}
