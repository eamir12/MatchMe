import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/home_refresh_utils.dart';

void main() {
  test('runs both content syncs and waits for both to complete', () async {
    final calls = <String>[];
    final matchesDone = Completer<void>();

    final refresh = HomeContentRefresh(
      syncMatches: () async {
        calls.add('matches');
        await matchesDone.future;
        calls.add('matches-complete');
      },
      syncChats: () async {
        calls.add('chats');
        calls.add('chats-complete');
      },
    );

    var completed = false;
    final future = refresh.run().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(calls, ['matches', 'chats', 'chats-complete']);
    expect(completed, isFalse);

    matchesDone.complete();
    await future;

    expect(calls, ['matches', 'chats', 'chats-complete', 'matches-complete']);
    expect(completed, isTrue);
  });
}
