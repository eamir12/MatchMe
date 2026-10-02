// lib/utils/desktop_window_focus.dart
//
// Barrel: raise the app's own window after a system-browser OAuth round trip.
// Resolves to the dart:io implementation on mobile/desktop and to a no-op on
// web, where the browser tab *is* the app.
export 'desktop_window_focus_stub.dart'
    if (dart.library.io) 'desktop_window_focus_io.dart';
