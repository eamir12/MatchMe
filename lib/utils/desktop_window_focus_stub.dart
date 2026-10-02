// lib/utils/desktop_window_focus_stub.dart
//
// On web the OAuth round trip never leaves a separate window - the browser tab
// hosting the app is the app - so there is nothing to raise. Mobile has no
// such concept either; the OS brings the app forward when the deep link fires.

/// Whether [focusAppWindow] can actually do anything on this platform.
bool get canFocusAppWindow => false;

/// Best-effort: bring the app's window to the front. No-op on web/mobile.
Future<void> focusAppWindow() async {}
