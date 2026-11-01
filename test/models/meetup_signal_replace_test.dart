import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_models.dart';

MeetupSignal _signal({
  required String id,
  required String senderId,
  MeetupSignalType type = MeetupSignalType.wave,
  String gesture = kMeetupGestureWave,
  int ageSeconds = 0,
  int secondsLeft = 60,
}) {
  final now = DateTime.now();
  return MeetupSignal(
    id: id,
    sessionId: null,
    senderId: senderId,
    type: type,
    payload: <String, dynamic>{'gesture': gesture},
    createdAt: now.subtract(Duration(seconds: ageSeconds)),
    expiresAt: now.add(Duration(seconds: secondsLeft)),
  );
}

List<String> _replace({
  required List<MeetupSignal> signals,
  required String? userId,
  required MeetupSignalType type,
  required MeetupSignal signal,
}) => replaceOwnMeetupSignal(
  signals: signals,
  userId: userId,
  type: type,
  signal: signal,
).map((item) => item.id).toList(growable: false);

void main() {
  group('replaceOwnMeetupSignal', () {
    test('your earlier signal is gone the moment you send a new one', () {
      final ids = _replace(
        signals: [
          _signal(
            id: 'wave-1',
            senderId: 'me',
            gesture: kMeetupGestureJumping,
            ageSeconds: 12,
          ),
        ],
        userId: 'me',
        type: MeetupSignalType.wave,
        signal: _signal(id: 'wave-2', senderId: 'me'),
      );

      expect(ids, ['wave-2']);
    });

    test('a signal the other person sent is never yours to replace', () {
      final ids = _replace(
        signals: [
          _signal(id: 'theirs', senderId: 'them'),
          _signal(id: 'wave-1', senderId: 'me'),
        ],
        userId: 'me',
        type: MeetupSignalType.wave,
        signal: _signal(id: 'wave-2', senderId: 'me'),
      );

      expect(ids, ['theirs', 'wave-2']);
    });

    test('a beacon resend leaves your wave standing', () {
      final ids = _replace(
        signals: [
          _signal(id: 'wave-1', senderId: 'me'),
          _signal(
            id: 'beacon-1',
            senderId: 'me',
            type: MeetupSignalType.beacon,
          ),
        ],
        userId: 'me',
        type: MeetupSignalType.beacon,
        signal: _signal(
          id: 'beacon-2',
          senderId: 'me',
          type: MeetupSignalType.beacon,
        ),
      );

      expect(ids, ['wave-1', 'beacon-2']);
    });

    test('a row of yours that already ran out goes with it', () {
      final ids = _replace(
        signals: [_signal(id: 'expired', senderId: 'me', secondsLeft: -5)],
        userId: 'me',
        type: MeetupSignalType.wave,
        signal: _signal(id: 'wave-2', senderId: 'me'),
      );

      expect(ids, ['wave-2']);
    });

    test('a signed-out viewer replaces nothing', () {
      // Sender ids are never null, so a missing user id must not be read as a
      // match and silently hide the partner's card.
      final ids = _replace(
        signals: [_signal(id: 'theirs', senderId: 'them')],
        userId: null,
        type: MeetupSignalType.wave,
        signal: _signal(id: 'wave-2', senderId: 'me'),
      );

      expect(ids, ['theirs', 'wave-2']);
    });
  });
}
