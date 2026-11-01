import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/services/meetup_suggestion_cache.dart';

const LatLng _anchor = LatLng(32.1143, 34.8357);

MeetupPlaceSuggestion _place(String label) => MeetupPlaceSuggestion(
  label: label,
  category: 'park',
  latitude: 32.0,
  longitude: 34.0,
  distanceMeters: 100,
);

MeetupSuggestionCache _storedCache() {
  final cache = MeetupSuggestionCache();
  cache.store(
    userId: 'user-1',
    matchId: 'match-1',
    anchor: _anchor,
    languageCode: 'en',
    provider: 'google',
    suggestions: [_place('a'), _place('b'), _place('c')],
    pool: [_place('d'), _place('e')],
    source: 'google',
  );
  return cache;
}

MeetupCachedSuggestionLookup? _lookup(
  MeetupSuggestionCache cache, {
  String userId = 'user-1',
  String matchId = 'match-1',
  LatLng anchor = _anchor,
  String languageCode = 'en',
  String provider = 'google',
}) => cache.lookup(
  userId: userId,
  matchId: matchId,
  anchor: anchor,
  languageCode: languageCode,
  provider: provider,
);

void main() {
  group('meetup suggestion cache', () {
    test('restores a lookup within 200 m', () {
      final hit = _lookup(
        _storedCache(),
        anchor: const LatLng(32.1155, 34.8357), // ~133 m north
      );

      expect(hit, isNotNull);
      expect(hit!.suggestions.map((place) => place.label), ['a', 'b', 'c']);
      expect(hit.pool.map((place) => place.label), ['d', 'e']);
      expect(hit.source, 'google');
    });

    test('misses after a real move', () {
      final miss = _lookup(
        _storedCache(),
        anchor: const LatLng(32.1168, 34.8357), // ~278 m north
      );

      expect(miss, isNull);
    });

    test('misses when the language or provider changed', () {
      final cache = _storedCache();

      expect(_lookup(cache, languageCode: 'es'), isNull);
      expect(_lookup(cache, provider: 'osm'), isNull);
    });

    test('is scoped to one user and one match', () {
      final cache = _storedCache();

      expect(_lookup(cache, userId: 'user-2'), isNull);
      expect(_lookup(cache, matchId: 'match-2'), isNull);
    });

    test('keeps the current page after Show other places', () {
      final cache = _storedCache();
      cache.updatePage(
        userId: 'user-1',
        matchId: 'match-1',
        suggestions: [_place('d'), _place('e')],
        pool: const [],
      );

      final hit = _lookup(cache);

      expect(hit!.suggestions.map((place) => place.label), ['d', 'e']);
      expect(hit.pool, isEmpty);
      expect(hit.source, 'google');
    });

    test('latest restores the list regardless of distance', () {
      final cache = _storedCache();

      final hit = cache.latest(
        userId: 'user-1',
        matchId: 'match-1',
        languageCode: 'en',
      );

      expect(hit, isNotNull);
      expect(hit!.suggestions.map((place) => place.label), ['a', 'b', 'c']);
      expect(hit.pool.map((place) => place.label), ['d', 'e']);
      expect(hit.source, 'google');
    });

    test('latest stays scoped to user, match and language', () {
      final cache = _storedCache();

      expect(
        cache.latest(userId: 'user-2', matchId: 'match-1', languageCode: 'en'),
        isNull,
      );
      expect(
        cache.latest(userId: 'user-1', matchId: 'match-2', languageCode: 'en'),
        isNull,
      );
      expect(
        cache.latest(userId: 'user-1', matchId: 'match-1', languageCode: 'he'),
        isNull,
      );
      expect(
        cache.latest(userId: '', matchId: 'match-1', languageCode: 'en'),
        isNull,
      );
    });

    test('latest misses before the first lookup', () {
      final cache = MeetupSuggestionCache();

      expect(
        cache.latest(userId: 'user-1', matchId: 'match-1', languageCode: 'en'),
        isNull,
      );
    });

    test('ignores an empty lookup and clears on demand', () {
      final empty = MeetupSuggestionCache();
      empty.store(
        userId: 'user-1',
        matchId: 'match-1',
        anchor: _anchor,
        languageCode: 'en',
        provider: 'google',
        suggestions: const [],
        pool: const [],
        source: 'google',
      );
      expect(_lookup(empty), isNull);

      final stored = _storedCache();
      stored.clearAll();
      expect(_lookup(stored), isNull);
    });
  });
}
