// The one rule every surface that announces a meet-up signal uses: the newest
// live signal the other side sent wins, whatever its type.
//
// This used to be decided per surface, and the surfaces disagreed. The chat
// banner answered "is waving" for a wave older than the beacon it ignored, the
// alert bar above the Navigator ranked by time, and the match card asked the
// server, which ranks by tool type. Only the newest can be what the sender just
// did, so the newest is what all of them have to say.

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/meetup_provider.dart';

const String _me = 'me';
const String _other = 'other';

MeetupSignal _signal({
  required String id,
  required MeetupSignalType type,
  required String senderId,
  required DateTime createdAt,
  int liveForSeconds = 120,
  String gesture = kMeetupGestureWave,
}) {
  return MeetupSignal(
    id: id,
    sessionId: null,
    senderId: senderId,
    type: type,
    payload: {if (type == MeetupSignalType.wave) 'gesture': gesture},
    createdAt: createdAt.toUtc(),
    expiresAt: createdAt.add(Duration(seconds: liveForSeconds)).toUtc(),
  );
}

void main() {
  // Live windows are compared against the wall clock, so the reference point is
  // "now" rather than a fixed date; every signal below is still inside its own.
  final base = DateTime.now().toUtc();

  MeetupState stateWith(List<MeetupSignal> signals) {
    return MeetupState(
      loading: false,
      currentUserId: _me,
      // Far enough in the future that nothing here is expired.
      signals: signals,
    );
  }

  group('latest incoming signal', () {
    test('the beacon started after a wave is the newest', () {
      final state = stateWith([
        _signal(
          id: 'wave-1',
          type: MeetupSignalType.wave,
          senderId: _other,
          createdAt: base.subtract(const Duration(seconds: 20)),
        ),
        _signal(
          id: 'beacon-1',
          type: MeetupSignalType.beacon,
          senderId: _other,
          createdAt: base,
        ),
      ]);

      expect(state.latestIncomingSignal?.id, 'beacon-1');
      // The feed still shows one card per live tool, so each type keeps its own
      // newest rather than collapsing into the single newest.
      expect(state.incomingWave?.id, 'wave-1');
      expect(state.incomingBeacon?.id, 'beacon-1');
    });

    test('a wave sent while a beacon is on is the newest', () {
      final state = stateWith([
        _signal(
          id: 'beacon-1',
          type: MeetupSignalType.beacon,
          senderId: _other,
          createdAt: base.subtract(const Duration(seconds: 30)),
        ),
        _signal(
          id: 'wave-2',
          type: MeetupSignalType.wave,
          senderId: _other,
          createdAt: base,
          gesture: kMeetupGestureJumping,
        ),
      ]);

      expect(state.latestIncomingSignal?.id, 'wave-2');
      expect(meetupSignalGesture(state.latestIncomingSignal!), 'jumping');
    });

    test(
      'the newest of the same type is the one that replaced the earlier',
      () {
        final state = stateWith([
          _signal(
            id: 'wave-1',
            type: MeetupSignalType.wave,
            senderId: _other,
            createdAt: base.subtract(const Duration(seconds: 40)),
            gesture: kMeetupGestureWave,
          ),
          _signal(
            id: 'wave-2',
            type: MeetupSignalType.wave,
            senderId: _other,
            createdAt: base,
            gesture: kMeetupGestureArmsWide,
          ),
        ]);

        expect(state.latestIncomingSignal?.id, 'wave-2');
        expect(
          meetupSignalGesture(state.latestIncomingSignal!),
          kMeetupGestureArmsWide,
        );
      },
    );

    test('a dismissed signal falls back to the older live one', () {
      final state = MeetupState(
        loading: false,
        currentUserId: _me,
        signals: [
          _signal(
            id: 'wave-1',
            type: MeetupSignalType.wave,
            senderId: _other,
            createdAt: base.subtract(const Duration(seconds: 10)),
          ),
          _signal(
            id: 'beacon-1',
            type: MeetupSignalType.beacon,
            senderId: _other,
            createdAt: base,
          ),
        ],
        hiddenSignalIds: const {'beacon-1'},
      );

      expect(state.latestIncomingSignal?.id, 'wave-1');
    });

    test('a signal that no longer exists live is not announced', () {
      final state = stateWith([
        _signal(
          id: 'beacon-1',
          type: MeetupSignalType.beacon,
          senderId: _other,
          // Already past its own window.
          createdAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 5),
          ),
          liveForSeconds: 60,
        ),
      ]);

      expect(state.latestIncomingSignal, isNull);
    });

    test('your own newest signal never becomes the incoming one', () {
      final state = stateWith([
        _signal(
          id: 'wave-1',
          type: MeetupSignalType.wave,
          senderId: _other,
          createdAt: base.subtract(const Duration(seconds: 30)),
        ),
        _signal(
          id: 'beacon-2',
          type: MeetupSignalType.beacon,
          senderId: _me,
          createdAt: base,
        ),
      ]);

      expect(state.latestIncomingSignal?.id, 'wave-1');
      expect(state.myBeacon?.id, 'beacon-2');
    });
  });
}
