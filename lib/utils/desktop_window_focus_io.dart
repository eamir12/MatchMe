// lib/utils/desktop_window_focus_io.dart
//
// Desktop half of the OAuth round trip: the provider forces the user out to the
// system browser, and when the loopback callback lands the browser is left
// sitting on top of us. The OAuth tab itself cannot be closed from script -
// `window.close()` is a documented no-op for tabs the *browser* opened rather
// than a page - so the best we can do is put our own window back in front and
// let the user carry on. The stale tab is harmless; not seeing the app is not.

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:window_manager/window_manager.dart';

/// Whether [focusAppWindow] can actually do anything on this platform.
bool get canFocusAppWindow {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// Brings the app's window to the front, restoring it first if it was minimised.
///
/// Deliberately best-effort and never throws: a failed refocus is a cosmetic
/// annoyance, and must not be able to break a sign-in that otherwise succeeded.
///
/// Windows restricts `SetForegroundWindow` for processes that do not currently
/// own the foreground window, so the call can be refused even though it is
/// correct. [restore] and [show] are attempted first because a window that is
/// merely behind or minimised is the common case and those are always allowed.
Future<void> focusAppWindow() async {
  if (!canFocusAppWindow) return;
  try {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
  } catch (error) {
    // Common and harmless: the platform declined to steal focus.
    debugPrint('⚠️ [DesktopWindowFocus] could not focus window: $error');
  }
}
