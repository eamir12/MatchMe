import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_activity.dart';

void main() {
  group('MeetupActivity.fromJson', () {
    test('parses a live row and keeps the expiry in UTC', () {
      final activity = MeetupActivity.fromJson({
        'match_id': 'match-1',
        'top_kind': 'beacon',
        'top_own': false,
        'tool_count': 3,
        'next_expiry': '2026-10-27T12:34:56+00:00',
      });

      expect(activity.topKind, MeetupActivityKind.beacon);
      expect(activity.topOwn, isFalse);
      expect(activity.toolCount, 3);
      expect(activity.nextExpiry, DateTime.utc(2026, 10, 27, 12, 34, 56));
      expect(activity.nextExpiry!.isUtc, isTrue);
    });

    test('accepts a null expiry for a share that runs until stopped', () {
      final activity = MeetupActivity.fromJson({
        'top_kind': 'live',
        'top_own': true,
        'tool_count': 1,
        'next_expiry': null,
      });

      expect(activity.topKind, MeetupActivityKind.live);
      expect(activity.topOwn, isTrue);
      expect(activity.topLabel, isNull);
      expect(activity.nextExpiry, isNull);
    });

    test('keeps the chosen place label for an active meet-up', () {
      final activity = MeetupActivity.fromJson({
        'top_kind': 'active',
        'top_own': false,
        'top_label': 'Dizengoff Square',
        'tool_count': 2,
      });

      expect(activity.topLabel, 'Dizengoff Square');
      expect(activity.toolCount, 2);
    });

    test('treats a blank place label as absent', () {
      final activity = MeetupActivity.fromJson({
        'top_kind': 'active',
        'top_own': false,
        'top_label': '   ',
      });

      expect(activity.topLabel, isNull);
    });

    test('keeps the gesture of a winning wave', () {
      final activity = MeetupActivity.fromJson({
        'top_kind': 'wave',
        'top_own': false,
        'top_gesture': 'jumping',
        'tool_count': 1,
      });

      expect(activity.topKind, MeetupActivityKind.wave);
      expect(activity.topGesture, 'jumping');
    });

    test('has no gesture for a beacon or a blank payload', () {
      final beacon = MeetupActivity.fromJson({
        'top_kind': 'beacon',
        'top_own': true,
        'top_gesture': null,
      });
      final legacyWave = MeetupActivity.fromJson({
        'top_kind': 'wave',
        'top_own': false,
        'top_gesture': '  ',
      });

      expect(beacon.topGesture, isNull);
      expect(legacyWave.topGesture, isNull);
    });

    test('fails closed when optional fields are missing', () {
      final activity = MeetupActivity.fromJson(const {});

      expect(activity.topKind, isEmpty);
      expect(activity.topOwn, isFalse);
      expect(activity.toolCount, 1);
      expect(activity.topLabel, isNull);
      expect(activity.topGesture, isNull);
      expect(activity.nextExpiry, isNull);
    });
  });
}
