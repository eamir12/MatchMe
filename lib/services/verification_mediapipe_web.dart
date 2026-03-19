// Web-only: open verification_capture.html in a new window and listen for photo.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Opens the MediaPipe gesture capture page (same origin). When user captures a photo,
/// [onPhoto] is called with the JPEG bytes. [context] is ignored on web.
void openMediaPipeVerificationCapture({
  required String gestureCode,
  required void Function(Uint8List?) onPhoto,
  String? gestureLabel,
  Map<String, String>? captureStrings,
  Uint8List? inputImageBytes,
  BuildContext? context,
}) {
  final base = html.window.location;
  final pathname = base.pathname ?? '/';
  final path = pathname.endsWith('/')
      ? '$pathname' 'verification_capture.html'
      : '$pathname/verification_capture.html';
  final queryParams = <String, String>{
    'gesture': gestureCode,
    if (gestureLabel != null && gestureLabel.trim().isNotEmpty) 'label': gestureLabel,
    if (captureStrings != null && captureStrings.isNotEmpty)
      'strings': base64UrlEncode(utf8.encode(jsonEncode(captureStrings))),
  };
  final url = '${base.origin}$path?${Uri(queryParameters: queryParams).query}';
  final popup = html.window.open(url, 'verification_capture', 'width=600,height=800,scrollbars=no');

  void handleMessage(html.Event e) {
    final event = e as html.MessageEvent;
    if (event.origin != base.origin) return;

    dynamic payload;
    try {
      payload = event.data;
    } catch (_) {
      return;
    }

    String? type;
    String? base64;
    if (payload is String) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          type = decoded['type']?.toString();
          final data = decoded['data'];
          base64 = data is String ? data : data?.toString();
        }
      } catch (_) {
        return;
      }
    } else if (payload is Map) {
      type = payload['type']?.toString();
      final data = payload['data'];
      base64 = data is String ? data : data?.toString();
    }

    if (type == 'verificationPhoto' && base64 != null && base64.isNotEmpty) {
      html.window.removeEventListener('message', handleMessage);
      try {
        final bytes = Uint8List.fromList(base64Decode(base64));
        popup.close();
        onPhoto(bytes);
      } catch (_) {
        onPhoto(null);
      }
    }
  }

  html.window.addEventListener('message', handleMessage);
}
