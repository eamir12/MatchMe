import 'dart:typed_data';

/// Non-io platforms have no WebView2 host; callers fall back to Gemini.
Future<Map<String, Object?>?> analyzePhotoPrescreenWindows(Uint8List bytes) async {
  return null;
}
