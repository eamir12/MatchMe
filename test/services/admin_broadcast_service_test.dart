// Regression test for the duplicate admin-broadcast notification bug:
// one admin "Resend" click produced two identical tray entries because the FCM
// background isolate re-posted the notification the Android/FCM SDK had already
// displayed from the message's `notification` block.
//
// See ADMIN_BROADCAST_DUPLICATE_NOTIFICATION_FIX.md.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/admin_broadcast_service.dart';

void main() {
  group('AdminBroadcastService.shouldShowOsNotification', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    /// Shape the server sends (cron-jobs `sendFcmV1`):
    /// notification+data with `tag = admin_<broadcast_id>`.
    RemoteMessage adminPush({bool withNotificationBlock = true}) {
      return RemoteMessage(
        messageId: '0:1700000000000000%abcdef',
        data: <String, dynamic>{
          'type': 'admin_broadcast',
          'broadcast_id': '11111111-1111-1111-1111-111111111111',
          'badge': '1',
        },
        notification: withNotificationBlock
            ? const RemoteNotification(
                title: 'Test title for Eran',
                body: 'test message for Eran',
              )
            : null,
      );
    }

    test('foreground isolate still posts its own tray entry', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        AdminBroadcastService.shouldShowOsNotification(adminPush()),
        isTrue,
      );
    });

    test(
      'background isolate skips notification+data (already drawn by FCM)',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(
          AdminBroadcastService.shouldShowOsNotification(
            adminPush(),
            fromBackground: true,
          ),
          isFalse,
        );
      },
    );

    test('background isolate skips notification+data on iOS as well', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        AdminBroadcastService.shouldShowOsNotification(
          adminPush(),
          fromBackground: true,
        ),
        isFalse,
      );
    });

    test('background isolate renders data-only pushes itself', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        AdminBroadcastService.shouldShowOsNotification(
          adminPush(withNotificationBlock: false),
          fromBackground: true,
        ),
        isTrue,
      );
    });

    test('desktop platforms never post OS notifications', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        AdminBroadcastService.shouldShowOsNotification(adminPush()),
        isFalse,
      );
    });
  });
}
