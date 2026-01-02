// services/keyboard_service_stub.dart
// Stub implementation for non-web platforms

class KeyboardService {
  static final KeyboardService _instance = KeyboardService._internal();

  factory KeyboardService() => _instance;

  KeyboardService._internal();

  void initialize() {
    // Do nothing on non-web platforms
  }

  void dispose() {
    // Do nothing on non-web platforms
  }
}