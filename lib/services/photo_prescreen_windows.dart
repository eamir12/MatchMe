// Windows on-device photo prescreen.
//
// Runs the shared MediaPipe still-image detector (web/photo_prescreen.js, the
// exact script the web build loads) in a headless WebView2 controller and
// returns the same map the mobile ML Kit / Vision MethodChannel analyzers
// produce, so PhotoPrescreenService applies identical rules on every platform.
//
// No Webview widget is involved: webview_windows creates the native
// controller and texture from WebviewController.initialize(), and JS results
// arrive on controller.webMessage. Everything is best-effort — any failure
// returns null so the caller falls back to server-side Gemini.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_windows/webview_windows.dart';

const String _virtualHost = 'matchme-prescreen.local';
const String _pageAsset = 'assets/photo_prescreen/index.html';
const String _scriptAsset = 'web/photo_prescreen.js';
const String _tempDirName = 'matchme_photo_prescreen';

/// First call pays for the MediaPipe model download (~10s, then HTTP-cached);
/// later calls are detection-only.
const Duration _startTimeout = Duration(seconds: 15);
const Duration _analyzeTimeout = Duration(seconds: 25);
const Duration _idleDispose = Duration(minutes: 2);

final _WindowsPhotoPrescreenHost _host = _WindowsPhotoPrescreenHost();

/// Runs the bundled face/body detector on [bytes]. Returns null when the
/// platform is not Windows or the runtime/page/models are unavailable.
Future<Map<String, Object?>?> analyzePhotoPrescreenWindows(Uint8List bytes) {
  if (!Platform.isWindows) return Future<Map<String, Object?>?>.value(null);
  return _host.analyze(bytes);
}

class _WindowsPhotoPrescreenHost {
  WebviewController? _controller;
  StreamSubscription<dynamic>? _messages;
  StreamSubscription<dynamic>? _loadErrorSub;
  Completer<void>? _readySignal;
  bool _ready = false;
  final Map<int, Completer<Map<String, Object?>?>> _pending = {};
  int _nextId = 1;
  Timer? _idleTimer;
  Future<void> _queue = Future<void>.value();

  Future<Map<String, Object?>?> analyze(Uint8List bytes) {
    // Detector calls are serialized: the MediaPipe instances are shared and
    // not safe to drive concurrently.
    final result = _queue.then((_) => _analyzeOnce(bytes));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, Object?>?> _analyzeOnce(Uint8List bytes) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    try {
      await _ensureStarted().timeout(_startTimeout);
      final id = _nextId++;
      final completer = Completer<Map<String, Object?>?>();
      _pending[id] = completer;
      try {
        await _controller!.postWebMessage(
          jsonEncode({
            'type': 'analyze',
            'id': id,
            'image': base64Encode(bytes),
          }),
        );
      } catch (_) {
        _pending.remove(id);
        rethrow;
      }
      // A timeout drops just this request: the page may still be downloading
      // models, and the next photo should reuse that work.
      return await completer.future.timeout(_analyzeTimeout);
    } catch (e) {
      debugPrint('[photoPrescreen] Windows detector unavailable: $e');
      await _disposeHost();
      return null;
    } finally {
      _scheduleIdleDispose();
    }
  }

  Future<void> _ensureStarted() {
    if (_ready && _controller != null) return Future<void>.value();
    return _start();
  }

  Future<void> _start() async {
    final version = await WebviewController.getWebViewVersion();
    if (version == null) throw StateError('WebView2 runtime missing');
    debugPrint('[photoPrescreen] WebView2 version=$version');

    final dir = Directory('${Directory.systemTemp.path}/$_tempDirName');
    await dir.create(recursive: true);
    final html = await rootBundle.loadString(_pageAsset);
    final script = await rootBundle.loadString(_scriptAsset);
    await File(
      '${dir.path}/index.html',
    ).writeAsString(html, flush: true);
    await File(
      '${dir.path}/photo_prescreen.js',
    ).writeAsString(script, flush: true);

    final controller = WebviewController();
    final readySignal = Completer<void>();
    _readySignal = readySignal;
    try {
      await controller.initialize();
      _controller = controller;
      _messages = controller.webMessage.listen(
        _onMessage,
        onError: (Object e) =>
            debugPrint('[photoPrescreen] webMessage error: $e'),
      );
      _loadErrorSub = controller.onLoadError.listen(
        (error) => debugPrint('[photoPrescreen] WebView2 load error: $error'),
      );
      // getUserMedia is not used, but the MediaPipe module import needs a
      // secure origin; about:blank is opaque, so serve through a virtual host.
      await controller.addVirtualHostNameMapping(
        _virtualHost,
        dir.path,
        WebviewHostResourceAccessKind.allow,
      );
      await controller.loadUrl('https://$_virtualHost/index.html');
      await readySignal.future;
      if (!identical(_controller, controller)) {
        throw StateError('host disposed during start');
      }
      _ready = true;
      _readySignal = null;
    } catch (_) {
      _readySignal = null;
      rethrow;
    }
  }

  void _onMessage(dynamic message) {
    // A page postMessage(string) arrives as a String: the plugin JSON-decodes
    // the outer WebView2 envelope but leaves the posted string intact.
    var payload = message;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } catch (_) {
        return;
      }
    }
    if (payload is! Map) return;
    final channel = payload['channel'];
    if (channel == 'PrescreenReady') {
      final signal = _readySignal;
      if (signal != null && !signal.isCompleted) signal.complete();
      return;
    }
    if (channel != 'PrescreenResult') return;
    final id = (payload['id'] as num?)?.toInt();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final raw = payload['result'];
    completer.complete(
      raw is Map ? Map<String, Object?>.from(raw) : null,
    );
  }

  void _scheduleIdleDispose() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleDispose, () {
      unawaited(_disposeHost());
    });
  }

  Future<void> _disposeHost() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _ready = false;
    final signal = _readySignal;
    _readySignal = null;
    if (signal != null && !signal.isCompleted) {
      // Wakes an in-flight _start; it then sees the disposed controller and
      // throws, which the analyze timeout already absorbs.
      signal.complete();
    }
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.complete(null);
    }
    _pending.clear();
    final messages = _messages;
    _messages = null;
    try {
      await messages?.cancel();
    } catch (_) {}
    final loadErrors = _loadErrorSub;
    _loadErrorSub = null;
    try {
      await loadErrors?.cancel();
    } catch (_) {}
    final controller = _controller;
    _controller = null;
    try {
      await controller?.dispose();
    } catch (_) {}
  }
}
