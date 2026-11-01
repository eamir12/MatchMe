// web_imports_web.dart - Web platform implementation of the browser bridge.
//
// The shared, platform-neutral surface lives in web_imports_contract.dart.
// This file overrides only the members that genuinely need a DOM, and keeps
// all `dart:js_interop` usage private to itself. Callers keep passing plain
// Dart closures and reading plain Dart values; previously they had to reach
// through `(html.window as dynamic).navigator...`.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'package:matchme/providers/locale_provider.dart';
import 'web_imports_contract.dart';

// The data types and inert defaults are consumed directly by callers as
// `html.WebGeolocationPosition`, `html.WebGeolocationOptions` and so on, so
// this branch has to re-export the contract exactly as the stub does.
//
// `flutter analyze` will NOT catch a missing export here: on the host it
// resolves the conditional export to web_imports_stub.dart, which does export
// them. Only `flutter build web` sees this branch. Keep the two exports
// identical.
export 'web_imports_contract.dart';

/// Memoises one `JSFunction` per Dart listener.
///
/// The DOM removes a listener only when the callback reference is *identical*,
/// so each Dart listener is wrapped exactly once. Producing a fresh
/// `JSFunction` per call would make every `removeEventListener` a silent no-op
/// and leak the listener for the lifetime of the page.
///
/// The wrapper deliberately does *not* catch: a throwing listener should reach
/// the browser's error handler and the console exactly as it did when this
/// shim re-exported `dart:html` and passed Dart closures straight through. The
/// DOM already isolates dispatch, so one bad listener cannot starve the rest.
class _ListenerRegistry {
  final Map<Function, JSFunction> _wrappers = {};

  JSFunction wrapFor(Function listener) => _wrappers.putIfAbsent(
    listener,
    () => ((web.Event event) {
      listener(_wrapEvent(event));
    }).toJS,
  );

  JSFunction? lookup(Function listener) => _wrappers[listener];
}

/// Shared by [HtmlDocument] and [Window]: the wrapper is target-agnostic, so
/// the same Dart listener registered on two targets still maps to one function.
final _listenerRegistry = _ListenerRegistry();

class _WebEvent extends Event {
  _WebEvent(this.raw);

  /// The DOM event behind this wrapper. Safe to expose: `_WebEvent` is
  /// private, so this is not part of the bridge's public surface and callers
  /// still only ever see the neutral [Event].
  final web.Event raw;

  @override
  String get type => raw.type;

  @override
  void preventDefault() => raw.preventDefault();
}

class _WebKeyboardEvent extends _WebEvent implements KeyboardEvent {
  _WebKeyboardEvent(super.raw);

  @override
  String get key => (raw as web.KeyboardEvent).key;
}

/// Wraps a DOM event so listeners receive the platform-neutral [Event].
///
/// Keyboard events are promoted to [KeyboardEvent] so [KeyboardEvent.key] is
/// actually readable, matching the documented surface. `isA` is required here:
/// `is` on a JS interop type cannot see through to the underlying JS object.
Event _wrapEvent(web.Event event) => event.isA<web.KeyboardEvent>()
    ? _WebKeyboardEvent(event as web.KeyboardEvent)
    : _WebEvent(event);

class _WebLocation extends Location {
  @override
  String get href => web.window.location.href;

  @override
  void reload() => web.window.location.reload();
}

class _WebHistory extends History {
  @override
  void replaceState(String title, String? url) {
    web.window.history.replaceState(null, title, url);
  }
}

class _WebDocument extends HtmlDocument {
  @override
  bool get hidden => web.document.hidden;

  @override
  String get visibilityState => web.document.visibilityState;

  @override
  void addEventListener(String type, Function? listener) {
    if (listener == null) return;
    web.document.addEventListener(type, _listenerRegistry.wrapFor(listener));
  }

  @override
  void removeEventListener(String type, Function? listener) {
    if (listener == null) return;
    final callback = _listenerRegistry.lookup(listener);
    if (callback == null) return;
    web.document.removeEventListener(type, callback);
  }
}

