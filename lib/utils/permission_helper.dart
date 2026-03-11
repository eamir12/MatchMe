import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionHelper {
  static Future<void> requestNotificationPermission() async {
    if (!kIsWeb && Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        debugPrint('Requesting notification permission...');
        final result = await Permission.notification.request();
        debugPrint('Notification permission result: $result');
      } else {
        debugPrint('Notification permission status: $status');
      }
    }
  }
}
