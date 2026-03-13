// Mobile/desktop: MediaPipe gesture capture via WebView (same flow as web).
import 'dart:convert';

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
    if (widget.inputImageBytes == null) {
      var cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) {
        if (cameraStatus.isDenied || cameraStatus.isPermanentlyDenied || cameraStatus.isRestricted) {
          // Don't bother requesting, just go to show settings
        } else {
          cameraStatus = await Permission.camera.request();
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
        return;
      }
    }

    final html = await rootBundle.loadString('assets/verification_capture/index.html');
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
            _onPhotoReceived(bytes);
          } catch (_) {
            _onPhotoReceived(null);
          }
        },
      )
      ..loadHtmlString(
        htmlWithParams,
        baseUrl: 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@latest/',
      );
    setState(() {
      _controller = c;
    });
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
