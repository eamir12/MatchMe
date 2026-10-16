// Windows: MediaPipe gesture capture via WebView2 (webview_windows).
//
// Same live flow as mobile (webview_flutter): the shared
// assets/verification_capture/index.html page runs MediaPipe in-page with the
// device camera. webview_windows has no JS-channel API, so a shim injected
// via addScriptToExecuteOnDocumentCreated defines window.PhotoCapture /
// window.ValidationLog on top of chrome.webview.postMessage, and Dart routes
// the webMessage stream. Camera/media permission requests are auto-granted
// (native camera permission is checked first, same as Android).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:matchme/widgets/voice_guidance_mute_button.dart';

/// JS injected before document parsing. Defines the same host bindings the
/// capture page expects on mobile (window.PhotoCapture / window.ValidationLog)
/// and forwards them through WebView2's chrome.webview.postMessage as
/// {channel, message} JSON. Also covers CaptchaBridge for reuse.
const String _windowsWebViewBridgeShim = '''
(function(){
  function postToHost(channel, message){
    try{
      if(window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage==='function'){
        window.chrome.webview.postMessage(JSON.stringify({channel:channel,message:String(message)}));
      }
    }catch(_){}
  }
  try{ window.PhotoCapture={postMessage:function(m){postToHost('PhotoCapture',m);}};}catch(_){}
  try{ window.ValidationLog={postMessage:function(m){postToHost('ValidationLog',m);}};}catch(_){}
  try{ window.CaptchaBridge={postMessage:function(m){postToHost('CaptchaBridge',m);}};}catch(_){}
})();
''';

/// Opens the MediaPipe gesture capture page in a full-screen WebView2.
/// Same contract as the mobile implementation: [onPhoto] receives JPEG bytes.
void openWindowsMediaPipeVerificationCapture({
  required String gestureCode,
  required void Function(Uint8List?) onPhoto,
  String? gestureLabel,
  String? gestureDescription,
  String? localeCode,
  Map<String, String>? captureStrings,
  Uint8List? inputImageBytes,
  BuildContext? context,
  void Function()? onClose,
}) {
  final ctx = context;
  if (ctx == null || !ctx.mounted) {
    onPhoto(null);
    return;
  }
  Navigator.of(ctx)
      .push<void>(
        MaterialPageRoute<void>(
          builder: (context) => _WindowsMediaPipeCapturePage(
            gestureCode: gestureCode,
            gestureLabel: gestureLabel,
            gestureDescription: gestureDescription,
            localeCode: localeCode,
            captureStrings: captureStrings,
            inputImageBytes: inputImageBytes,
            onPhoto: onPhoto,
            onClose: onClose,
          ),
        ),
      )
      .then((_) {});
}

class _WindowsMediaPipeCapturePage extends ConsumerStatefulWidget {
  const _WindowsMediaPipeCapturePage({
    required this.gestureCode,
    required this.gestureLabel,
    required this.gestureDescription,
    required this.localeCode,
    required this.captureStrings,
    required this.inputImageBytes,
    required this.onPhoto,
    this.onClose,
  });

  final String gestureCode;
  final String? gestureLabel;
  final String? gestureDescription;
  final String? localeCode;
  final Map<String, String>? captureStrings;
  final Uint8List? inputImageBytes;
  final void Function(Uint8List?) onPhoto;
  final void Function()? onClose;

  @override
  ConsumerState<_WindowsMediaPipeCapturePage> createState() =>
      _WindowsMediaPipeCapturePageState();
}

