import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/meetup_alert_card.dart';

void main() {
  const match = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  const sender = '11111111-2222-3333-4444-555555555555';
  const signal = '99999999-8888-7777-6666-555544443333';

  group('the card a wave or beacon is posted under', () {
    test('keys on sender and match, because a resend replaces the row', () {
      final data = <String, dynamic>{
        'matchId': match,
        'senderId': sender,
        'meetup_signal_id': signal,
      };
      expect(
        meetupAlertCardKey(kMeetupAlertSignal, data),
        'meetup_signal_${match}_$sender',
      );
      expect(
        meetupAlertCardKey(kMeetupAlertBeacon, data),
        'meetup_beacon_${match}_$sender',
      );
    });

    test(
      'falls back to the row id when it cannot tell the directions apart',
      () {
        expect(
          meetupAlertCardKey(kMeetupAlertSignal, {'meetup_signal_id': signal}),
          'meetup_signal_$signal',
        );
      },
    );

    test('accepts either spelling of the payload keys', () {
      final snake = <String, dynamic>{'match_id': match, 'sender_id': sender};
      final camel = <String, dynamic>{'matchId': match, 'senderId': sender};
      expect(
        meetupAlertCardKey(kMeetupAlertSignal, snake),
        meetupAlertCardKey(kMeetupAlertSignal, camel),
      );
    });
  });

  group('the collapse tag the push carries', () {
    test('truncates the live-signal ids, matching the server contract', () {
      expect(
        meetupAlertServerTag(kMeetupAlertSignal, {
          'matchId': match,
          'senderId': sender,
          'meetup_signal_id': signal,
        }),
        'meetup_signal_aaaaaaaa_11111111',
      );
    });

    test('keeps a short id whole instead of slicing past its end', () {
      expect(
        meetupAlertServerTag(kMeetupAlertBeacon, {
          'matchId': 'match-1',
          'senderId': 'user-2',
        }),
        'meetup_beacon_match-1_user-2',
      );
    });

    test('keys the one-shot tools on their own row', () {
      expect(
        meetupAlertServerTag(kMeetupAlertSpot, {
          'matchId': match,
          'meetup_spot_id': signal,
        }),
        'meetup_spot_$signal',
      );
      expect(
        meetupAlertServerTag(kMeetupAlertProposal, {
          'matchId': match,
          'meetup_session_id': sender,
        }),
        'meetup_proposal_$sender',
      );
      expect(
        meetupAlertServerTag(kMeetupAlertPlaceChange, {'matchId': match}),
        'meetup_place_change_$match',
      );
    });

    test('the card key and the tag name the same event', () {
      final data = <String, dynamic>{
        'matchId': match,
        'senderId': sender,
        'meetup_signal_id': signal,
      };
      for (final kind in kMeetupAlertKinds) {
        final cardKey = meetupAlertCardKey(kind, data);
        final tag = meetupAlertServerTag(kind, data);
        expect(cardKey, startsWith('${kind}_'));
        expect(tag, startsWith('${kind}_'));
      }
    });

    test('an event no payload names has no card to cancel', () {
      expect(meetupAlertCardKey(kMeetupAlertSpot, const {}), '');
      expect(meetupAlertServerTag(kMeetupAlertSpot, const {}), '');
    });
  });

  test('the kinds are exactly the tools the alert bar knows', () {
    expect(kMeetupAlertKinds, {
      kMeetupAlertSignal,
      kMeetupAlertBeacon,
      kMeetupAlertSpot,
      kMeetupAlertProposal,
      kMeetupAlertPlaceChange,
    });
    for (final kind in kMeetupAlertKinds) {
      expect(kMeetupAlertDefaultTtl[kind]!.inSeconds, greaterThan(0));
    }
  });
}
