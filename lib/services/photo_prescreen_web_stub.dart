// lib/services/photo_prescreen_web_stub.dart
// Non-web fallback: no local ML detector, caller falls back to Gemini.
import 'dart:typed_data';

/// Runs the MediaPipe JS still-image detector on web.
/// Returns the native-shaped result map, or null when unavailable so the
/// caller defers person checks to Gemini.
Future<Map<String, Object?>?> analyzePhotoPrescreenWeb(Uint8List bytes) async =>
    null;
