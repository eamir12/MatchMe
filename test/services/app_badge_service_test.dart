import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:matchme/services/app_badge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('matchme/badge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('publishes the count together with the localized body', () async {
    await AppBadgeService.setCount(3, body: '3 unread');

    expect(AppBadgeService.currentCount, 3);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setBadgeCount');
    expect(calls.single.arguments, {'count': 3, 'body': '3 unread'});
  });

  test('omits the body when it is empty', () async {
    await AppBadgeService.setCount(2, body: '');

    expect(calls.single.arguments, {'count': 2});
  });

  test('clamps negative counts to zero', () async {
    await AppBadgeService.setCount(-4);

    expect(AppBadgeService.currentCount, 0);
    expect(calls.single.arguments, {'count': 0});
  });

  test('clear resets the published count and clears the platform badge',
      () async {
    await AppBadgeService.setCount(7, body: '7 unread');
    await AppBadgeService.clear();

    expect(AppBadgeService.currentCount, 0);
    expect(calls.map((call) => call.method), ['setBadgeCount', 'clearBadge']);
  });

  test('a platform failure never escapes to the caller', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });

    await expectLater(AppBadgeService.setCount(5), completes);
    expect(AppBadgeService.currentCount, 5);
  });
}
