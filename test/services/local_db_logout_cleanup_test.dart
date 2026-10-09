import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:matchme/services/local_db_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalDbService db;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('matchme_logout_cleanup');
    Hive.init(tempDir.path);
    db = LocalDbService();
    await db.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows may retain a file handle briefly after Hive closes.
    }
  });

  test('logout deletes outgoing chat data but preserves the next user cache', () async {
    await db.saveMatches('outgoing-user', [
      {'id': 'outgoing-match'},
    ]);
    await db.saveMatches('next-user', [
      {'id': 'next-match'},
    ]);
    await db.saveChats('outgoing-user', [
      {'match_id': 'outgoing-match'},
    ]);
    await db.saveChats('next-user', [
      {'match_id': 'next-match'},
    ]);
    await db.saveMessages('outgoing-match', [
      {'id': 'outgoing-message', 'content_original': 'private message'},
    ]);
    await db.saveMessages('next-match', [
      {'id': 'next-message', 'content_original': 'next user message'},
    ]);
    await db.saveOtherUserProfile('cached-profile', {'name': 'Cached name'});

    await db.clearUserData('outgoing-user');

    expect(await db.getMessages('outgoing-match'), isEmpty);
    expect(await db.watchChats('outgoing-user').first, isEmpty);
    expect(await db.watchMatches('outgoing-user').first, isEmpty);
    expect(await db.getOtherUserProfile('cached-profile'), isNull);
    expect(await db.getMessages('next-match'), isEmpty);
    expect(await db.watchChats('next-user').first, hasLength(1));
    expect(await db.watchMatches('next-user').first, hasLength(1));

    // The next user's chat sync repopulates message storage from the server.
    await db.saveMessages('next-match', [
      {'id': 'next-message', 'content_original': 'next user message'},
    ]);
    expect(await db.getMessages('next-match'), hasLength(1));
  });
}
