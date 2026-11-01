// In-memory last suggestion lookup for the meet-up picker.
//
// The meet-up provider is autoDispose, so leaving the screen used to discard
// the places the user had just fetched and every re-entry paid for a new
// position fix and a new provider call. This cache keeps the last lookup for
// the process lifetime and lets the picker restore it when the device has not
// meaningfully moved.
//
// It deliberately has no disk box: the coarsened anchor is still a location,
// and the app promises to keep none. An app restart clears everything. The
// stored anchor is the same four-decimal value already sent to the provider.

import 'package:latlong2/latlong.dart';
import 'package:matchme/models/meetup_models.dart';

class MeetupCachedSuggestionLookup {
  final LatLng anchor;
  final String languageCode;
  final String provider;
  final List<MeetupPlaceSuggestion> suggestions;
  final List<MeetupPlaceSuggestion> pool;
  final String source;

  const MeetupCachedSuggestionLookup({
    required this.anchor,
    required this.languageCode,
    required this.provider,
    required this.suggestions,
    required this.pool,
    required this.source,
  });
}

class MeetupSuggestionCache {
  MeetupSuggestionCache();

  static final MeetupSuggestionCache instance = MeetupSuggestionCache();

  /// Two fixes within this distance of the cached anchor count as the same
  /// place. Indoor and crowd accuracy is commonly 30-100 m, so a tighter
  /// radius would refetch while the user stands still.
  static const double samePlaceRadiusMeters = 200;

  final Map<String, MeetupCachedSuggestionLookup> _memory = {};

  // Keyed per user as well as per match, so an account switch on the same
  // device never restores another user's last lookup.
  String _key(String userId, String matchId) => '$userId:$matchId';

  MeetupCachedSuggestionLookup? lookup({
    required String userId,
    required String matchId,
    required LatLng anchor,
    required String languageCode,
    required String provider,
  }) {
    if (userId.isEmpty || matchId.isEmpty) return null;
    final cached = _memory[_key(userId, matchId)];
    if (cached == null || cached.suggestions.isEmpty) return null;
    if (cached.languageCode != languageCode) return null;
    if (cached.provider != provider) return null;
    final distance =
        const Distance().as(LengthUnit.Meter, anchor, cached.anchor);
    if (distance > samePlaceRadiusMeters) return null;
    return cached;
  }

  /// The last lookup for this match without the distance gate. Used to show
  /// the list the user already fetched (for example when editing a pending
  /// proposal) without a new position fix or provider call. In-memory only,
  /// so it dies with the process like every other entry.
  MeetupCachedSuggestionLookup? latest({
    required String userId,
    required String matchId,
    required String languageCode,
  }) {
    if (userId.isEmpty || matchId.isEmpty) return null;
    final cached = _memory[_key(userId, matchId)];
    if (cached == null || cached.suggestions.isEmpty) return null;
    if (cached.languageCode != languageCode) return null;
    return cached;
  }

  void store({
    required String userId,
    required String matchId,
    required LatLng anchor,
    required String languageCode,
    required String provider,
    required List<MeetupPlaceSuggestion> suggestions,
    required List<MeetupPlaceSuggestion> pool,
    required String source,
  }) {
    if (userId.isEmpty || matchId.isEmpty || suggestions.isEmpty) return;
    _memory[_key(userId, matchId)] = MeetupCachedSuggestionLookup(
      anchor: anchor,
      languageCode: languageCode,
      provider: provider,
      suggestions: suggestions,
      pool: pool,
      source: source,
    );
  }

  /// Keeps the cached entry in step with "Show other places", so re-entering
  /// the screen restores the page the user was looking at.
  void updatePage({
    required String userId,
    required String matchId,
    required List<MeetupPlaceSuggestion> suggestions,
    required List<MeetupPlaceSuggestion> pool,
  }) {
    if (userId.isEmpty || matchId.isEmpty) return;
    final key = _key(userId, matchId);
    final cached = _memory[key];
    if (cached == null) return;
    _memory[key] = MeetupCachedSuggestionLookup(
      anchor: cached.anchor,
      languageCode: cached.languageCode,
      provider: cached.provider,
      suggestions: suggestions,
      pool: pool,
      source: cached.source,
    );
  }

  void clearAll() => _memory.clear();
}
