// Platform-neutral base for the browser bridge in lib/web_imports.dart.
//
// `web_imports.dart` picks one of two implementations with a conditional
// export, and `flutter analyze` resolves that export for only ONE platform.
// Without help, a member added to web_imports_web.dart but not
// web_imports_stub.dart analyses clean, tests clean, and builds clean on
// whichever platform you happen to build - then fails at runtime on the other.
//
// This file removes the mirroring instead of testing for it. Everything that
// can be expressed in plain Dart is written ONCE here, with inert defaults,
// and web_imports_stub.dart simply re-exports it. Only the DOM-facing members
// are overridden in web_imports_web.dart, so the shared surface cannot drift.
//
// Two things are deliberately NOT enforced here:
//
//   * Constructors. A web class must be handed the real DOM object, which has
//     no non-web equivalent, so `Event(web.Event)` cannot match `Event()`.
//     Nothing constructs these types; they only ever arrive as listener
//     arguments.
//   * Extra public members added to web_imports_web.dart. Keep new surface
//     here first, then override it in the web file. That way a consumer can
//     never reach a member that the stub lacks.
//
// This file must never import dart:html, dart:js_interop, dart:js_util,
// dart:ui_web or package:web - it is compiled for every target.

import 'dart:typed_data';

/// A DOM event as delivered to a listener.
///
/// Off the web this carries no data, so listeners that ignore the argument -
/// which is all of them - behave identically on both platforms.
class Event {
  String get type => '';

  void preventDefault() {}
}

/// A keyboard event. Provided for API parity with the non-web stub.
class KeyboardEvent extends Event {
  String get key => '';
}

/// `window.location`, narrowed to the parts this app uses.
class Location {
  String get href => '';

  void reload() {}
}

/// `window.history`, narrowed to the parts this app uses.
class History {
  /// Replaces the current history entry, rewriting the URL in place.
  ///
  /// `history.state` is always `null` in this app: the only use is stripping
  /// auth query parameters after the redirect, so no state is worth keeping.
  void replaceState(String title, String? url) {}
}

/// `document`, reporting a permanently visible page.
class HtmlDocument {
  /// Whether the document is hidden from view.
  bool get hidden => false;

  /// One of `hidden`, `visible` or `prerender`.
  String get visibilityState => 'visible';

  void addEventListener(String type, Function? listener) {}

  void removeEventListener(String type, Function? listener) {}
}

/// Options for a geolocation read.
class WebGeolocationOptions {
  const WebGeolocationOptions({
    this.enableHighAccuracy = false,
    this.timeout,
    this.maximumAge = 0,
  });

  final bool enableHighAccuracy;

  /// Timeout in milliseconds. `null` lets the browser decide.
  final int? timeout;

  /// Maximum acceptable age of the cached position, in milliseconds.
  final int maximumAge;
}

/// The `coords` member of a geolocation reading.
class WebGeolocationCoordinates {
  const WebGeolocationCoordinates({
    this.latitude,
    this.longitude,
    this.accuracy,
    this.altitude,
    this.altitudeAccuracy,
    this.heading,
    this.headingAccuracy,
    this.speed,
    this.speedAccuracy,
  });

  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final double? altitude;
  final double? altitudeAccuracy;
  final double? heading;

  /// Always `null`: not exposed by `package:web` 1.x and never populated by
  /// `dart:html` either, so callers already fell back to their default.
  final double? headingAccuracy;

  final double? speed;

  /// Always `null`, for the same reason as [headingAccuracy].
  final double? speedAccuracy;
}

/// A single geolocation reading.
class WebGeolocationPosition {
  const WebGeolocationPosition({required this.coords, this.timestamp});

  final WebGeolocationCoordinates coords;

  /// Milliseconds since the Unix epoch, or `null` when unavailable.
  final int? timestamp;
}

typedef WebPositionCallback = void Function(WebGeolocationPosition position);

/// Receives a geolocation failure [code] (1 = permission denied,
/// 2 = unavailable, 3 = timeout) and a human-readable [message].
typedef WebPositionErrorCallback = void Function(int code, String message);

/// `navigator.geolocation`.
///
/// Callbacks are never invoked, so a caller that relies on a callback to
/// settle a `Completer` must already be guarded by a platform check (`kIsWeb`)
/// or a timeout - exactly as it was when this was a `null` navigator.
class WebGeolocation {
  void getCurrentPosition(
    WebPositionCallback onSuccess, [
    WebPositionErrorCallback? onError,
    WebGeolocationOptions? options,
  ]) {}

  int watchPosition(
    WebPositionCallback onSuccess, [
    WebPositionErrorCallback? onError,
    WebGeolocationOptions? options,
  ]) => -1;

  void clearWatch(int watchId) {}
}

/// `navigator.permissions`, unavailable off the web.
class WebPermissions {
  Future<String> queryState(String name) async => 'prompt';
}

/// `navigator`, unavailable off the web.
class WebNavigator {
  WebGeolocation get geolocation => WebGeolocation();

  WebPermissions get permissions => WebPermissions();

  bool sendBeacon(String url, Uint8List data) => false;
}

/// `window`, a permanently top-level, script-opened window.
class Window {
  Location get location => Location();

  History get history => History();

  /// The window that opened this one, or `null` when not script-opened.
  Object? get opener => null;

  void close() {}

  WebNavigator get navigator => WebNavigator();

  void addEventListener(String type, Function? listener) {}

  void removeEventListener(String type, Function? listener) {}
}

/// Authenticated keepalive delivery is unsupported off the web.
bool sendAuthenticatedOfflineBeacon(
  String url,
  String data,
  String accessToken,
  String anonKey,
) => false;

/// Vibration is a no-op off the web.
void safeVibrate(Object pattern) {}

/// No camera is available off the web.
///
/// [allowFileFallback] exists for strict camera flows (for example a selfie
/// that must not come from the gallery). [onError] receives `unavailable`,
/// `denied` or `failed`; a plain null result without an error means the user
/// canceled.
Future<Uint8List?> pickImageBytesFromCamera({
  String capture = 'user',
  String? captureButtonText,
  String? cancelButtonText,
  bool allowFileFallback = true,
  void Function(String error)? onError,
}) async => null;
