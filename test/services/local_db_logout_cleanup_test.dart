import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:matchme/services/encrypted_cache_service.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_api_cache.dart';
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
      await db.savePendingReferralCode('REF-OUTGOING');

      await db.clearUserData('outgoing-user');

      expect(await db.getMessages('outgoing-match'), isEmpty);
      expect(await db.watchChats('outgoing-user').first, isEmpty);
      expect(await db.watchMatches('outgoing-user').first, isEmpty);
      expect(await db.getNotificationInbox('outgoing-user'), isNull);
      expect(await db.getNearbyMapCells('outgoing-user', 'query-1'), isNull);
      expect(await db.getOtherUserProfile('cached-profile'), isNull);
      expect(await db.getPendingReferralCode(), isNull);
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

  test('logout clears emoji usage and queued offline mutations', () async {
    final emojiBox = await Hive.openBox<int>('emoji_usage');
    await emojiBox.put('👍', 5);
    final mutationBox = await Hive.openBox('offline_mutations');
    await mutationBox.put('mutation-1', {'payload': 'queued-secret'});

    await db.clearUserData('outgoing-user');

    expect(Hive.box<int>('emoji_usage').isEmpty, isTrue);
    expect(Hive.box('offline_mutations').isEmpty, isTrue);
  });

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
    'overlapping message writes never drop rows from the conversation',
    () async {
      final history = <Map<String, dynamic>>[
        for (var i = 0; i < 20; i++)
          {
            'id': 'history-$i',
            'match_id': 'write-race-match',
            'sender_id': 'peer',
            'created_at': '2026-10-08T08:${i.toString().padLeft(2, '0')}:00Z',
            'content_original': 'message $i',
            'content_original_encrypted': 'cipher $i',
          },
      ];
      await db.saveMessages('write-race-match', history);

      // After login the cache key is loaded, so merging decrypted rows back
      // performs async encryption between reading and writing the blob.
      await EncryptedCacheService.instance.initialize('write-race-user');
      addTearDown(
        () => EncryptedCacheService.instance.clearMemoryCache(
          userId: 'write-race-user',
        ),
      );

      // A realtime insert and two decryption results land at the same time.
      // Each of them reads the whole blob, mutates it and writes it back, so
      // without serialization the last writer wins and the rows only the
      // others added disappear - which is how a conversation used to end up
      // holding just its newest message.
      await Future.wait([
        db.addMessages('write-race-match', [
          {
            'id': 'newest-message',
            'match_id': 'write-race-match',
            'sender_id': 'peer',
            'created_at': '2026-10-08T09:00:00Z',
            'content_original': 'newest',
          },
        ]),
        db.mergeMessages('write-race-match', [
          {
            'id': 'history-3',
            'content_original': 'message 3 decrypted',
            'content_original_encrypted': 'cipher 3',
          },
        ]),
        db.mergeMessages('write-race-match', [
          {
            'id': 'history-7',
            'content_original': 'message 7 decrypted',
            'content_original_encrypted': 'cipher 7',
          },
        ]),
      ]);

      final cached = await db.getMessages('write-race-match');
      expect(cached, hasLength(21));
      expect(
        cached.firstWhere((m) => m['id'] == 'history-3')['content_original'],
        'message 3 decrypted',
      );
      expect(
        cached.firstWhere((m) => m['id'] == 'history-7')['content_original'],
        'message 7 decrypted',
      );
      expect(cached.any((m) => m['id'] == 'newest-message'), isTrue);
    },
  );

  test(
    'sync marker keeps its message count when only the time is updated',
    () async {
      await db.markMessagesSynced('marker-match', messageCount: 5);

      final state = await db.getMessagesSyncState('marker-match');
      expect(state, isNotNull);
      expect(state!.count, 5);
      expect(await db.getMessagesSyncedAt('marker-match'), isNotNull);

      await db.markMessagesSynced('marker-match');

      final refreshed = await db.getMessagesSyncState('marker-match');
      expect(refreshed!.count, 5);
    },
  );

  test('notification snapshot remains available offline', () async {
    await db.saveNotificationInbox('offline-snapshot-user', [
      {
        'id': 'cached-notification',
        'title': 'A cached title',
        'body': 'A cached body',
      },
    ]);

    expect(
      (await db.getNotificationInbox('offline-snapshot-user'))?.single['id'],
      'cached-notification',
    );
    expect(await db.getNotificationInbox('different-user'), isNull);
  });

  test('pending visibility updates are scoped per user', () async {
    expect(await db.hasPendingVisibilityUpdate('visibility-user-a'), isFalse);

    await db.saveVisibilityUpdateToOutbox('visibility-user-a', false);

    expect(await db.hasPendingVisibilityUpdate('visibility-user-a'), isTrue);
    expect(await db.hasPendingVisibilityUpdate('visibility-user-b'), isFalse);

    final pending = await db.watchVisibilityOutbox().first;
    final key = pending.keys.singleWhere(
      (k) => k.toString().startsWith('visibility-user-a_visibility_'),
    );
    await db.removeVisibilityUpdateFromOutbox(key);

    expect(await db.hasPendingVisibilityUpdate('visibility-user-a'), isFalse);
  });

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

  test(
    'verification status stays in encrypted storage and is wiped on logout',
    () async {
      const userId = 'verification-cache-user';
      await db.saveVerificationStatus(userId, {
        'verification_status': 'rejected',
        'verification_ai_analysis': {'reasoning': 'Different person'},
        'verification_photo_path': '$userId/verification.jpg',
      });

      final cached = await db.getVerificationStatus(userId);
      expect(cached?['verification_status'], 'rejected');
      expect(
        cached?['verification_ai_analysis'],
        containsPair('reasoning', 'Different person'),
      );
      expect(await db.getVerificationStatus('different-user'), isNull);

      await db.clearUserData(userId);
      expect(await db.getVerificationStatus(userId), isNull);
    },
  );

  test(
    'Supabase GET responses round-trip through the encrypted API cache',
    () async {
      final key = OfflineApiCache.buildKey(
        method: 'GET',
        url: Uri.parse('https://example.supabase.co/rest/v1/users?select=*'),
        userId: 'cache-user',
      );
      final bytes = Uint8List.fromList(utf8.encode('[{"id":"cache-user"}]'));
      await OfflineApiCache.instance.write(
        key,
        bytes,
        headers: {'content-type': 'application/json'},
      );

      final cached = await OfflineApiCache.instance.read(key);
      expect(cached, isNotNull);
      expect(cached!.bytes, orderedEquals(bytes));
      expect(cached.headers['content-type'], 'application/json');

      await OfflineApiCache.instance.clear();
      expect(await OfflineApiCache.instance.read(key), isNull);
    },
  );

  test(
    'API cache identity is stable per subject and isolates accounts',
    () async {
      final url = Uri.parse('https://example.supabase.co/rest/v1/matches');
      final anonymous = OfflineApiCache.buildKey(method: 'GET', url: url);
      final first = OfflineApiCache.buildKey(
        method: 'GET',
        url: url,
        userId: 'user-a',
      );
      final second = OfflineApiCache.buildKey(
        method: 'GET',
        url: url,
        userId: 'user-b',
      );
      expect(anonymous, isNot(first));
      expect(first, isNot(second));
      expect(
        first,
        OfflineApiCache.buildKey(method: 'GET', url: url, userId: 'user-a'),
      );
      // `.range()` pages share a URL but not a body: the Range header must
      // keep their cache identities distinct.
      expect(
        OfflineApiCache.buildKey(
          method: 'GET',
          url: url,
          userId: 'user-a',
          headers: {'Range': '0-9'},
        ),
        isNot(
          OfflineApiCache.buildKey(
            method: 'GET',
            url: url,
            userId: 'user-a',
            headers: {'Range': '10-19'},
          ),
        ),
      );
    },
  );

  Uri longEventsUrl() => Uri.parse(
        'https://example.supabase.co/rest/v1/events'
        '?select=${List.generate(80, (i) => 'column_$i').join(',')}',
      );

  test(
    'API cache keys stay within Hive\'s one-byte key length limit',
    () {
      final longUrl = longEventsUrl();
      final key = OfflineApiCache.buildKey(
        method: 'GET',
        url: longUrl,
        userId: 'cache-user',
        headers: const {'Range': '0-9'},
      );
      // Hive writes the key length with writeByte(): keys over 255 bytes wrap
      // (290 -> 34), the CRC still validates, and the next open misparses the
      // frame as "unknown typeId: <garbage>" — the discard loop seen on device.
      expect(utf8.encode(key).length, lessThanOrEqualTo(255));
      expect(
        key,
        OfflineApiCache.buildKey(
          method: 'GET',
          url: longUrl,
          userId: 'cache-user',
          headers: const {'Range': '0-9'},
        ),
      );
      expect(
        key,
        isNot(
          OfflineApiCache.buildKey(
            method: 'GET',
            url: longUrl,
            userId: 'cache-user',
            headers: const {'Range': '10-19'},
          ),
        ),
      );
      // Short keys keep their exact readable form so existing cache entries
      // (and logout cleanup) stay byte-identical.
      expect(
        OfflineApiCache.buildKey(
          method: 'GET',
          url: Uri.parse('https://example.supabase.co/rest/v1/matches'),
        ),
        'GET anon https://example.supabase.co/rest/v1/matches',
      );
    },
  );

  test(
    'oversized-key cache entries survive a full box close and reopen',
    () async {
      final key = OfflineApiCache.buildKey(
        method: 'GET',
        url: longEventsUrl(),
        userId: 'cache-user',
      );
      expect(utf8.encode(key).length, lessThanOrEqualTo(255));
      final bytes = Uint8List.fromList(utf8.encode('[{"id":"cache-user"}]'));
      await OfflineApiCache.instance.write(
        key,
        bytes,
        headers: {'content-type': 'application/json'},
      );

      // Reopen the file exactly like a fresh launch would. A wrapped key
      // length on disk makes this throw "unknown typeId" and lose the entry.
      await Hive.close();
      final cipher = await HiveEncryptionService.instance.getCipher();
      final box = await Hive.openBox<dynamic>(
        'offline_api_cache_v1',
        encryptionCipher: cipher,
      );
      final stored = box.get(key);
      expect(stored, isNotNull);
      expect((stored as Map)['bytes'], orderedEquals(bytes));
      await box.close();
    },
  );
}
