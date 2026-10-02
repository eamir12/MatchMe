import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlatformTraceLogger {
  static const MethodChannel _channel = MethodChannel(
    'matchme/background_service',
  );

  static Future<void> trace(String tag, String message) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('traceLog', <String, String>{
        'tag': tag,
        'message': message,
      });
    } catch (_) {
      // Ignore bridge failures; local debugPrint remains the primary trace.
    }
  }
}
