import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/list_sync_gate.dart';

void main() {
  group('ListSyncGate', () {
    final gate = ListSyncGate(kind: 'chats', random: Random(7));
    final now = DateTime.utc(2026, 11, 1, 8);

    test('no watermark forces a full fetch even when a full sync just ran', () {
      final plan = gate.plan(
        userId: 'u1',
        watermark: null,
        lastFullAt: now,
        now: now,
      );
      expect(plan.isFull, isTrue);
      expect(plan.since, isNull);
    });

    test('a fresh full sync keeps subsequent starts on the delta', () {
      final plan = gate.plan(
        userId: 'u1',
        watermark: '2026-11-01T07:59:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 23)),
        now: now,
      );
      expect(plan.isFull, isFalse);
      expect(plan.since, '2026-11-01T07:59:00+00:00');
    });

    test('a due reconcile defers the full fetch past the startup burst', () {
      final first = gate.plan(
        userId: 'u1',
        watermark: '2026-10-31T08:00:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 24)),
        now: now,
      );
      expect(first.isFull, isFalse);
      expect(first.since, isNotNull);

      final duringBurst = gate.plan(
        userId: 'u1',
        watermark: '2026-10-31T08:00:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 24)),
        now: now.add(const Duration(seconds: 30)),
      );
      expect(duringBurst.isFull, isFalse);

      final afterDelay = gate.plan(
        userId: 'u1',
        watermark: '2026-10-31T08:00:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 24)),
        now: now.add(const Duration(minutes: 10)),
      );
      expect(afterDelay.isFull, isTrue);
    });

    test('the deferred schedule is per user', () {
      final otherGate = ListSyncGate(kind: 'matches', random: Random(1));
      final dueArgs = (
        watermark: '2026-10-31T08:00:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 25)),
      );
      final first = otherGate.plan(
        userId: 'u1',
        watermark: dueArgs.watermark,
        lastFullAt: dueArgs.lastFullAt,
        now: now,
      );
      expect(first.isFull, isFalse);

      final otherUser = otherGate.plan(
        userId: 'u2',
        watermark: dueArgs.watermark,
        lastFullAt: dueArgs.lastFullAt,
        now: now.add(const Duration(minutes: 10)),
      );
      expect(otherUser.isFull, isFalse,
          reason: 'u2 schedules its own deferred fetch');

      final u1AfterDelay = otherGate.plan(
        userId: 'u1',
        watermark: dueArgs.watermark,
        lastFullAt: dueArgs.lastFullAt,
        now: now.add(const Duration(minutes: 10)),
      );
      expect(u1AfterDelay.isFull, isTrue);
    });

    test('reset forgets the deferred schedule', () {
      final resetGate = ListSyncGate(kind: 'chats', random: Random(3));
      resetGate.plan(
        userId: 'u1',
        watermark: '2026-10-31T08:00:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 30)),
        now: now,
      );
      resetGate.reset('u1');
      final afterReset = resetGate.plan(
        userId: 'u1',
        watermark: '2026-10-31T08:00:00+00:00',
        lastFullAt: now.subtract(const Duration(hours: 30)),
        now: now.add(const Duration(minutes: 10)),
      );
      expect(afterReset.isFull, isFalse,
          reason: 'a reset user schedules a new deferred fetch');
    });

    test('cursor keys are namespaced per kind and user', () {
      expect(gate.watermarkKey('u1'), 'list_sync_v1_chats_watermark_u1');
      expect(gate.fullSyncAtKey('u1'), 'list_sync_v1_chats_full_at_u1');
      expect(gate.watermarkKey('u1'), isNot(contains('matches')));
    });
  });

  group('maxUpdatedAt', () {
    test('returns the newest raw server value', () {
      final raw = maxUpdatedAt([
        {'updated_at': '2026-11-01T08:00:01.123456+00:00'},
        {'updated_at': '2026-11-01T08:00:02.000001+00:00'},
        {'updated_at': '2026-11-01T07:59:59+00:00'},
      ]);
      expect(raw, '2026-11-01T08:00:02.000001+00:00');
    });

    test('ignores rows without a usable updated_at', () {
      expect(maxUpdatedAt([]), isNull);
      expect(maxUpdatedAt([{'id': 'x'}]), isNull);
      expect(
        maxUpdatedAt([
          {'updated_at': 'not-a-timestamp'},
          {'updated_at': ''},
          'not-a-map',
        ]),
        isNull,
      );
    });
  });
}
