import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

class CustomCameraWidget extends ConsumerStatefulWidget {
  final bool useFrontCamera;
  final Function(Uint8List) onImageCaptured;

  const CustomCameraWidget({
    super.key,
    this.useFrontCamera = true,
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
          setState(() => _hasCameraError = true);
          final l10n = ref.read(localizationProvider);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.getString('cameraNoCamerasAvailable'))),
          );
        }
        return;
      }

      // Find the desired camera (front or rear)
      CameraDescription? selectedCamera;

      if (widget.useFrontCamera) {
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
      if (mounted) {
        setState(() => _hasCameraError = true);
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString(
                'cameraInitFailed',
                params: {'error': e.toString()},
              ),
            ),
          ),
        );
      }
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
      setState(() {
        _isCapturing = false;
      });
    }
  }

  void _switchCamera() {
    if (_cameras.length < 2) return;

    // Find the opposite camera
    CameraDescription? newCamera;
    final currentCamera = _controller!.description;

    if (currentCamera.lensDirection == CameraLensDirection.front) {
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
        appBar: AppBar(title: Text(l10n.getString('cameraTitle'))),
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
        appBar: AppBar(title: Text(l10n.getString('cameraTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _controller?.description.lensDirection == CameraLensDirection.front
              ? l10n.getString('cameraSelfieTitle')
              : l10n.getString('cameraRearTitle'),
        ),
        actions: [
          if (_cameras.length > 1)
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
}) async {
  Uint8List? capturedImage;

  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CustomCameraWidget(
        useFrontCamera: useFrontCamera,
        onImageCaptured: (bytes) {
          capturedImage = bytes;
          Navigator.pop(context);
        },
      ),
    ),
  );

  return capturedImage;
}
