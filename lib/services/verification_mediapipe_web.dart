// Web-only: open verification_capture.html in a new window and listen for photo.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:matchme/services/voice_guidance_service.dart';

/// Opens the MediaPipe gesture capture page (same origin). When user captures a photo,
/// [onPhoto] is called with the JPEG bytes. [context] is ignored on web.
/// [onClose] is called when the popup is closed without delivering a photo.
void openMediaPipeVerificationCapture({
  required String gestureCode,
  required void Function(Uint8List?) onPhoto,
  String? gestureLabel,
  String? gestureDescription,
  String? localeCode,
  Map<String, String>? captureStrings,
  Uint8List? inputImageBytes,
  BuildContext? context,
  void Function()? onClose,
}) {
  final base = web.window.location;
  final pathname = base.pathname;
  final path = pathname.endsWith('/')
      ? '$pathname'
            'verification_capture.html'
      : '$pathname/verification_capture.html';
  final queryParams = <String, String>{
    'gesture': gestureCode,
    if (gestureLabel != null && gestureLabel.trim().isNotEmpty)
      'label': gestureLabel,
    if (gestureDescription != null && gestureDescription.trim().isNotEmpty)
      'description': gestureDescription,
    if (localeCode != null && localeCode.trim().isNotEmpty)
      'locale': localeCode,
    if (captureStrings != null && captureStrings.isNotEmpty)
      'strings': base64UrlEncode(utf8.encode(jsonEncode(captureStrings))),
  };
  final url = '${base.origin}$path?${Uri(queryParameters: queryParams).query}';
  final popup = web.window.open(
    url,
    'verification_capture',
    'width=600,height=800,scrollbars=no',
  );
  if (popup == null) {
    onPhoto(null);
    onClose?.call();
    return;
  }

  var photoReceived = false;
  var isWaitingForSpeech = false;
  // Primary selfie: speak the instructions aloud while the popup loads. The
  // capture page itself enforces a minimum page-open time plus a longer
  // hold-steady gate in FACE_ONLY mode, so auto-capture waits for speech.
  if (gestureCode == 'FACE_ONLY') {
    final label = (gestureLabel ?? '').trim();
    final description = (gestureDescription ?? '').trim();
    final text = [label, description]
        .where((s) => s.isNotEmpty)
        .join('. ');
    if (text.isNotEmpty) {
      unawaited(
        VoiceGuidanceService.instance.speakAndWait(
          text,
          timeout: const Duration(seconds: 30),
        ),
      );
    }
  }
  late final JSFunction messageListener;
  Timer? closePoll;
  void stopClosePoll() {
    try {
      closePoll?.cancel();
    } catch (_) {}
    closePoll = null;
  }

  void handleMessage(web.Event e) {
    final event = e as web.MessageEvent;
    if (event.origin != base.origin) return;

    dynamic payload;
    try {
      payload = event.data.dartify();
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
      if (photoReceived || isWaitingForSpeech) return;
      isWaitingForSpeech = true;
      stopClosePoll();
      web.window.removeEventListener('message', messageListener);
      () async {
        try {
          final bytes = Uint8List.fromList(base64Decode(base64!));
          if (VoiceGuidanceService.instance.isSpeaking) {
            await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished();
          }
          photoReceived = true;
          popup.close();
          onPhoto(bytes);
        } catch (_) {
          photoReceived = true;
          popup.close();
          onPhoto(null);
        }
      }();
    } else if (type == 'verificationCaptureLog' &&
        base64 != null &&
        base64.isNotEmpty) {
      // Diagnostics forwarded by the capture page (ready/stuck/error) plus
      // 'voice' live-coaching events. Here `base64` actually holds the inner
      // reportLog JSON string (see handleMessage's generic decode). Voice
      // events are spoken via the shared guidance service; the rest stay
      // console-only.
      try {
        final inner = jsonDecode(base64);
        if (inner is Map && inner['type']?.toString() == 'voice') {
          if (isWaitingForSpeech || photoReceived) return;
          final data = inner['data'];
          final key = data is Map ? data['key']?.toString() : null;
          if (key != null && key.isNotEmpty) {
            unawaited(VoiceGuidanceService.instance.speakKey(key));
          }
          return;
        }
      } catch (_) {}
      // ignore: avoid_print
      print('VERIFICATION CAPTURE [popup]: $base64');
    }
  }

  if (onClose != null) {
    closePoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      var closed = false;
      try {
        closed = popup.closed;
      } catch (_) {
        closed = false;
      }
      if (closed && !photoReceived) {
        stopClosePoll();
        web.window.removeEventListener('message', messageListener);
        onClose.call();
      }
    });
  }

  messageListener = handleMessage.toJS;
  web.window.addEventListener('message', messageListener);
}
