// web_imports_stub.dart - Stub implementations for non-web platforms

import 'dart:typed_data';

class HtmlDocument {
  // Stub
  bool get hidden => false;
  String get visibilityState => 'visible';
  void addEventListener(String type, Function? listener) {}
}

class Window {
  // Stub
  Location get location => Location();
  History get history => History();
  void addEventListener(String type, Function? listener) {}
}

class KeyboardEvent {
  // Stub
}

class Event {
  // Stub
}

class Location {
  String get href => '';
  void reload() {}
}

class History {
  void replaceState(dynamic data, String title, String? url) {}
}

// Stub variables
final HtmlDocument document = HtmlDocument();
final Window window = Window();

bool sendOfflineBeacon(String url, String data) {
  return false;
}

// Stub safeVibrate: no-op on non-web platforms
void safeVibrate(Object pattern) {}

Future<Uint8List?> pickImageBytesFromCamera({
  String capture = 'user',
  String? captureButtonText,
  String? cancelButtonText,
}) async {
  return null;
}
