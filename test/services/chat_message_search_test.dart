import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:matchme/services/local_db_service.dart';
/// Full-text search over cached messages.
///
/// The important property is that this runs on-device: messages are
/// end-to-end encrypted, so the server cannot search them without being handed
/// every message ever sent. These tests pin that both the original body and
/// the machine translation are matched, because a Hebrew speaker searching an
/// English word finds nothing otherwise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Uses the real LocalDbService and the real saveMessages path, so these
  // tests exercise the same storage the app writes to.
  //
  // LocalDbService holds its Hive boxes in static fields, so the box is opened
  // once for the whole file against one temp directory. Re-initialising Hive
  // per test would leave the previous directory locked on Windows and fail with
  // a file-in-use error. Per-test isolation comes from clearing the match ids
  // instead, via the public deleteMessages path.
  late Directory tempDir;
  late LocalDbService db;
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('matchme_search_test');
    Hive.init(tempDir.path);
    db = LocalDbService();
    await db.init();
  });
  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows can still hold a handle briefly after close. The directory is
      // under the OS temp root and is cleaned up with it.
    }
  });
  setUp(() async {
    for (final id in const ['m1', 'm2']) {
      await db.deleteMessages(id);
    }
  });
  Future<void> seed(
    String matchId,
    List<Map<String, dynamic>> msgs,
  ) async {
    await db.saveMessages(matchId, msgs);
  }
  test('matches text deep inside a conversation, not just the last message', () async {
    await seed('m1', [
      {'id': '1', 'content_original': 'first message', 'created_at': '1'},
      {'id': '2', 'content_original': 'the middle one', 'created_at': '2'},
      {'id': '3', 'content_original': 'most recent', 'created_at': '3'},
    ]);
    // "first" is three messages back, so a preview-only search would miss it.
    final hits = await db.searchCachedMessages('first', matchIds: ['m1']);
    expect(hits, hasLength(1));
    expect(hits.first.matchId, 'm1');
    expect(hits.first.field, 'original');
  });
  test('matches machine-translated text', () async {
    await seed('m1', [
      {
        'id': '1',
        'content_original': 'שלום, נתראה מחר',
        'content_translated': 'Hi, see you tomorrow',
        'created_at': '1',
      },
    ]);
    // Searching the English word only finds it via the translation.
    final hits = await db.searchCachedMessages('tomorrow', matchIds: ['m1']);
    expect(hits, hasLength(1));
    expect(hits.first.field, 'translated');
  });
  test('matches the original text of a translated message', () async {
    await seed('m1', [
      {
        'id': '1',
        'content_original': 'the climb is at six',
        'content_translated': 'הטיול מתחיל בשש',
        'created_at': '1',
      },
    ]);
    final hits = await db.searchCachedMessages('climb', matchIds: ['m1']);
    expect(hits, hasLength(1));
    expect(hits.first.field, 'original');
  });
  test('search is case-insensitive', () async {
    await seed('m1', [
      {'id': '1', 'content_original': 'Bouldering GYM tonight', 'created_at': '1'},
    ]);
    expect(
      await db.searchCachedMessages('bouldering', matchIds: ['m1']),
      hasLength(1),
    );
    expect(
      await db.searchCachedMessages('GYM', matchIds: ['m1']),
      hasLength(1),
    );
  });
  test('scopes to the given match ids only', () async {
    await seed('m1', [
      {'id': '1', 'content_original': 'shared word', 'created_at': '1'},
    ]);
    await seed('m2', [
      {'id': '1', 'content_original': 'shared word', 'created_at': '1'},
    ]);
    final hits = await db.searchCachedMessages('shared', matchIds: ['m1']);
    expect(hits, hasLength(1));
    expect(hits.first.matchId, 'm1');
  });
  test('empty query and empty scope return nothing', () async {
    await seed('m1', [
      {'id': '1', 'content_original': 'anything', 'created_at': '1'},
    ]);
    expect(await db.searchCachedMessages('', matchIds: ['m1']), isEmpty);
    expect(await db.searchCachedMessages('   ', matchIds: ['m1']), isEmpty);
    expect(await db.searchCachedMessages('any', matchIds: const []), isEmpty);
  });
  test('returns one hit per message even when several fields match', () async {
    await seed('m1', [
      {
        'id': '1',
        'content_original': 'climb',
        'content_translated': 'climb',
        'reply_to_content': 'climb',
        'created_at': '1',
      },
    ]);
    expect(
      await db.searchCachedMessages('climb', matchIds: ['m1']),
      hasLength(1),
    );
  });
  test('snippet shows the match with surrounding context', () async {
    final filler = 'word ' * 60;
    await seed('m1', [
      {
        'id': '1',
        'content_original': '$filler NEEDLE $filler',
        'created_at': '1',
      },
    ]);
    final hits = await db.searchCachedMessages('needle', matchIds: ['m1']);
    expect(hits, hasLength(1));
    expect(hits.first.snippet.toLowerCase(), contains('needle'));
    // Trimmed rather than dumped whole, and elided at both ends.
    expect(hits.first.snippet.length, lessThan(200));
    expect(hits.first.snippet, startsWith('…'));
    expect(hits.first.snippet, endsWith('…'));
  });
  test('a short message has no ellipsis in its snippet', () async {
    await seed('m1', [
      {'id': '1', 'content_original': 'find the NEedle', 'created_at': '1'},
    ]);
    final hits = await db.searchCachedMessages('needle', matchIds: ['m1']);
    expect(hits.first.snippet, 'find the NEedle');
  });
  test('unknown match ids are skipped, not thrown on', () async {
    expect(
      await db.searchCachedMessages('anything', matchIds: ['nope', 'alsonope']),
      isEmpty,
    );
  });
}
