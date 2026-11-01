import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/meetup_provider.dart';

MeetupPlaceSuggestion _place(String label) => MeetupPlaceSuggestion(
  label: label,
  category: 'park',
  latitude: 32.0,
  longitude: 34.0,
  distanceMeters: 100,
);

MeetupSession _session({
  MeetupStatus status = MeetupStatus.proposed,
  MeetupOrigin origin = MeetupOrigin.proximity,
  String proposedBy = 'user-1',
  Duration expiresIn = const Duration(minutes: 10),
}) {
  final now = DateTime.now().toUtc();
  return MeetupSession(
    id: 'session-1',
    matchId: 'match-1',
    createdBy: 'user-1',
    status: status,
    origin: origin,
    proposedBy: proposedBy,
    proposalRound: 1,
    createdAt: now,
    updatedAt: now,
    expiresAt: now.add(expiresIn),
  );
}

MeetupState _stateOn(MeetupSession session, {String userId = 'user-1'}) =>
    MeetupState(loading: false, currentUserId: userId, session: session);

void main() {
  group('canReplaceProposal', () {
    test('allows the proposer of a live proximity proposal', () {
      expect(_stateOn(_session()).canReplaceProposal, isTrue);
    });

    test('rejects the receiver', () {
      expect(_stateOn(_session(), userId: 'user-2').canReplaceProposal, isFalse);
    });

    test('rejects an expired proposal', () {
      final state = _stateOn(
        _session(expiresIn: const Duration(minutes: -1)),
      );

      expect(state.canReplaceProposal, isFalse);
    });

    test('rejects event proposals and non-proposed sessions', () {
      expect(
        _stateOn(_session(origin: MeetupOrigin.event)).canReplaceProposal,
        isFalse,
      );
      expect(
        _stateOn(_session(status: MeetupStatus.active)).canReplaceProposal,
        isFalse,
      );
      expect(
        _stateOn(_session(status: MeetupStatus.ended)).canReplaceProposal,
        isFalse,
      );
    });

    test('an earlier proposer cannot edit once the other side takes the round', () {
      final countered = _stateOn(_session(proposedBy: 'user-2'), userId: 'user-1');

      expect(countered.canCounter, isTrue);
      expect(countered.canAccept, isTrue);
      expect(countered.canReplaceProposal, isFalse);
    });
  });

  group('suggestion paging', () {
    test('advances three at a time and keeps the remainder', () {
      final state = MeetupState(
        loading: false,
        suggestions: [_place('a'), _place('b'), _place('c')],
        suggestionPool: [_place('d'), _place('e'), _place('f'), _place('g')],
      );

      final next = state.nextSuggestionPage();

      expect(next.suggestions.map((place) => place.label), ['d', 'e', 'f']);
      expect(next.suggestionPool.map((place) => place.label), ['g']);
      expect(next.suggestionSource, state.suggestionSource);
    });

    test('the last page drains the pool and the next call is a no-op', () {
      final state = MeetupState(
        loading: false,
        suggestions: [_place('a')],
        suggestionPool: [_place('b'), _place('c')],
      );

      final last = state.nextSuggestionPage();
      expect(last.suggestions.map((place) => place.label), ['b', 'c']);
      expect(last.suggestionPool, isEmpty);

      final again = last.nextSuggestionPage();
      expect(again.suggestions.map((place) => place.label), ['b', 'c']);
    });

    test('no pool means no change', () {
      final state = MeetupState(
        loading: false,
        suggestions: [_place('a'), _place('b'), _place('c')],
      );

      expect(state.nextSuggestionPage().suggestions, state.suggestions);
    });
  });
}