class _WindowsMediaPipeCapturePageState
    extends ConsumerState<_WindowsMediaPipeCapturePage> {
  bool _sent = false;
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription> _subscriptions = [];
  String? _loadError;
  bool _cameraPermissionDenied = false;
  bool _ready = false;
  bool _webview2Missing = false;
  DateTime? _pageOpenedAt;

  int _elapsedPageMs() {
    final opened = _pageOpenedAt;
    if (opened == null) return -1;
    return DateTime.now().difference(opened).inMilliseconds;
  }

  /// Bottom system-bar inset in logical px, measured by Flutter (ground truth
  /// for the in-page card: 0 when the view already ends above opaque bars).
  double? _bottomInsetPx() {
    try {
      return MediaQuery.paddingOf(context).bottom;
    } catch (_) {
      return null;
    }
  }

  bool _isWaitingForSpeech = false;

  /// Primary-selfie (FACE_ONLY) instruction gate: the capture page holds
  /// auto-capture until the spoken instructions finish. The readiness signal
  /// must be acknowledged by the page (it can be dropped while the page is
  /// still loading); retried until then, with a page-side 20s fallback.
  bool _faceOnlyInstructionsSignaled = false;
  bool _faceOnlyInstructionsSpoken = false;
  int _faceOnlySignalAttempts = 0;

  bool get _isFaceOnlyCapture => widget.gestureCode == 'FACE_ONLY';

  Future<void> _speakPrimarySelfieInstructionsAndSignalReady() async {
    if (!_isFaceOnlyCapture) return;
    final label = (widget.gestureLabel ?? '').trim();
    final description = (widget.gestureDescription ?? '').trim();
    final fallbackInstruction =
        widget.captureStrings?['verificationCaptureInstruction'] ?? '';
    final text = [label, description]
        .where((s) => s.isNotEmpty)
        .join('. ');
    final toSpeak = text.isNotEmpty ? text : fallbackInstruction.trim();
    try {
      if (toSpeak.isNotEmpty) {
        await VoiceGuidanceService.instance
            .speakAndWait(toSpeak, timeout: const Duration(seconds: 30));
      }
    } catch (_) {}
    _faceOnlyInstructionsSpoken = true;
    await _signalFaceOnlyReadyToPage();
  }

  Future<void> _signalFaceOnlyReadyToPage() async {
    if (_faceOnlyInstructionsSignaled) return;
    if (!_ready) return;
    // Probe for the function: before the page's module script executes,
    // window.setFaceOnlyInstructionsReady is undefined and the call would
    // be silently dropped, blocking auto-capture forever. Retry until the
    // page answers (the page also lifts the gate itself after 20s).
    const probe =
        '(typeof window.setFaceOnlyInstructionsReady === "function" ? '
        '(window.setFaceOnlyInstructionsReady(), "ok") : "pending")';
    var result = '';
    try {
      final res = await _controller.executeScript(probe);
      result = res?.toString() ?? '';
    } catch (_) {
      result = '';
    }
    if (result.contains('ok')) {
      _faceOnlyInstructionsSignaled = true;
      return;
    }
    _faceOnlySignalAttempts++;
    if (_faceOnlySignalAttempts > 120 || !mounted) return;
    Timer(const Duration(milliseconds: 500), () {
      if (!_faceOnlyInstructionsSignaled) {
        unawaited(_signalFaceOnlyReadyToPage());
      }
    });
  }

  Future<void> _onPhotoReceived(Uint8List? bytes) async {
    if (_sent || _isWaitingForSpeech) return;

    if (bytes == null) {
      _sent = true;
      if (mounted) {
        Navigator.of(context).pop();
      }
      widget.onPhoto(null);
      return;
    }

    _isWaitingForSpeech = true;

    // Only advance automatically once the image is captured and the current
    // explanation sentence has finished being spoken. If explanations are
    // muted or guidance is disabled, this completes immediately.
    if (VoiceGuidanceService.instance.isSpeaking) {
      await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished();
    }

    if (!mounted || _sent) return;
    _sent = true;

    print(
      'WebView2 photo decoded: ${bytes.length} bytes after ${_elapsedPageMs()}ms page-open',
    );
    if (mounted) {
      Navigator.of(context).pop();
    }
    widget.onPhoto(bytes);
  }

  void _onLogMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type']?.toString() ?? 'log';
        if (type == 'voice') {
          // If a photo was captured and we are waiting for the current sentence
          // to finish, ignore any further coaching lines.
          if (_isWaitingForSpeech || _sent) return;

          final data = decoded['data'];
          final key = data is Map ? data['key']?.toString() : null;
          if (key != null && key.isNotEmpty) {
            final paramsRaw = data is Map ? data['params'] : null;
            final params = paramsRaw is Map
                ? paramsRaw.map((k, v) => MapEntry(k.toString(), v.toString()))
                : null;
            unawaited(
              VoiceGuidanceService.instance.speakKey(key, params: params),
            );
          } else {
            // Free-form shown text (checklist labels, fatal error card):
            // spoken after whatever is currently in progress instead of
            // interrupting it, so it can never be dropped by the rate limit.
            final text = data is Map ? data['text']?.toString() : null;
            if (text != null && text.trim().isNotEmpty) {
              unawaited(
                VoiceGuidanceService.instance.speakTextAfterCurrent(text),
              );
            }
          }
          return;
        }
        // captureTiming/ready/metrics always print: they are the timing
        // telemetry used to diagnose slow captures.
        if (type == 'error' ||
            type == 'stuck' ||
            type == 'captureTiming' ||
            type == 'ready' ||
            type == 'metrics') {
          debugPrint('VERIFICATION CAPTURE [$type]: $raw');
        } else if (kDebugMode) {
          debugPrint('VERIFICATION CAPTURE [$type]: $raw');
        }
        return;
      }
    } catch (_) {}
    debugPrint('VERIFICATION CAPTURE [log]: $raw');
  }

  void _onWebMessage(dynamic message) {
    // webview_windows delivers the string passed to chrome.webview.postMessage.
    if (message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        final channel = decoded['channel']?.toString();
        final payload = decoded['message']?.toString() ?? '';
        if (channel == 'PhotoCapture') {
          print(
            'WebView2 PhotoCapture bridge message after ${_elapsedPageMs()}ms page-open, payloadLen=${payload.length}',
          );
          try {
            final bytes = Uint8List.fromList(base64Decode(payload));
            print('Received photo from WebView2, length: ${bytes.length}');
            _onPhotoReceived(bytes);
          } catch (e) {
            print('Error decoding photo from WebView2: $e');
            _onPhotoReceived(null);
          }
          return;
        }
        if (channel == 'ValidationLog') {
          _onLogMessage(payload);
          return;
        }
      }
    } catch (_) {
      // Not a bridge envelope; ignore.
    }
  }

  Future<WebviewPermissionDecision> _onPermissionRequested(
    String url,
    WebviewPermissionKind kind,
    bool isUserInitiated,
  ) async {
    // Mirror Android behaviour: the host screen was opened via user gesture
    // and native camera permission was checked first, so grant media.
    print('Granting WebView2 permission request: $kind for $url');
    return WebviewPermissionDecision.allow;
  }

  Future<void> _pickFileFallback() async {
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) {
        _onPhotoReceived(null);
        return;
      }
      final bytes = await file.readAsBytes();
      _onPhotoReceived(bytes);
    } catch (e) {
      print('Verification capture file fallback failed: $e');
      _onPhotoReceived(null);
    }
  }

  Future<void> _initController() async {
    // Start loading the HTML immediately so it overlaps the version and
    // permission checks below instead of running after them.
    final htmlFuture = rootBundle.loadString(
      'assets/verification_capture/index.html',
    );
    // WebView2 runtime must be present (preinstalled on Win11, evergreen
    // installer on Win10).
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        print('WebView2 runtime not found');
        if (mounted) {
          setState(() => _webview2Missing = true);
        }
        return;
      }
      print('WebView2 version: $version');
    } catch (e) {
      print('WebView2 version check failed: $e');
      if (mounted) {
        setState(() => _webview2Missing = true);
      }
      return;
    }

    // Native camera permission first (same gate as Android).
    try {
      var cameraStatus = await Permission.camera.status;
      print('Camera permission status: $cameraStatus');
      if (!cameraStatus.isGranted && !cameraStatus.isLimited) {
        if (!cameraStatus.isPermanentlyDenied &&
            !cameraStatus.isRestricted) {
          cameraStatus = await Permission.camera.request();
          print('After request, camera status: $cameraStatus');
        }
      }
      if (!cameraStatus.isGranted && !cameraStatus.isLimited) {
        final l10n = ref.read(localizationProvider);
        if (mounted) {
          setState(() {
            _cameraPermissionDenied = true;
            _loadError = l10n.getString(
              'verificationCaptureCameraPermissionDenied',
            );
          });
        }
        print('Camera permission denied, showing error UI');
        return;
      }
    } catch (e) {
      // permission_handler_windows may not implement camera status; let the
      // WebView2 permission handler decide instead of blocking.
      print('Camera permission check skipped on Windows: $e');
    }

    print('Loading WebView2...');
    try {
      final html = await htmlFuture;
      print('Loaded HTML successfully, length: ${html.length}');

      final htmlWithParams = html
          .replaceFirst('__GESTURE_CODE_JSON__', jsonEncode(widget.gestureCode))
          .replaceFirst(
            '__GESTURE_LABEL_JSON__',
            jsonEncode(widget.gestureLabel ?? ''),
          )
          .replaceFirst(
            '__GESTURE_DESCRIPTION_JSON__',
            jsonEncode(widget.gestureDescription ?? ''),
          )
          .replaceFirst(
            '__LOCALE_CODE_JSON__',
            jsonEncode(widget.localeCode ?? 'en'),
          )
          .replaceFirst(
            '__CAPTURE_STRINGS_JSON__',
            jsonEncode(widget.captureStrings ?? <String, String>{}),
          )
          .replaceFirst(
            '__INPUT_IMAGE_BASE64_JSON__',
            jsonEncode(
              widget.inputImageBytes == null
                  ? ''
                  : base64Encode(widget.inputImageBytes!),
            ),
          )
          // Never show the in-page debug overlay (fps/scores) on Windows,
          // not even in debug builds. Release builds never show it on any
          // platform (kDebugMode is false there); diagnostics still reach
          // Dart logs via the ValidationLog bridge.
          .replaceFirst('__CAPTURE_DEBUG_JSON__', 'false')
          .replaceFirst(
            '__BOTTOM_INSET_JSON__',
            jsonEncode(_bottomInsetPx()),
          );
      print('HTML with params prepared');

      if (!mounted) return;

      // Secure context: getUserMedia requires an https origin.
      // loadStringContent uses about:blank (opaque origin) where
      // navigator.mediaDevices is undefined. Serve the page through a
      // virtual host mapping instead, mirroring mobile's
      // baseUrl: 'https://cdn.jsdelivr.net/'.
      final captureDir = Directory(
        '${Directory.systemTemp.path}/matchme_mediapipe',
      );
      await captureDir.create(recursive: true);
      final captureFile = File('${captureDir.path}/index.html');
      await captureFile.writeAsString(htmlWithParams, flush: true);

      await _controller.initialize();
      _subscriptions.add(_controller.webMessage.listen(_onWebMessage));
      await _controller.addScriptToExecuteOnDocumentCreated(
        _windowsWebViewBridgeShim,
      );
      await _controller.addVirtualHostNameMapping(
        'matchme-capture.local',
        captureDir.path,
        WebviewHostResourceAccessKind.allow,
      );
      await _controller.loadUrl('https://matchme-capture.local/index.html');
      print('WebView2 controller created');

      if (!mounted) return;
      setState(() => _ready = true);
      print('WebView2 controller set in state');
      // If the instructions already finished speaking while the WebView2
      // page was loading, lift the auto-capture gate now.
      if (_isFaceOnlyCapture && _faceOnlyInstructionsSpoken) {
        unawaited(_signalFaceOnlyReadyToPage());
      }
    } catch (e) {
      print('Error initializing WebView2 controller: $e');
      if (mounted) {
        setState(() => _loadError = e.toString());
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    try {
      _controller.dispose();
    } catch (_) {}
    if (!_sent) {
      // Backed out: silence any guidance still speaking so it does not follow
      // the user back to the verification screen (or beyond).
      unawaited(VoiceGuidanceService.instance.stop());
      try {
        widget.onClose?.call();
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _pageOpenedAt = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // No artificial delay: the 500ms wait in the mobile page works around
      // an Android platform-view race that does not exist for WebView2.
      // First run still downloads the MediaPipe models (~10s, HTTP-cached
      // afterwards); the page shows its loading status meanwhile.
      if (!mounted) return;
      // Primary selfie: speak the instructions now (while models load) so
      // the user hears what to do; the page holds auto-capture until
      // speaking finishes. A fallback timer guarantees the gate lifts even
      // if TTS never completes.
      if (_isFaceOnlyCapture) {
        unawaited(_speakPrimarySelfieInstructionsAndSignalReady());
        Timer(const Duration(seconds: 12), () {
          if (mounted) unawaited(_signalFaceOnlyReadyToPage());
        });
      }
      await _initController().catchError((e) {
        if (mounted) setState(() => _loadError = e.toString());
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    if (_webview2Missing) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: ShrinkText(l10n.getString('verification'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n
                      .getString('verificationCaptureWrapperFailedToLoad')
                      .replaceAll('{error}', 'WebView2 runtime not installed'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _pickFileFallback,
                  child: Text(l10n.getString('takePhoto')),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: ShrinkText(l10n.getString('verification'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n
                  .getString('verificationCaptureWrapperFailedToLoad')
                  .replaceAll('{error}', _loadError ?? ''),
            ),
          ),
        ),
        bottomNavigationBar: _cameraPermissionDenied
            ? SafeArea(
                minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: FilledButton(
                  onPressed: () async {
                    await openAppSettings();
                  },
                  child: Text(l10n.getString('permActionOpenSettings')),
                ),
              )
            : null,
      );
    }
    if (!_ready) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: ShrinkText(l10n.getString('verification')),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Webview(
              _controller,
              permissionRequested: _onPermissionRequested,
            ),
          ),
          // Back button so the user can leave and do verification later.
          // Popping without a photo triggers onClose via dispose().
          // Directional: sits on the leading edge (right in RTL/Hebrew).
          Positioned.directional(
            textDirection: Directionality.of(context),
            top: 0,
            start: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ),
          // Mute/unmute for the spoken instructions while the camera is live.
          // Trailing edge keeps it clear of the back button in both LTR/RTL.
          Positioned.directional(
            textDirection: Directionality.of(context),
            top: 0,
            end: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: const VoiceGuidanceMuteButton(
                    iconColor: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
