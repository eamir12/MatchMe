import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/safe_text.dart';

class CustomCameraWidget extends ConsumerStatefulWidget {
  final bool useFrontCamera;

  /// When true, only a front-facing camera is acceptable. Missing permission
  /// or a rear-only device reports an error instead of silently using a rear
  /// camera, and the flip control is hidden.
  final bool frontOnly;
  final ValueChanged<String>? onCameraError;
  final Function(Uint8List) onImageCaptured;

  const CustomCameraWidget({
    super.key,
    this.useFrontCamera = true,
    this.frontOnly = false,
    this.onCameraError,
    required this.onImageCaptured,
  });

  @override
  ConsumerState<CustomCameraWidget> createState() => _CustomCameraWidgetState();
}

class _CustomCameraWidgetState extends ConsumerState<CustomCameraWidget> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isCapturing = false;
  bool _hasCameraError = false;

  /// Selfie flows pass [CustomCameraWidget.onCameraError] and auto-close so the
  /// caller can show its own localized message instead of this screen's
  /// generic "camera not available" page.
  void _reportFatal(String code) {
    if (!mounted) return;
    final handler = widget.onCameraError;
    if (handler != null) {
      Navigator.of(context).pop();
      handler(code);
      return;
    }
    setState(() => _hasCameraError = true);
    final l10n = ref.read(localizationProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.getString('cameraNotAvailable'))),
    );
  }

  static bool _looksDenied(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('denied') || message.contains('permission');
  }

  /// camera_windows reports every device as a front camera and has no notion
  /// of lens direction, so on Windows the lens labels are meaningless and
  /// switching has to cycle devices instead of matching front/back.
  bool get _lensDirectionKnown =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras().timeout(const Duration(seconds: 15));

      if (_cameras.isEmpty) {
        if (mounted) {
          _reportFatal('unavailable');
        }
        return;
      }

      // Find the desired camera (front or rear)
      CameraDescription? selectedCamera;

      if (widget.frontOnly) {
        final frontCameras = _cameras
            .where(
              (camera) => camera.lensDirection == CameraLensDirection.front,
            )
            .toList(growable: false);
        if (frontCameras.isEmpty) {
          _reportFatal('unavailable');
          return;
        }
        selectedCamera = frontCameras.first;
      } else if (widget.useFrontCamera) {
        // Try to find front camera
        selectedCamera = _cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => _cameras.first,
        );
      } else {
        // Try to find rear camera
        selectedCamera = _cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => _cameras.first,
        );
      }

      _controller = CameraController(
        selectedCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize().timeout(const Duration(seconds: 15));

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (widget.onCameraError != null) {
        _reportFatal(_looksDenied(e) ? 'denied' : 'unavailable');
        return;
      }
      setState(() => _hasCameraError = true);
      final l10n = ref.read(localizationProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString('cameraInitFailed', params: {'error': e.toString()}),
          ),
        ),
      );
    }
  }

  Future<void> _captureImage() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCapturing) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      // Take the picture
      final XFile file = await _controller!.takePicture();

      // Read the file as bytes
      final Uint8List bytes = await file.readAsBytes();

      // Return the image bytes
      widget.onImageCaptured(bytes);
    } catch (e) {
      if (mounted) {
        if (widget.onCameraError != null) {
          _reportFatal('failed');
          return;
        }
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString(
                'cameraCaptureFailed',
                params: {'error': e.toString()},
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  void _switchCamera() {
    if (widget.frontOnly || _cameras.length < 2) return;

    // Find the opposite camera
    CameraDescription? newCamera;
    final currentCamera = _controller!.description;

    if (!_lensDirectionKnown) {
      final index = _cameras.indexWhere(
        (camera) => camera.name == currentCamera.name,
      );
      newCamera = _cameras[(index + 1) % _cameras.length];
    } else if (currentCamera.lensDirection == CameraLensDirection.front) {
      newCamera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
    } else {
      newCamera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );
    }

    _initializeNewCamera(newCamera);
  }

  Future<void> _initializeNewCamera(CameraDescription newCamera) async {
    if (_controller != null) {
      await _controller!.dispose();
    }

    setState(() {
      _isCameraInitialized = false;
    });

    _controller = CameraController(
      newCamera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      // Handle error silently
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    if (_hasCameraError) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('cameraTitle'))),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(l10n.getString('cameraNotAvailable')),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.getString('generalBack')),
              ),
            ],
          ),
        ),
      );
    }
    if (!_isCameraInitialized) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('cameraTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: ShrinkText(
          !_lensDirectionKnown
              ? l10n.getString('cameraTitle')
              : _controller?.description.lensDirection ==
                    CameraLensDirection.front
              ? l10n.getString('cameraSelfieTitle')
              : l10n.getString('cameraRearTitle'),
        ),
        actions: [
          if (!widget.frontOnly && _cameras.length > 1)
            IconButton(
              icon: const Icon(Icons.flip_camera_ios),
              onPressed: _switchCamera,
            ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          Positioned.fill(child: CameraPreview(_controller!)),

          // Capture button
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                onPressed: _isCapturing ? null : _captureImage,
                backgroundColor: _isCapturing ? Colors.grey : Colors.blue,
                child: _isCapturing
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Icon(Icons.camera_alt, size: 30),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper function to show custom camera and return image bytes
Future<Uint8List?> showCustomCamera({
  required BuildContext context,
  bool useFrontCamera = true,
  bool frontOnly = false,
  ValueChanged<String>? onCameraError,
}) async {
  Uint8List? capturedImage;

  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CustomCameraWidget(
        useFrontCamera: useFrontCamera,
        frontOnly: frontOnly,
        onCameraError: onCameraError,
        onImageCaptured: (bytes) {
          capturedImage = bytes;
          Navigator.pop(context);
        },
      ),
    ),
  );

  return capturedImage;
}
