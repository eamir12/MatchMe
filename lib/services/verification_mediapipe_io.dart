// Mobile/desktop: MediaPipe gesture capture via WebView (same flow as web).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/verification_mediapipe_windows.dart'
    as windows_capture;
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// webview_flutter covers Android/iOS/macOS. Windows uses WebView2
/// (see verification_mediapipe_windows.dart) with the same live capture page.
/// Only Linux has no WebView and falls back to a file picker.
bool _isLiveCaptureSupported() {
  try {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  } catch (_) {
    return false;
  }
}

/// Linux fallback (no WebView available): let the user pick an existing photo.
/// The backend AI verification still checks the gesture.
Future<void> _pickPhotoFromFilesFallback(
  void Function(Uint8List?) onPhoto,
  void Function()? onClose,
) async {
  try {
    print(
      'Verification capture: WebView not supported on ${Platform.operatingSystem}, using file picker fallback',
    );
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) {
      onPhoto(null);
      onClose?.call();
      return;
    }
    final bytes = await file.readAsBytes();
    onPhoto(bytes);
  } catch (e) {
    print('Verification capture file fallback failed: $e');
    onPhoto(null);
    onClose?.call();
  }
}

/// Opens the MediaPipe gesture capture page in a full-screen WebView. When the user
/// captures a photo, [onPhoto] is called with the JPEG bytes. [context] is required
/// to push the WebView route.
void openMediaPipeVerificationCapture({
  required String gestureCode,
  required void Function(Uint8List?) onPhoto,
  String? gestureLabel,
  String? gestureDescription,
  String? localeCode,
  Map<String, String>? captureStrings,
  Uint8List? inputImageBytes,
  BuildContext? context,
  // Called when the capture route is closed without delivering a photo
  // (user backed out). Omit to keep the legacy fire-and-forget behaviour.
  void Function()? onClose,
}) {
  try {
    if (Platform.isWindows) {
      windows_capture.openWindowsMediaPipeVerificationCapture(
        gestureCode: gestureCode,
        onPhoto: onPhoto,
        gestureLabel: gestureLabel,
        gestureDescription: gestureDescription,
        localeCode: localeCode,
        captureStrings: captureStrings,
        inputImageBytes: inputImageBytes,
        context: context,
        onClose: onClose,
      );
      return;
    }
  } catch (_) {}
  if (!_isLiveCaptureSupported()) {
    unawaited(_pickPhotoFromFilesFallback(onPhoto, onClose));
    return;
  }
  final ctx = context;
  if (ctx == null || !ctx.mounted) {
    onPhoto(null);
    return;
  }

  Navigator.of(ctx)
      .push<void>(
        MaterialPageRoute<void>(
          builder: (context) => _MediaPipeCapturePage(
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
      .then((_) {
        // If route was popped without sending a photo, ensure we don't leave callback dangling
        // (onPhoto is only called when we receive base64 from the WebView)
      });
}

class _MediaPipeCapturePage extends ConsumerStatefulWidget {
  const _MediaPipeCapturePage({
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
  ConsumerState<_MediaPipeCapturePage> createState() =>
      _MediaPipeCapturePageState();
}

class _MediaPipeCapturePageState extends ConsumerState<_MediaPipeCapturePage> {
  bool _sent = false;
  WebViewController? _controller;
  String? _loadError;
  bool _cameraPermissionDenied = false;

  /// Bottom system-bar inset in logical px, measured by Flutter. Ground truth
  /// for the in-page card position: 0 when the WebView already ends above
  /// opaque bars (card hugs the bottom), bar height when underlapping.
  /// CSS env() can't know this and double-counts on resized WebViews.
  double? _bottomInsetPx() {
    try {
      return MediaQuery.paddingOf(context).bottom;
    } catch (_) {
      return null;
    }
  }

  bool _isWaitingForSpeech = false;

  /// Primary-selfie (FACE_ONLY) instruction gate: the capture page holds
  /// auto-capture until the spoken instructions finish. This flag tracks
  /// whether the host has finished speaking AND the page has acknowledged
  /// the readiness signal.
  bool _faceOnlyInstructionsSignaled = false;
  bool _faceOnlyInstructionsSpoken = false;
  int _faceOnlySignalAttempts = 0;

  bool get _isFaceOnlyCapture => widget.gestureCode == 'FACE_ONLY';

  /// Speaks the primary-selfie instructions aloud, then lifts the page's
  /// auto-capture gate. Falls back to signalling after a timeout so a TTS
  /// failure can never block capture forever.
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
    final controller = _controller;
    if (controller == null) {
      // WebView not ready yet — retried once it is (called again after
      // _initController sets the controller).
      return;
    }
    // The page may still be loading (module script not yet executed), in
    // which case window.setFaceOnlyInstructionsReady is undefined and the
    // call is silently dropped — which used to block auto-capture forever.
    // Probe for the function and only stop retrying once the page answers.
    const probe =
        '(typeof window.setFaceOnlyInstructionsReady === "function" ? '
        '(window.setFaceOnlyInstructionsReady(), "ok") : "pending")';
    var result = '';
    try {
      final res = await controller.runJavaScriptReturningResult(probe);
      result = res.toString();
    } catch (_) {
      result = '';
    }
    if (result.contains('ok')) {
      _faceOnlyInstructionsSignaled = true;
      return;
    }
    _faceOnlySignalAttempts++;
    if (_faceOnlySignalAttempts > 120) {
      // ~60s of retries is plenty; the page also lifts this gate itself
      // after 20s as a hard fallback.
      return;
    }
    Timer(const Duration(milliseconds: 500), () {
      if (mounted && !_faceOnlyInstructionsSignaled) {
        unawaited(_signalFaceOnlyReadyToPage());
      }
    });
  }

  Future<void> _onPhotoReceived(Uint8List? bytes) async {
    if (_sent || _isWaitingForSpeech) return;

    if (bytes == null) {
      _sent = true;
      _controller = null;
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

    // Fix for PigeonProxyApiRegistrar memory leak: dispose controller before popping
    _controller = null;

    if (mounted) {
      Navigator.of(context).pop();
    }
    widget.onPhoto(bytes);
  }

  void _onLogReceived(JavaScriptMessage message) {
    // Structured diagnostics from the capture page (ready/metrics/stuck/
    // warn/error) plus 'voice' live-coaching events. Surfaced in release logs
    // so support can tell which gate is stuck on a specific device instead of
    // guessing.
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type']?.toString() ?? 'log';
        if (type == 'voice') {
          // If a photo was captured and we are waiting for the current sentence
          // to finish, ignore any further coaching lines.
          if (_isWaitingForSpeech || _sent) return;

          // Live capture coaching: the capture page reached a new gate and
          // asked for its localized status line to be spoken.
          final data = decoded['data'];
          final key = data is Map ? data['key']?.toString() : null;
          if (key != null && key.isNotEmpty) {
            unawaited(VoiceGuidanceService.instance.speakKey(key));
          }
          return;
        }
        if (type == 'error' || type == 'stuck') {
          debugPrint('VERIFICATION CAPTURE [$type]: ${message.message}');
        } else if (kDebugMode) {
          debugPrint('VERIFICATION CAPTURE [$type]: ${message.message}');
        }
        return;
      }
    } catch (_) {
      // Fall through to plain logging.
    }
    debugPrint('VERIFICATION CAPTURE [log]: ${message.message}');
  }

  Future<void> _handleWebViewPermissionRequest(
    WebViewPermissionRequest request,
  ) async {
    // Android WebView denies camera access unless the host app responds to the
    // embedded page's permission request.
    final needsCamera = request.types.contains(
      WebViewPermissionResourceType.camera,
    );
    final needsMicrophone = request.types.contains(
      WebViewPermissionResourceType.microphone,
    );

    var cameraGranted = !needsCamera;
    if (needsCamera) {
      var cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted && !cameraStatus.isLimited) {
        cameraStatus = await Permission.camera.request();
      }
      // Some OEMs report `limited` for foreground camera access; that still
      // allows capture, so it must not be treated as denied.
      cameraGranted = cameraStatus.isGranted || cameraStatus.isLimited;
    }

    var microphoneGranted = !needsMicrophone;
    if (needsMicrophone) {
      var microphoneStatus = await Permission.microphone.status;
      if (!microphoneStatus.isGranted && !microphoneStatus.isLimited) {
        microphoneStatus = await Permission.microphone.request();
      }
      microphoneGranted =
          microphoneStatus.isGranted || microphoneStatus.isLimited;
    }

    if (cameraGranted && microphoneGranted) {
      print(
        'Granting WebView permission request: ${request.types.map((type) => type.name).join(', ')}',
      );
      await request.grant();
      return;
    }

    await request.deny();
    if (!mounted) return;

    final l10n = ref.read(localizationProvider);
    setState(() {
      _cameraPermissionDenied = needsCamera && !cameraGranted;
      _loadError = l10n.getString('verificationCaptureCameraPermissionDenied');
    });
  }

  Future<void> _initController() async {
    if (!_isLiveCaptureSupported()) {
      print(
        'Verification capture: WebView not supported on ${Platform.operatingSystem}, showing error UI',
      );
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        setState(() {
          _loadError = l10n
              .getString('verificationCaptureWrapperFailedToLoad')
              .replaceAll('{error}', 'WebView not supported on this platform');
        });
      }
      return;
    }
    // Skip native camera permission check on iOS - let WebView handle its own camera permission
    // On iOS, the WebView has its own permission system and will prompt for camera access
    // The native permission check can fail incorrectly due to permission_handler limitations
    if (Platform.isIOS) {
      print('iOS detected - letting WebView handle camera permission');
    } else {
      // For Android, check native camera permission first
      var cameraStatus = await Permission.camera.status;
      print('Camera permission status: $cameraStatus');
      print('Camera status isGranted: ${cameraStatus.isGranted}');
      print('Camera status isDenied: ${cameraStatus.isDenied}');
      print(
        'Camera status isPermanentlyDenied: ${cameraStatus.isPermanentlyDenied}',
      );
      print('Camera status isRestricted: ${cameraStatus.isRestricted}');
      print('Camera status isLimited: ${cameraStatus.isLimited}');

      if (!cameraStatus.isGranted && !cameraStatus.isLimited) {
        if (cameraStatus.isPermanentlyDenied || cameraStatus.isRestricted) {
          print(
            'Camera permission permanently denied/restricted - showing settings',
          );
        } else {
          print('Requesting camera permission...');
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
    }

    print('Loading WebView...');

    try {
      final html = await rootBundle.loadString(
        'assets/verification_capture/index.html',
      );
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
          .replaceFirst('__CAPTURE_DEBUG_JSON__', jsonEncode(kDebugMode))
          .replaceFirst('__BOTTOM_INSET_JSON__', jsonEncode(_bottomInsetPx()));
      print('HTML with params prepared');

      if (!mounted) return;

      PlatformWebViewControllerCreationParams params =
          const PlatformWebViewControllerCreationParams();
      if (WebViewPlatform.instance is WebKitWebViewPlatform) {
        params =
            WebKitWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
              params,
              allowsInlineMediaPlayback: true,
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
            );
      } else if (WebViewPlatform.instance is AndroidWebViewPlatform) {
        params =
            AndroidWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
              params,
            );
      }

      print(
        'Creating WebView controller with platform: ${WebViewPlatform.instance}',
      );

      if (kDebugMode && Platform.isAndroid) {
        // Allows chrome://inspect debugging of the capture page on test devices.
        try {
          await AndroidWebViewController.enableDebugging(true);
        } catch (e) {
          debugPrint('Could not enable WebView debugging: $e');
        }
      }

      final c = WebViewController.fromPlatformCreationParams(
        params,
        onPermissionRequest: (WebViewPermissionRequest request) {
          unawaited(_handleWebViewPermissionRequest(request));
        },
      );

      if (Platform.isAndroid) {
        // Autoplay of the camera preview must not require a tap inside the
        // WebView; the host screen was already opened via a user gesture.
        try {
          await (c.platform as AndroidWebViewController)
              .setMediaPlaybackRequiresUserGesture(false);
        } catch (e) {
          debugPrint('Could not set media playback gesture requirement: $e');
        }
      }

      c
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..addJavaScriptChannel(
          'PhotoCapture',
          onMessageReceived: (JavaScriptMessage message) {
            try {
              final bytes = Uint8List.fromList(base64Decode(message.message));
              print('Received photo from WebView, length: ${bytes.length}');
              _onPhotoReceived(bytes);
            } catch (e) {
              print('Error decoding photo from WebView: $e');
              _onPhotoReceived(null);
            }
          },
        )
        ..addJavaScriptChannel(
          'ValidationLog',
          onMessageReceived: _onLogReceived,
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) {
              print('WebView page started: $url');
            },
            onPageFinished: (String url) async {
              print('WebView page finished: $url');
              // Fix for Android WebView camera permission race condition
              await Future<void>.delayed(const Duration(milliseconds: 1000));
            },
            onWebResourceError: (WebResourceError error) {
              print('WebView resource error: $error');
            },
            onNavigationRequest: (NavigationRequest request) {
              // Top-level navigations stay locked down, but MediaPipe model
              // fetches (WASM + .task files) must be reachable.
              if (request.url.startsWith('https://cdn.jsdelivr.net') ||
                  request.url.startsWith('https://unpkg.com') ||
                  request.url.startsWith('https://storage.googleapis.com')) {
                return NavigationDecision.navigate;
              }
              print('Blocking navigation to: ${request.url}');
              return NavigationDecision.prevent;
            },
          ),
        )
        ..loadHtmlString(htmlWithParams, baseUrl: 'https://cdn.jsdelivr.net/');

      print('WebView controller created');

      if (!mounted) return;
      setState(() {
        _controller = c;
      });
      print('WebView controller set in state');
      // If the instructions already finished speaking while the WebView was
      // loading, lift the auto-capture gate now.
      if (_isFaceOnlyCapture && _faceOnlyInstructionsSpoken) {
        unawaited(_signalFaceOnlyReadyToPage());
      }
    } catch (e) {
      print('Error initializing WebView controller: $e');
      if (mounted) {
        setState(() => _loadError = e.toString());
      }
    }
  }

  @override
  void dispose() {
    // Route closed without delivering a photo (user backed out): silence any
    // guidance still speaking and notify listeners that only care about
    // cancellation. Photo delivery sets _sent first, so a successful capture
    // never triggers onClose.
    if (!_sent) {
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Critical fix for Android WebView race condition: wait for platform view to be fully attached
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      // Primary selfie: speak the instructions now (while the camera/models
      // load) so the user hears what to do; the page holds auto-capture
      // until speaking finishes. _signalFaceOnlyReadyToPage retries with
      // backoff until the page acknowledges, so the gate can't be lost to a
      // WebView race, and the page lifts it itself after 20s as a fallback.
      if (_isFaceOnlyCapture) {
        unawaited(_speakPrimarySelfieInstructionsAndSignalReady());
      }
      _initController().catchError((e) {
        if (mounted) setState(() => _loadError = e.toString());
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      final l10n = ref.watch(localizationProvider);
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(l10n.getString('verification'))),
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
    if (_controller == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(ref.watch(localizationProvider).getString('verification')),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _controller!)),
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
        ],
      ),
    );
  }
}
