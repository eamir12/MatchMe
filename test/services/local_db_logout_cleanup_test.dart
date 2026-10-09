import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_image_cache.dart';

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

  test(
    'logout deletes outgoing chat data but preserves the next user cache',
    () async {
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
      await db.saveNotificationInbox('outgoing-user', [
        {'id': 'outgoing-notification'},
      ]);
      await db.saveNearbyMapCells('outgoing-user', 'query-1', [
        {'cell_center_lat': 1, 'cell_center_lng': 2, 'user_count': 3},
      ]);
      await db.saveOtherUserProfile('cached-profile', {'name': 'Cached name'});

      await db.clearUserData('outgoing-user');

      expect(await db.getMessages('outgoing-match'), isEmpty);
      expect(await db.watchChats('outgoing-user').first, isEmpty);
      expect(await db.watchMatches('outgoing-user').first, isEmpty);
      expect(await db.getNotificationInbox('outgoing-user'), isNull);
      expect(await db.getNearbyMapCells('outgoing-user', 'query-1'), isNull);
      expect(await db.getOtherUserProfile('cached-profile'), isNull);
      expect(await db.getMessages('next-match'), isEmpty);
      expect(await db.watchChats('next-user').first, hasLength(1));
      expect(await db.watchMatches('next-user').first, hasLength(1));

      // The next user's chat sync repopulates message storage from the server.
      await db.saveMessages('next-match', [
        {'id': 'next-message', 'content_original': 'next user message'},
      ]);
      expect(await db.getMessages('next-match'), hasLength(1));
    },
  );

  test(
    'offline chat preview persists as a message without dropping history',
    () async {
      await db.saveMessages('preview-match', [
        {
          'id': 'older-message',
          'match_id': 'preview-match',
          'sender_id': 'peer',
          'created_at': '2026-10-08T08:00:00Z',
          'content_original': 'Earlier message',
        },
      ]);

      await db.mergeMessages('preview-match', [
        {
          'id': 'latest-message',
          'match_id': 'preview-match',
          'sender_id': 'peer',
          'created_at': '2026-10-08T08:15:00Z',
          'content_original': 'Latest preview',
          'encryption_scheme': 'legacy',
        },
      ]);

      final cached = await db.getMessages('preview-match');
      expect(cached, hasLength(2));
      expect(cached.last['content_original'], 'Latest preview');
    },
  );

  test('incomplete chat refresh retains cached name and photos', () async {
    await db.saveChats('chat-cache-user', [
      {
        'match_id': 'chat-cache-match',
        'other_user_id': 'peer',
        'other_user_name': 'Alex Example',
        'other_user_photos': ['cached-photo.jpg'],
      },
    ]);

    await db.saveChats('chat-cache-user', [
      {
        'match_id': 'chat-cache-match',
        'other_user_id': 'peer',
        'other_user_name': 'Unknown User',
        'other_user_photos': null,
      },
    ]);

    final cachedChats = await db.watchChats('chat-cache-user').first;
    expect(cachedChats.single['other_user_name'], 'Alex Example');
    expect(cachedChats.single['other_user_photos'], ['cached-photo.jpg']);
  });

  test(
    'dashboard and notification snapshots remain available offline',
    () async {
      await db.saveDashboardStats('offline-snapshot-user', 12, 4);
      await db.saveNotificationInbox('offline-snapshot-user', [
        {
          'id': 'cached-notification',
          'title': 'A cached title',
          'body': 'A cached body',
        },
      ]);

      expect(await db.getDashboardStats('offline-snapshot-user'), {
        'online': 12,
        'nearby': 4,
      });
      expect(
        (await db.getNotificationInbox('offline-snapshot-user'))?.single['id'],
        'cached-notification',
      );
      expect(await db.getNotificationInbox('different-user'), isNull);
    },
  );

  test(
    'web image cache round-trips bytes through encrypted local storage',
    () async {
      final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
      await OfflineImageCache.instance.write('offline-test-image', bytes);

      expect(
        await OfflineImageCache.instance.read('offline-test-image'),
        orderedEquals(bytes),
      );

      await OfflineImageCache.instance.evict('offline-test-image');
      expect(
        await OfflineImageCache.instance.read('offline-test-image'),
        isNull,
      );
    },
  );
}