class _WebGeolocation extends WebGeolocation {
  @override
  void getCurrentPosition(
    WebPositionCallback onSuccess, [
    WebPositionErrorCallback? onError,
    WebGeolocationOptions? options,
  ]) {
    web.window.navigator.geolocation.getCurrentPosition(
      _jsPositionCallback(onSuccess),
      onError == null ? null : _jsPositionErrorCallback(onError),
      _jsPositionOptions(options),
    );
  }

  @override
  int watchPosition(
    WebPositionCallback onSuccess, [
    WebPositionErrorCallback? onError,
    WebGeolocationOptions? options,
  ]) {
    return web.window.navigator.geolocation.watchPosition(
      _jsPositionCallback(onSuccess),
      onError == null ? null : _jsPositionErrorCallback(onError),
      _jsPositionOptions(options),
    );
  }

  @override
  void clearWatch(int watchId) {
    web.window.navigator.geolocation.clearWatch(watchId);
  }

  static web.PositionOptions _jsPositionOptions(
    WebGeolocationOptions? options,
  ) => web.PositionOptions(
    enableHighAccuracy: options?.enableHighAccuracy ?? false,
    timeout: options?.timeout ?? 30000,
    maximumAge: options?.maximumAge ?? 0,
  );

  static web.PositionCallback _jsPositionCallback(
    WebPositionCallback callback,
  ) => ((web.GeolocationPosition position) {
    final c = position.coords;
    callback(
      WebGeolocationPosition(
        coords: WebGeolocationCoordinates(
          latitude: c.latitude,
          longitude: c.longitude,
          accuracy: c.accuracy,
          altitude: c.altitude,
          altitudeAccuracy: c.altitudeAccuracy,
          heading: c.heading,
          speed: c.speed,
        ),
        timestamp: position.timestamp,
      ),
    );
  }).toJS;

  static web.PositionErrorCallback _jsPositionErrorCallback(
    WebPositionErrorCallback callback,
  ) => ((web.GeolocationPositionError error) {
    callback(error.code, error.message);
  }).toJS;
}

class _WebPermissions extends WebPermissions {
  @override
  Future<String> queryState(String name) async {
    final descriptor = JSObject();
    descriptor.setProperty('name'.toJS, name.toJS);
    final status = await web.window.navigator.permissions
        .query(descriptor)
        .toDart;
    return status.state;
  }
}

class _WebNavigator extends WebNavigator {
  @override
  WebGeolocation get geolocation => _WebGeolocation();

  @override
  WebPermissions get permissions => _WebPermissions();

  @override
  bool sendBeacon(String url, Uint8List data) {
    return web.window.navigator.sendBeacon(url, data.toJS);
  }
}

class _WebWindow extends Window {
  @override
  Location get location => _WebLocation();

  @override
  History get history => _WebHistory();

  @override
  Object? get opener => web.window.opener;

  @override
  void close() => web.window.close();

  @override
  WebNavigator get navigator => _WebNavigator();

  @override
  void addEventListener(String type, Function? listener) {
    if (listener == null) return;
    web.window.addEventListener(type, _listenerRegistry.wrapFor(listener));
  }

  @override
  void removeEventListener(String type, Function? listener) {
    if (listener == null) return;
    final callback = _listenerRegistry.lookup(listener);
    if (callback == null) return;
    web.window.removeEventListener(type, callback);
  }
}

final HtmlDocument document = _WebDocument();
final Window window = _WebWindow();

