import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/error_localization_service.dart';

class PhotoConfirmationWidget extends ConsumerWidget {
  final Uint8List photoBytes;
  final VoidCallback onConfirm;
  final VoidCallback onRetake;

  const PhotoConfirmationWidget({
    super.key,
    required this.photoBytes,
    required this.onConfirm,
    required this.onRetake,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Photo preview
          Positioned.fill(child: Image.memory(photoBytes, fit: BoxFit.contain)),

          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      onPressed: onRetake,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    Expanded(
                      child: Text(
                        ref
                            .watch(localizationProvider)
                            .getString('confirmYourPhoto'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
          ),

          // Bottom buttons
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(24),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: onRetake,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          ref.watch(localizationProvider).getString('retake'),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: onConfirm,
                        icon: const Icon(Icons.check),
                        label: Text(
                          ref.watch(localizationProvider).getString('usePhoto'),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CameraPreviewWidget extends ConsumerStatefulWidget {
  final CameraController controller;
  final String? gestureTitle;
  final String? gestureDescription;

  const CameraPreviewWidget({
    super.key,
    required this.controller,
    this.gestureTitle,
    this.gestureDescription,
  });

  @override
  ConsumerState<CameraPreviewWidget> createState() =>
      _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends ConsumerState<CameraPreviewWidget> {
  bool _isTakingPhoto = false;
  bool _isCountdownActive = false;
  int _countdownSeconds = 3;

  @override
  void initState() {
    super.initState();
    _resetCameraPreview();
  }

  Future<void> _resetCameraPreview() async {
    try {
      if (widget.controller.value.isInitialized) {
        // Pause and resume to clear any cached frames
        await widget.controller.pausePreview();
        await Future.delayed(const Duration(milliseconds: 300));
        await widget.controller.resumePreview();

        // Add additional delay to ensure camera fully resets
        await Future.delayed(const Duration(milliseconds: 200));

        // Force a widget rebuild to ensure fresh preview
        if (mounted) {
          setState(() {
            _isTakingPhoto = false;
            _isCountdownActive = false;
          });
        }
      }
    } catch (e) {
      // Ignore camera reset errors
    }
  }

  // Public method to force reset - can be called when widget is reused
  void forceResetPreview() {
    if (mounted) {
      _resetCameraPreview();
    }
  }

  Future<void> _startCountdownAndTakePhoto() async {
    if (!mounted) return;
    setState(() {
      _isCountdownActive = true;
      _countdownSeconds = 3;
    });

    // Countdown from 3 to 1
    for (int i = 3; i >= 1; i--) {
      if (!mounted) return;

      setState(() {
        _countdownSeconds = i;
      });

      await Future.delayed(const Duration(seconds: 1));
    }

    if (!mounted) return;
    await _takePhoto();
  }

  Future<void> _takePhoto() async {
    if (!mounted || _isTakingPhoto) return;

    setState(() {
      _isTakingPhoto = true;
      _isCountdownActive = false;
    });

    try {
      final XFile photoFile = await widget.controller.takePicture();
      final Uint8List photoBytes = await photoFile.readAsBytes();

      if (!mounted) return;

      // Return to verification screen with the photo
      Navigator.pop(context, photoBytes);
    } catch (e) {
      if (mounted) {
        final l10n = ref.watch(localizationProvider);
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
        final errorMessage = l10n.getString(errorKey);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMessage)));
        setState(() {
          _isTakingPhoto = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Build children list dynamically to handle conditional countdown overlay
    final List<Widget> children = [];

    // Show camera preview - force rebuild when state changes
    children.add(
      // Camera preview - fill screen with proper aspect ratio
      Positioned.fill(
        key: ValueKey<bool>(_isTakingPhoto), // Force rebuild when state changes
        child: AspectRatio(
          aspectRatio: widget.controller.value.aspectRatio,
          child: CameraPreview(widget.controller),
        ),
      ),
    );

    // Instruction text and gesture at the top center
    children.add(
      Positioned(
        top: MediaQuery.of(context).padding.top + 20,
        left: 16,
        right: 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ref
                  .watch(localizationProvider)
                  .getString('cameraVerificationInstruction'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 6, color: Colors.black)],
              ),
              textAlign: TextAlign.center,
            ),
            if (widget.gestureDescription != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.gestureDescription!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );

    // Face guide overlay - positioned over camera preview
    children.add(
      Positioned.fill(
        child: AspectRatio(
          aspectRatio: widget.controller.value.aspectRatio,
          child: CustomPaint(
            painter: FaceGuidePainter(
              orientation: MediaQuery.of(context).orientation,
            ),
          ),
        ),
      ),
    );

    // Bottom capture button - responsive to orientation
    children.add(
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Container(
          color: Colors.black54,
          padding: MediaQuery.of(context).orientation == Orientation.portrait
              ? const EdgeInsets.all(24)
              : const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          child: SafeArea(
            top: false,
            child: MediaQuery.of(context).orientation == Orientation.portrait
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                          color: _isTakingPhoto || _isCountdownActive
                              ? Colors.grey
                              : Colors.white,
                        ),
                        child: FloatingActionButton(
                          heroTag: 'camera_preview_primary_fab',
                          onPressed: (_isTakingPhoto || _isCountdownActive)
                              ? null
                              : _startCountdownAndTakePhoto,
                          backgroundColor: Colors.transparent,
                          elevation: 0,
                          child: _isTakingPhoto
                              ? const CircularProgressIndicator(
                                  color: Colors.black,
                                )
                              : const Icon(
                                  Icons.camera,
                                  color: Colors.black,
                                  size: 32,
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isCountdownActive
                            ? '${ref.watch(localizationProvider).getString('takingPhotoIn')} $_countdownSeconds...'
                            : ref
                                  .watch(localizationProvider)
                                  .getString('takePhoto'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          color: _isTakingPhoto || _isCountdownActive
                              ? Colors.grey
                              : Colors.white,
                        ),
                        child: FloatingActionButton(
                          heroTag: 'camera_preview_secondary_fab',
                          onPressed: (_isTakingPhoto || _isCountdownActive)
                              ? null
                              : _startCountdownAndTakePhoto,
                          backgroundColor: Colors.transparent,
                          elevation: 0,
                          child: _isTakingPhoto
                              ? const CircularProgressIndicator(
                                  color: Colors.black,
                                  strokeWidth: 2,
                                )
                              : const Icon(
                                  Icons.camera,
                                  color: Colors.black,
                                  size: 28,
                                ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Text(
                        _isCountdownActive
                            ? '${ref.watch(localizationProvider).getString('takingPhotoIn')} $_countdownSeconds...'
                            : ref
                                  .watch(localizationProvider)
                                  .getString('takePhoto'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );

    // Add countdown overlay if active
    if (_isCountdownActive) {
      final currentOrientation = MediaQuery.of(context).orientation;
      children.add(
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.7),
            child: Center(
              child: Container(
                width: currentOrientation == Orientation.portrait ? 120 : 100,
                height: currentOrientation == Orientation.portrait ? 120 : 100,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _countdownSeconds.toString(),
                    style: TextStyle(
                      fontSize: currentOrientation == Orientation.portrait
                          ? 48
                          : 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: children),
    );
  }
}

class FaceGuidePainter extends CustomPainter {
  final Orientation? orientation;

  FaceGuidePainter({this.orientation});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Calculate oval dimensions based on canvas size and orientation
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // Adjust oval size based on orientation for better face fitting
    final ovalWidth =
        size.width * (orientation == Orientation.portrait ? 0.6 : 0.4);
    final ovalHeight =
        size.height * (orientation == Orientation.portrait ? 0.4 : 0.6);

    // Draw the face guide oval
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: ovalWidth,
        height: ovalHeight,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
