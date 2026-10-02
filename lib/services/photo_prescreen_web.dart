// lib/services/photo_prescreen_web.dart
// Web-only bridge to web/photo_prescreen.js (MediaPipe FaceDetector +
// PoseLandmarker). Loaded via conditional import from
// photo_prescreen_service.dart.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

@JS('MatchMePhotoPrescreen.analyze')
external JSPromise<JSAny?> _analyzePhotoPrescreen(JSString base64Image);

/// Runs the MediaPipe JS still-image detector.
/// Returns the native-shaped result map, or null when the JS bridge or
/// models are unavailable so the caller defers person checks to Gemini.
Future<Map<String, Object?>?> analyzePhotoPrescreenWeb(Uint8List bytes) async {
  try {
    final promise = _analyzePhotoPrescreen(base64Encode(bytes).toJS);
    final jsResult = await promise.toDart;
    if (jsResult == null || jsResult.isUndefinedOrNull) return null;
    final dartified = jsResult.dartify();
    if (dartified is Map) {
      return Map<String, Object?>.from(dartified);
    }
    return null;
  } catch (_) {
    return null;
  }
}