/// Send an authenticated keepalive request during page unload.
///
/// `navigator.sendBeacon` cannot attach an Authorization header, so the RPC
/// would run as `anon` and be rejected now that presence updates require a
/// user JWT. `fetch(..., keepalive: true)` survives the unload and carries
/// the same headers as a normal PostgREST call.
bool sendAuthenticatedOfflineBeacon(
  String url,
  String data,
  String accessToken,
  String anonKey,
) {
  try {
    final headers = web.Headers();
    headers.set('apikey', anonKey);
    headers.set('Authorization', 'Bearer $accessToken');
    headers.set('Content-Type', 'application/json');
    final init = web.RequestInit(
      method: 'POST',
      headers: headers,
      body: data.toJS,
      keepalive: true,
    );
    unawaited(
      web.window
          .fetch(url.toJS, init)
          .toDart
          .then<void>((_) {}, onError: (_) {}),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// Safe vibration for web platform.
void safeVibrate(Object pattern) {
  try {
    if (pattern is int) {
      web.window.navigator.vibrate(pattern.toJS);
      return;
    }
    if (pattern is List<int>) {
      final jsPattern = pattern.map((v) => v.toJS).toList().toJS;
      web.window.navigator.vibrate(jsPattern);
      return;
    }
    web.window.navigator.vibrate(20.toJS);
  } catch (_) {
    // Silently fail if vibration is not supported.
  }
}

/// Reads [reader]'s result once the current read has finished.
Future<Uint8List?> _readBytes(web.FileReader reader) async {
  final completer = Completer<Uint8List?>();
  final subscriptions = <StreamSubscription<web.Event>>[];

  void complete(Uint8List? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  subscriptions.add(
    web.EventStreamProviders.loadEvent
        .forTarget(reader)
        .listen((_) => complete(_asBytes(reader))),
  );
  subscriptions.add(
    web.EventStreamProviders.errorEvent
        .forTarget(reader)
        .listen((_) => complete(null)),
  );

  try {
    return await completer.future;
  } finally {
    for (final sub in subscriptions) {
      unawaited(sub.cancel());
    }
  }
}

/// `FileReader.result` after `readAsArrayBuffer` is a `JSArrayBuffer`.
Uint8List? _asBytes(web.FileReader reader) {
  final result = reader.result;
  if (result == null) return null;
  if (result.isA<JSArrayBuffer>()) {
    return (result as JSArrayBuffer).toDart.asUint8List();
  }
  return null;
}

/// Web-specific implementation of camera functionality.
Future<Uint8List?> pickImageBytesFromCamera({
  String capture = 'user',
  String? captureButtonText,
  String? cancelButtonText,
  bool allowFileFallback = true,
  void Function(String error)? onError,
}) async {
  try {
    // Use getUserMedia API to access camera directly.
    // package:web models every constraint member as a bare `JSAny`, so the
    // `{ideal: n}` plain-object shorthand has to be assembled by hand.
    final width = JSObject()..setProperty('ideal'.toJS, 1920.toJS);
    final height = JSObject()..setProperty('ideal'.toJS, 1080.toJS);
    final videoConstraints = JSObject()
      ..setProperty('facingMode'.toJS, capture.toJS)
      ..setProperty('width'.toJS, width)
      ..setProperty('height'.toJS, height);

    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(video: videoConstraints))
        .toDart;

    // Create overlay container for camera preview
    final overlay = web.HTMLDivElement()
      ..style.position = 'fixed'
      ..style.top = '0'
      ..style.left = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = 'rgba(0, 0, 0, 0.8)'
      ..style.display = 'flex'
      ..style.flexDirection = 'column'
      ..style.alignItems = 'center'
      ..style.justifyContent = 'center'
      ..style.zIndex = '999999';

    // Create video element for camera preview
    final video = web.HTMLVideoElement()
      ..srcObject = stream
      ..autoplay = true
      ..controls = false
      ..muted = true
      ..style.maxWidth = '90%'
      ..style.maxHeight = '70%'
      ..style.borderRadius = '8px';

    // Create capture button
    final resolvedCaptureButtonText =
        captureButtonText ??
        LocalizationState.defaultTranslation('cameraCapturePhoto');
    final captureButton = web.HTMLButtonElement()
      ..textContent = resolvedCaptureButtonText
      ..style.padding = '16px 32px'
      ..style.fontSize = '18px'
      ..style.backgroundColor = '#007AFF'
      ..style.color = 'white'
      ..style.border = 'none'
      ..style.borderRadius = '8px'
      ..style.marginTop = '20px'
      ..style.cursor = 'pointer';

    // Create cancel button
    final resolvedCancelButtonText =
        cancelButtonText ??
        LocalizationState.defaultTranslation('commonCancel');
    final cancelButton = web.HTMLButtonElement()
      ..textContent = resolvedCancelButtonText
      ..style.padding = '16px 32px'
      ..style.fontSize = '18px'
      ..style.backgroundColor = '#666'
      ..style.color = 'white'
      ..style.border = 'none'
      ..style.borderRadius = '8px'
      ..style.marginTop = '10px'
      ..style.cursor = 'pointer';

    // Add elements to overlay
    overlay.append(video);
    overlay.append(captureButton);
    overlay.append(cancelButton);

    // Add overlay to document
    web.document.body?.append(overlay);

    // Wait for video to be ready
    await web.EventStreamProviders.loadedMetadataEvent.forTarget(video).first;

    // Create a completer to wait for user action
    final actionCompleter = Completer<String>();
    final clickSubscriptions = <StreamSubscription<web.Event>>[];

    void resolveAction(String action) {
      if (!actionCompleter.isCompleted) actionCompleter.complete(action);
    }

    clickSubscriptions.add(
      web.EventStreamProviders.clickEvent
          .forTarget(captureButton)
          .listen((_) => resolveAction('capture')),
    );
    clickSubscriptions.add(
      web.EventStreamProviders.clickEvent
          .forTarget(cancelButton)
          .listen((_) => resolveAction('cancel')),
    );

    // Wait for user action
    final action = await actionCompleter.future;
    for (final sub in clickSubscriptions) {
      unawaited(sub.cancel());
    }

    Uint8List? result;
    if (action == 'capture') {
      try {
        // Create canvas to capture frame
        final canvas = web.HTMLCanvasElement()
          ..width = video.videoWidth
          ..height = video.videoHeight;
        final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
        ctx.drawImage(video, 0, 0);

        // Convert to blob and then to bytes
        final blobCompleter = Completer<web.Blob?>();
        canvas.toBlob(
          ((web.Blob? blob) {
            if (!blobCompleter.isCompleted) blobCompleter.complete(blob);
          }).toJS,
          'image/jpeg',
          0.9.toJS,
        );
        final blob = await blobCompleter.future;
        if (blob == null) {
          onError?.call('failed');
          result = null;
        } else {
          final reader = web.FileReader();
          final pending = _readBytes(reader);
          reader.readAsArrayBuffer(blob);
          result = await pending;
        }
      } catch (_) {
        onError?.call('failed');
        result = null;
      }
    }

    // Cleanup
    final tracks = stream.getTracks();
    for (var i = 0; i < tracks.length; i++) {
      tracks[i].stop();
    }
    overlay.remove();

    return result;
  } catch (error) {
    final message = error.toString().toLowerCase();
    onError?.call(
      message.contains('notallowed') || message.contains('permission')
          ? 'denied'
          : 'unavailable',
    );
    if (!allowFileFallback) return null;
    return _pickImageBytesFromFileInput(capture);
  }
}

/// File-picker fallback used when `getUserMedia` is unavailable or denied.
Future<Uint8List?> _pickImageBytesFromFileInput(String capture) async {
  try {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = 'image/*'
      ..multiple = false;
    input.setAttribute('capture', capture);

    final completer = Completer<Uint8List?>();
    late final StreamSubscription<web.Event> sub;

    sub = web.EventStreamProviders.changeEvent.forTarget(input).listen((
      _,
    ) async {
      unawaited(sub.cancel());

      final file = input.files?.item(0);
      if (file == null) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }

      try {
        final reader = web.FileReader();
        final pending = _readBytes(reader);
        reader.readAsArrayBuffer(file);
        if (!completer.isCompleted) completer.complete(await pending);
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    input.click();

    return await completer.future;
  } catch (_) {
    return null;
  }
}
