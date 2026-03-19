// Mobile/desktop: MediaPipe gesture capture via WebView (same flow as web).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Opens the MediaPipe gesture capture page in a full-screen WebView. When the user
/// captures a photo, [onPhoto] is called with the JPEG bytes. [context] is required
/// to push the WebView route.
void openMediaPipeVerificationCapture({
  required String gestureCode,
  required void Function(Uint8List?) onPhoto,
  String? gestureLabel,
  Map<String, String>? captureStrings,
  Uint8List? inputImageBytes,
  BuildContext? context,
}) {
  final ctx = context;
  if (ctx == null || !ctx.mounted) {
    onPhoto(null);
    return;
  }

  Navigator.of(ctx).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => _MediaPipeCapturePage(
        gestureCode: gestureCode,
        gestureLabel: gestureLabel,
        captureStrings: captureStrings,
        inputImageBytes: inputImageBytes,
        onPhoto: onPhoto,
      ),
    ),
  ).then((_) {
    // If route was popped without sending a photo, ensure we don't leave callback dangling
    // (onPhoto is only called when we receive base64 from the WebView)
  });
}

class _MediaPipeCapturePage extends ConsumerStatefulWidget {
  const _MediaPipeCapturePage({
    required this.gestureCode,
    required this.gestureLabel,
    required this.captureStrings,
    required this.inputImageBytes,
    required this.onPhoto,
  });

  final String gestureCode;
  final String? gestureLabel;
  final Map<String, String>? captureStrings;
  final Uint8List? inputImageBytes;
  final void Function(Uint8List?) onPhoto;

  @override
  ConsumerState<_MediaPipeCapturePage> createState() => _MediaPipeCapturePageState();
}

class _MediaPipeCapturePageState extends ConsumerState<_MediaPipeCapturePage> {
  bool _sent = false;
  WebViewController? _controller;
  String? _loadError;
  bool _cameraPermissionDenied = false;

  void _onPhotoReceived(Uint8List? bytes) {
    if (_sent) return;
    _sent = true;
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onPhoto(bytes);
  }

  Future<void> _initController() async {
    // Skip native camera permission check on iOS - let WebView handle its own camera permission
    // On iOS, the WebView has its own permission system and will prompt for camera access
    // The native permission check can fail incorrectly due to permission_handler limitations
    if (Platform.isIOS) {
      debugPrint('iOS detected - letting WebView handle camera permission');
    } else {
      // For Android, check native camera permission first
      var cameraStatus = await Permission.camera.status;
      debugPrint('Camera permission status: $cameraStatus');
      debugPrint('Camera status isGranted: ${cameraStatus.isGranted}');
      debugPrint('Camera status isDenied: ${cameraStatus.isDenied}');
      debugPrint('Camera status isPermanentlyDenied: ${cameraStatus.isPermanentlyDenied}');
      debugPrint('Camera status isRestricted: ${cameraStatus.isRestricted}');
      debugPrint('Camera status isLimited: ${cameraStatus.isLimited}');
      
      if (!cameraStatus.isGranted) {
        if (cameraStatus.isPermanentlyDenied || cameraStatus.isRestricted) {
          debugPrint('Camera permission permanently denied/restricted - showing settings');
        } else {
          debugPrint('Requesting camera permission...');
          cameraStatus = await Permission.camera.request();
          debugPrint('After request, camera status: $cameraStatus');
        }
      }
      if (!cameraStatus.isGranted) {
        final l10n = ref.read(localizationProvider);
        if (mounted) {
          setState(
            () {
              _cameraPermissionDenied = true;
              _loadError = l10n.getString('verificationCaptureCameraPermissionDenied');
            },
          );
        }
        debugPrint('Camera permission denied, showing error UI');
        return;
      }
    }
    
    debugPrint('Loading WebView...');
    
    try {
      final html = await rootBundle.loadString('assets/verification_capture/index.html');
      debugPrint('Loaded HTML successfully, length: ${html.length}');
      
      final htmlWithParams = html
          .replaceFirst('__GESTURE_CODE_JSON__', jsonEncode(widget.gestureCode))
          .replaceFirst('__GESTURE_LABEL_JSON__', jsonEncode(widget.gestureLabel ?? ''))
          .replaceFirst(
            '__CAPTURE_STRINGS_JSON__',
            jsonEncode(widget.captureStrings ?? <String, String>{}),
          )
          .replaceFirst(
            '__INPUT_IMAGE_BASE64_JSON__',
            jsonEncode(
              widget.inputImageBytes == null ? '' : base64Encode(widget.inputImageBytes!),
            ),
          );
      debugPrint('HTML with params prepared');
      
      if (!mounted) return;
      
      PlatformWebViewControllerCreationParams params =
          const PlatformWebViewControllerCreationParams();
      if (WebViewPlatform.instance is WebKitWebViewPlatform) {
        params = WebKitWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
          params,
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      } else if (WebViewPlatform.instance is AndroidWebViewPlatform) {
        params = AndroidWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
          params,
        );
      }
      
      debugPrint('Creating WebView controller with platform: ${WebViewPlatform.instance}');
      
      final c = WebViewController.fromPlatformCreationParams(
        params,
        onPermissionRequest: (request) => request.grant(),
      )
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'PhotoCapture',
          onMessageReceived: (JavaScriptMessage message) {
            try {
              final bytes = Uint8List.fromList(base64Decode(message.message));
              debugPrint('Received photo from WebView, length: ${bytes.length}');
              _onPhotoReceived(bytes);
            } catch (e) {
              debugPrint('Error decoding photo from WebView: $e');
              _onPhotoReceived(null);
            }
          },
        )
        ..loadHtmlString(
          htmlWithParams,
          baseUrl: 'https://cdn.jsdelivr.net/',
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) {
              debugPrint('WebView page started: $url');
            },
            onPageFinished: (String url) {
              debugPrint('WebView page finished: $url');
            },
            onWebResourceError: (WebResourceError error) {
              debugPrint('WebView resource error: $error');
            },
            onNavigationRequest: (NavigationRequest request) {
              if (request.url.startsWith('https://cdn.jsdelivr.net') ||
                  request.url.startsWith('https://unpkg.com')) {
                return NavigationDecision.navigate;
              }
              debugPrint('Blocking navigation to: ${request.url}');
              return NavigationDecision.prevent;
            },
          ),
        );
      
      debugPrint('WebView controller created');
      
      if (!mounted) return;
      setState(() {
        _controller = c;
      });
      debugPrint('WebView controller set in state');
    } catch (e) {
      debugPrint('Error initializing WebView controller: $e');
      if (mounted) {
        setState(() => _loadError = e.toString());
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _initController().catchError((e) {
      if (mounted) setState(() => _loadError = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      final l10n = ref.watch(localizationProvider);
      return Scaffold(
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: WebViewWidget(controller: _controller!),
      ),
    );
  }
}
