import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:matchme/services/local_db_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalDbService db;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('matchme_save_chats');
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

  Map<String, dynamic> chatRow({
    required String lastMessageId,
    required String lastMessage,
    Map<String, dynamic> extra = const {},
  }) {
    return {
      'match_id': 'm1',
      'other_user_id': 'peer',
      'other_user_name': 'Peer',
      'last_message': lastMessage,
      'last_message_at': '2026-01-01T00:00:00.000Z',
      'unread_count': 1,
      'translation_enabled': true,
      'translation_language': 'en',
      'last_message_id': lastMessageId,
      'last_message_sender_id': 'peer',
      'last_message_encryption_scheme': 'v1',
      ...extra,
    };
  }

  test(
    'same message sync keeps cached plaintext and translation while the '
    'server preview is empty',
    () async {
      await db.saveChats('user-a', [
        chatRow(
          lastMessageId: 'msg-1',
          lastMessage: 'bonjour',
          extra: {
            'last_message_translated': 'hello',
            'last_message_target_language': 'en',
          },
        ),
      ]);

      // A later sync whose Phase 3 could not decrypt v1 content returns an
      // empty preview for the same message. The decrypted cache must survive.
      await db.saveChats('user-a', [
        chatRow(lastMessageId: 'msg-1', lastMessage: ''),
      ]);

      final chat = (await db.watchChats('user-a').first).single;
      expect(chat['last_message'], 'bonjour');
      expect(chat['last_message_translated'], 'hello');
      expect(chat['last_message_target_language'], 'en');
    },
  );

  test(
    'advanced last_message_id never inherits the previous message text or '
    'translation',
    () async {
      await db.saveChats('user-a', [
        chatRow(
          lastMessageId: 'msg-1',
          lastMessage: 'bonjour',
          extra: {
            'last_message_translated': 'hello',
            'last_message_target_language': 'en',
          },
        ),
      ]);

      // The new message's plaintext could not be decrypted yet. The previous
      // message's text must not be pinned under the new id — rows that render
      // last_message directly (translation disabled / source == UI language)
      // would otherwise show the previous message.
      await db.saveChats('user-a', [
        chatRow(lastMessageId: 'msg-2', lastMessage: ''),
      ]);

      final chat = (await db.watchChats('user-a').first).single;
      expect(chat['last_message_id'], 'msg-2');
      expect(chat['last_message'], isEmpty);
      expect(chat['last_message_translated'], isNull);
      expect(chat['last_message_target_language'], isNull);
    },
  );

  test(
    'advanced last_message_id with a decrypted preview takes the new text '
    'and drops the stale translation',
    () async {
      await db.saveChats('user-a', [
        chatRow(
          lastMessageId: 'msg-1',
          lastMessage: 'bonjour',
          extra: {
            'last_message_translated': 'hello',
            'last_message_target_language': 'en',
          },
        ),
      ]);

      await db.saveChats('user-a', [
        chatRow(lastMessageId: 'msg-2', lastMessage: 'bonsoir'),
      ]);

      final chat = (await db.watchChats('user-a').first).single;
      expect(chat['last_message_id'], 'msg-2');
      expect(chat['last_message'], 'bonsoir');
      expect(chat['last_message_translated'], isNull);
    },
  );
}
