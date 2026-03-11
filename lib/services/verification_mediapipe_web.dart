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
    if (event.data is! Map) return;
    final data = event.data as Map;
    if (data['type'] == 'verificationPhoto' && data['data'] != null) {
      html.window.removeEventListener('message', handleMessage);
      try {
        final base64 = data['data'] as String;
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
