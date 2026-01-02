// web_imports_stub.dart - Stub implementations for non-web platforms

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
}

class History {
  void replaceState(dynamic data, String title, String? url) {}
}

// Stub variables
final HtmlDocument document = HtmlDocument();
final Window window = Window();

// Stub safeVibrate: no-op on non-web platforms
void safeVibrate(Object pattern) {}