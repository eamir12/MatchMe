// lib/services/photo_prescreen_service.dart
// Service for local photo prescreening before sending to Gemini AI validation
// Extends existing ML Kit/Vision framework integration with additional validation rules

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'photo_prescreen_web_stub.dart'
    if (dart.library.html) 'photo_prescreen_web.dart';

/// Result of photo prescreening analysis
class PhotoPrescreenResult {
  final bool passed;
  final PrescreenFailureReason? failureReason;
  final double confidence;
  final FaceAnalysis? faceAnalysis;
  final BodyAnalysis? bodyAnalysis;
  final ImageQuality? imageQuality;
  final String? errorMessage;

  const PhotoPrescreenResult({
    required this.passed,
    this.failureReason,
    required this.confidence,
    this.faceAnalysis,
    this.bodyAnalysis,
    this.imageQuality,
    this.errorMessage,
  });

  factory PhotoPrescreenResult.passedWithConfidence({
    required double confidence,
    FaceAnalysis? faceAnalysis,
    BodyAnalysis? bodyAnalysis,
    ImageQuality? imageQuality,
  }) {
    return PhotoPrescreenResult(
      passed: true,
      confidence: confidence,
      faceAnalysis: faceAnalysis,
      bodyAnalysis: bodyAnalysis,
      imageQuality: imageQuality,
    );
  }

  factory PhotoPrescreenResult.failed({
    required PrescreenFailureReason reason,
    String? errorMessage,
    double confidence = 0.0,
  }) {
    return PhotoPrescreenResult(
      passed: false,
      failureReason: reason,
      confidence: confidence,
      errorMessage: errorMessage,
    );
  }
}

/// Detailed face analysis results
class FaceAnalysis {
  final bool faceDetected;
  final int faceCount;
  final double faceConfidence;
  final double faceSizeRatio; // Face area as ratio of total image
  final bool facePositionedCenter;

  /// True when the detector's face rectangle reaches the image boundary.
  /// A profile photo cannot rely on a face that has been cut off by its crop.
  final bool faceTouchesImageEdge;

  /// At least one detected face has a rectangle wholly inside the image.
  final bool completeFaceDetected;
  final bool faceObstructed;

  const FaceAnalysis({
    required this.faceDetected,
    required this.faceCount,
    required this.faceConfidence,
    required this.faceSizeRatio,
    required this.facePositionedCenter,
    required this.faceTouchesImageEdge,
    required this.completeFaceDetected,
    required this.faceObstructed,
  });

  bool get hasSingleFace => faceDetected && faceCount == 1;
  bool get hasMultipleFaces => faceCount > 1;
}

/// Detailed body analysis results
class BodyAnalysis {
  final bool bodyDetected;
  final double bodyConfidence;
  final bool upperBodyOnly;
  final bool fullBodyVisible;

  /// At least one body includes head, torso, legs, and feet inside the frame.
  final bool completeBodyDetected;

  const BodyAnalysis({
    required this.bodyDetected,
    required this.bodyConfidence,
    required this.upperBodyOnly,
    required this.fullBodyVisible,
    required this.completeBodyDetected,
  });

  bool get hasClearBody => bodyDetected && bodyConfidence >= 0.6;
}

/// Image quality metrics
class ImageQuality {
  final int width;
  final int height;
  final double aspectRatio;
  final int fileSize;
  final String format;
  final double blurScore; // 0-1, higher is sharper
  final double brightnessScore; // 0-1, 0.5 is ideal

  const ImageQuality({
    required this.width,
    required this.height,
    required this.aspectRatio,
    required this.fileSize,
    required this.format,
    required this.blurScore,
    required this.brightnessScore,
  });
}

/// Localization key for a prescreen failure reason, shared by the visual
/// failure dialog and non-UI callers (e.g. reorder-promotion gating) so the
/// reason-to-message mapping lives in exactly one place.
String prescreenFailureL10nKey(PrescreenFailureReason? reason) {
  switch (reason) {
    case PrescreenFailureReason.invalidFormat:
      return 'photoErrorInvalidFormat';
    case PrescreenFailureReason.fileTooLarge:
      return 'photoErrorFileTooLarge';
    case PrescreenFailureReason.fileTooSmall:
      return 'photoErrorFileTooSmall';
    case PrescreenFailureReason.resolutionTooLow:
      return 'photoErrorResolutionTooLow';
    case PrescreenFailureReason.aspectRatioInvalid:
      return 'photoErrorAspectRatioInvalid';
    case PrescreenFailureReason.imageCorrupted:
      return 'photoErrorImageCorrupted';
    case PrescreenFailureReason.duplicatePhoto:
      return 'photoErrorDuplicatePhoto';
    case PrescreenFailureReason.noFaceOrBody:
      return 'photoErrorNoFaceOrBody';
    case PrescreenFailureReason.noFaceDetected:
      return 'photoErrorNoFaceDetected';
    case PrescreenFailureReason.bodyShotNotAllowed:
      return 'photoErrorBodyShotNotAllowed';
    case PrescreenFailureReason.multipleFaces:
      return 'photoErrorMultipleFaces';
    case PrescreenFailureReason.faceTooSmall:
      return 'photoErrorFaceTooSmall';
    case PrescreenFailureReason.faceNotVisible:
      return 'photoErrorFaceNotVisible';
    case PrescreenFailureReason.imageTooBlurry:
      return 'photoErrorImageTooBlurry';
    case PrescreenFailureReason.imageTooDark:
      return 'photoErrorImageTooDark';
    case PrescreenFailureReason.imageTooBright:
      return 'photoErrorImageTooBright';
    case null:
      return 'photoErrorGeneral';
  }
}

/// Reasons for prescreening failure
enum PrescreenFailureReason {
  invalidFormat,
  fileTooLarge,
  fileTooSmall,
  resolutionTooLow,
  aspectRatioInvalid,
  imageCorrupted,
  duplicatePhoto,
  noFaceOrBody,
  multipleFaces,
  faceTooSmall,
  faceNotVisible,
  imageTooBlurry,
  imageTooDark,
  imageTooBright,
  // Primary-photo-only reasons: the first photo must be a face-only selfie
  // with exactly one face. Body-only shots (e.g. someone laying on a beach)
  // must never pass the primary prescreen, even when a body is detected.
  noFaceDetected,
  bodyShotNotAllowed,
}

/// Prescreening configuration
class PrescreenConfig {
  final int minFileSize;
  final int maxFileSize;
  final int minResolution;
  final double minAspectRatio;
  final double maxAspectRatio;
  final double minFaceSizeRatio;
  final double minFaceConfidence;
  final double minBodyConfidence;
  final double minBlurScore;
  final double minBrightness;
  final double maxBrightness;

  const PrescreenConfig({
    this.minFileSize = 10240, // 10KB
    this.maxFileSize = 10485760, // 10MB
    this.minResolution = 200,
    this.minAspectRatio = 0.33,
    this.maxAspectRatio = 3.0,
    this.minFaceSizeRatio = 0.12,
    this.minFaceConfidence = 0.65,
    this.minBodyConfidence = 0.55,
    this.minBlurScore = 0.3,
    this.minBrightness = 0.15,
    this.maxBrightness = 0.95,
  });

  /// Config for primary photos (stricter requirements)
  static const PrescreenConfig primaryPhoto = PrescreenConfig(
    minFileSize: 20480, // 20KB
    maxFileSize: 10485760, // 10MB
    minResolution: 400,
    minAspectRatio: 0.33,
    maxAspectRatio: 3.0,
    minFaceSizeRatio: 0.15,
    minFaceConfidence: 0.75,
    minBodyConfidence: 0.6,
    minBlurScore: 0.4,
    minBrightness: 0.2,
    maxBrightness: 0.9,
  );

  /// Config for secondary photos (more lenient)
  static const PrescreenConfig secondaryPhoto = PrescreenConfig(
    minFileSize: 10240, // 10KB
    maxFileSize: 10485760, // 10MB
    minResolution: 200,
    minAspectRatio: 0.33,
    maxAspectRatio: 3.0,
    minFaceSizeRatio: 0.08,
    minFaceConfidence: 0.6,
    minBodyConfidence: 0.5,
    minBlurScore: 0.25,
    minBrightness: 0.1,
    maxBrightness: 0.95,
  );
}

/// Lightweight image metrics computed off the UI thread in a single decode pass.
class _DecodedImageMetrics {
  final int width;
  final int height;
  final double blurScore;
  final double brightnessScore;

  const _DecodedImageMetrics({
    required this.width,
    required this.height,
    required this.blurScore,
    required this.brightnessScore,
  });
}

/// Top-level functions so they can run in a background isolate via compute().
String _computeImageHashIsolate(Uint8List bytes) {
  try {
    return md5.convert(bytes).toString();
  } catch (_) {
    return '';
  }
}

_DecodedImageMetrics _computeImageMetricsIsolate(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) {
    return const _DecodedImageMetrics(
      width: 0,
      height: 0,
      blurScore: 0,
      brightnessScore: 0,
    );
  }

  return _DecodedImageMetrics(
    width: image.width,
    height: image.height,
    blurScore: _calculateBlurScoreSync(image),
    brightnessScore: _calculateBrightnessScoreSync(image),
  );
}

/// Blur heuristic: pixel-brightness variance sampled across a grayscale copy.
double _calculateBlurScoreSync(img.Image image) {
  try {
    final gray = img.grayscale(image);
    var sum = 0.0;
    var sumSquared = 0.0;
    var count = 0;

    for (var y = 0; y < gray.height; y += 10) {
      for (var x = 0; x < gray.width; x += 10) {
        final pixel = gray.getPixel(x, y);
        final brightness = (pixel.r + pixel.g + pixel.b) / 3;
        sum += brightness;
        sumSquared += brightness * brightness;
        count++;
      }
    }

    if (count == 0) return 0.0;
    final mean = sum / count;
    final variance = (sumSquared / count) - (mean * mean);
    return (variance / 500).clamp(0.0, 1.0);
  } catch (_) {
    return 0.5;
  }
}

double _calculateBrightnessScoreSync(img.Image image) {
  try {
    var totalBrightness = 0.0;
    var pixelCount = 0;

    for (var y = 0; y < image.height; y += 20) {
      for (var x = 0; x < image.width; x += 20) {
        final pixel = image.getPixel(x, y);
        final brightness = (pixel.r + pixel.g + pixel.b) / (3 * 255);
        totalBrightness += brightness;
        pixelCount++;
      }
    }

    if (pixelCount == 0) return 0.5;
    return (totalBrightness / pixelCount).clamp(0.0, 1.0);
  } catch (_) {
    return 0.5;
  }
}

/// Photo prescreening service
class PhotoPrescreenService {
  static const MethodChannel _prescreenChannel = MethodChannel(
    'matchme/photo_prescreen',
  );

  static const Set<String> _supportedFormats = {'jpeg', 'png', 'webp'};

  /// Prescreen a photo for profile wizard use
  /// [bytes] - Image bytes to analyze
  /// [isPrimary] - True if this is a primary photo (stricter rules)
  /// [existingHashes] - Set of existing photo hashes to check for duplicates
  Future<PhotoPrescreenResult> prescreenPhoto(
    Uint8List bytes, {
    bool isPrimary = false,
    Set<String>? existingHashes,
  }) async {
    final config = isPrimary
        ? PrescreenConfig.primaryPhoto
        : PrescreenConfig.secondaryPhoto;

    // 1. Basic file validation
    final fileValidation = _validateFile(bytes, config);
    if (!fileValidation.passed) {
      return fileValidation;
    }

    // 2. Duplicate check (exact-byte match)
    if (existingHashes != null && existingHashes.isNotEmpty) {
      final hash = await compute(_computeImageHashIsolate, bytes);
      if (existingHashes.contains(hash)) {
        return PhotoPrescreenResult.failed(
          reason: PrescreenFailureReason.duplicatePhoto,
        );
      }
    }

    // 3. Image metrics (single decode pass, off the UI thread)
    final metrics = await compute(_computeImageMetricsIsolate, bytes);
    if (metrics.width == 0 || metrics.height == 0) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.imageCorrupted,
      );
    }

    final quality = ImageQuality(
      width: metrics.width,
      height: metrics.height,
      aspectRatio: metrics.width / metrics.height,
      fileSize: bytes.length,
      format: _detectFormat(bytes),
      blurScore: metrics.blurScore,
      brightnessScore: metrics.brightnessScore,
    );

    if (metrics.width < config.minResolution ||
        metrics.height < config.minResolution) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.resolutionTooLow,
      );
    }
    if (quality.aspectRatio < config.minAspectRatio ||
        quality.aspectRatio > config.maxAspectRatio) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.aspectRatioInvalid,
      );
    }
    // The primary image is a clear face photo. Gallery images can be wide,
    // dark, distant, or intentionally stylized, so Gemini—not a coarse local
    // quality heuristic—is the authority for whether they are usable.
    if (isPrimary) {
      if (quality.blurScore < config.minBlurScore) {
        return PhotoPrescreenResult.failed(
          reason: PrescreenFailureReason.imageTooBlurry,
        );
      }
      if (quality.brightnessScore < config.minBrightness) {
        return PhotoPrescreenResult.failed(
          reason: PrescreenFailureReason.imageTooDark,
        );
      }
      if (quality.brightnessScore > config.maxBrightness) {
        return PhotoPrescreenResult.failed(
          reason: PrescreenFailureReason.imageTooBright,
        );
      }
    }

    // 4. Native ML detection (if available)
    final mlResult = await _performNativeDetection(bytes, config);
    if (!mlResult.passed) {
      return mlResult;
    }

    // 5. Apply photo-type specific rules
    if (isPrimary) {
      return _applyPrimaryPhotoRules(mlResult, config);
    } else {
      return _applySecondaryPhotoRules(mlResult);
    }
  }

  /// Validate basic file properties
  PhotoPrescreenResult _validateFile(Uint8List bytes, PrescreenConfig config) {
    if (bytes.isEmpty) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.fileTooSmall,
      );
    }

    if (bytes.length < config.minFileSize) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.fileTooSmall,
      );
    }

    if (bytes.length > config.maxFileSize) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.fileTooLarge,
      );
    }

    final format = _detectFormat(bytes);
    if (!_supportedFormats.contains(format)) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.invalidFormat,
      );
    }

    return PhotoPrescreenResult.passedWithConfidence(confidence: 1.0);
  }

  String _detectFormat(Uint8List bytes) {
    if (bytes.length > 3) {
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpeg';
      if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
      if (bytes[0] == 0x52 && bytes[1] == 0x49) return 'webp';
    }
    return 'unknown';
  }

  /// Perform native ML detection.
  ///
  /// Mobile uses ML Kit / Vision over a MethodChannel. Web uses the MediaPipe
  /// JS still-image detector (web/photo_prescreen.js, same face/body rules).
  /// Desktop has no local ML yet. Any unavailable/failed detector falls back
  /// to Gemini validation instead of falsely rejecting.
  Future<PhotoPrescreenResult> _performNativeDetection(
    Uint8List bytes,
    PrescreenConfig config,
  ) async {
    if (kIsWeb) {
      final webResult = await _performWebDetection(bytes, config);
      if (webResult != null) return webResult;
      // Bridge/models unavailable: skip person checks, Gemini still validates.
      return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // No local ML on desktop: skip person checks, Gemini still validates.
      return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
    }

    try {
      final result = await _prescreenChannel.invokeMapMethod<Object?, Object?>(
        'analyzePhoto',
        {'bytes': bytes},
      );

      if (result == null) {
        return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
      }

      return _parseNativeResult(result, config);
    } catch (_) {
      // Native detection unavailable/failed: fall back to Gemini validation.
      return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
    }
  }

  /// Runs the web MediaPipe JS detector with a bounded wait, so a slow
  /// first-time model download degrades to Gemini instead of hanging the
  /// wizard (the JS layer keeps loading in the background for next time).
  /// Returns null when the bridge/models are unavailable.
  Future<PhotoPrescreenResult?> _performWebDetection(
    Uint8List bytes,
    PrescreenConfig config,
  ) async {
    try {
      final map = await analyzePhotoPrescreenWeb(
        bytes,
      ).timeout(const Duration(seconds: 25));
      if (map == null) return null;
      return _parseNativeResult(Map<Object?, Object?>.from(map), config);
    } catch (_) {
      return null;
    }
  }

  /// Parse native ML detection result
  PhotoPrescreenResult _parseNativeResult(
    Map<Object?, Object?> result,
    PrescreenConfig config,
  ) {
    try {
      final supported = result['supported'] == true;
      if (!supported) {
        return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
      }

      final containsFace = result['containsFace'] == true;
      final containsBody = result['containsBody'] == true;
      final faceConfidence =
          (result['faceConfidence'] as num?)?.toDouble() ?? 0.0;
      final bodyConfidence =
          (result['bodyConfidence'] as num?)?.toDouble() ?? 0.0;
      final faceCount =
          (result['faceCount'] as num?)?.toInt() ?? (containsFace ? 1 : 0);

      final faceAnalysis = containsFace
          ? FaceAnalysis(
              faceDetected: true,
              faceCount: faceCount,
              faceConfidence: faceConfidence,
              faceSizeRatio:
                  (result['faceSizeRatio'] as num?)?.toDouble() ?? 0.0,
              facePositionedCenter: result['facePositionedCenter'] == true,
              faceTouchesImageEdge: result['faceTouchesImageEdge'] == true,
              completeFaceDetected: result['completeFaceDetected'] == true,
              faceObstructed: result['faceObstructed'] == true,
            )
          : FaceAnalysis(
              faceDetected: false,
              faceCount: faceCount,
              faceConfidence: 0.0,
              faceSizeRatio: 0.0,
              facePositionedCenter: false,
              faceTouchesImageEdge: false,
              completeFaceDetected: false,
              faceObstructed: false,
            );

      final bodyAnalysis = BodyAnalysis(
        bodyDetected: containsBody,
        bodyConfidence: bodyConfidence,
        upperBodyOnly: result['upperBodyOnly'] == true,
        fullBodyVisible: result['fullBodyVisible'] == true,
        completeBodyDetected: result['completeBodyDetected'] == true,
      );

      final confidence = _calculateOverallConfidence(
        faceAnalysis,
        bodyAnalysis,
      );

      return PhotoPrescreenResult.passedWithConfidence(
        confidence: confidence,
        faceAnalysis: faceAnalysis,
        bodyAnalysis: bodyAnalysis,
      );
    } catch (_) {
      return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
    }
  }

  /// Calculate overall confidence from ML results
  double _calculateOverallConfidence(
    FaceAnalysis faceAnalysis,
    BodyAnalysis bodyAnalysis,
  ) {
    if (faceAnalysis.faceDetected && bodyAnalysis.bodyDetected) {
      return ((faceAnalysis.faceConfidence + bodyAnalysis.bodyConfidence) / 2)
          .clamp(0.0, 1.0);
    }
    if (faceAnalysis.faceDetected) return faceAnalysis.faceConfidence;
    if (bodyAnalysis.bodyDetected) return bodyAnalysis.bodyConfidence;
    return 0.0;
  }

  /// Apply primary photo specific rules
  ///
  /// The primary (first) photo must contain exactly one face — a face-only
  /// selfie. Body-only shots (e.g. someone laying on a beach) are rejected,
  /// even when a body is detected with high confidence. When no local ML
  /// result is available (detector unavailable/failed), person checks are
  /// skipped so Gemini remains the final validator instead of crashing on a
  /// null dereference.
  PhotoPrescreenResult _applyPrimaryPhotoRules(
    PhotoPrescreenResult mlResult,
    PrescreenConfig config,
  ) {
    final faceAnalysis = mlResult.faceAnalysis;
    final bodyAnalysis = mlResult.bodyAnalysis;

    // No local ML data: cannot enforce face-only locally; defer to Gemini.
    if (faceAnalysis == null || bodyAnalysis == null) {
      return mlResult;
    }

    // Exactly one face is required — group shots are rejected.
    if (faceAnalysis.hasMultipleFaces) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.multipleFaces,
        confidence: mlResult.confidence,
      );
    }

    // No face at all: a body (or nothing) is never acceptable for primary.
    // This is the beach-photo fix — a detected body must NOT let a faceless
    // shot pass as the primary photo.
    if (!faceAnalysis.faceDetected) {
      if (bodyAnalysis.bodyDetected) {
        return PhotoPrescreenResult.failed(
          reason: PrescreenFailureReason.bodyShotNotAllowed,
          confidence: mlResult.confidence,
        );
      }
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.noFaceDetected,
        confidence: mlResult.confidence,
      );
    }

    // Defensive: exactly one face is required. Inconsistent native data
    // (faceDetected true but count != 1) is never valid for primary.
    if (faceAnalysis.faceCount != 1) {
      if (faceAnalysis.faceCount == 0) {
        return PhotoPrescreenResult.failed(
          reason: PrescreenFailureReason.noFaceDetected,
          confidence: mlResult.confidence,
        );
      }
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.multipleFaces,
        confidence: mlResult.confidence,
      );
    }

    if (faceAnalysis.faceConfidence < config.minFaceConfidence) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.faceNotVisible,
        confidence: mlResult.confidence,
      );
    }

    if (faceAnalysis.faceTouchesImageEdge || faceAnalysis.faceObstructed) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.faceNotVisible,
        confidence: mlResult.confidence,
      );
    }

    if (faceAnalysis.faceSizeRatio < config.minFaceSizeRatio) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.faceTooSmall,
        confidence: mlResult.confidence,
      );
    }

    return mlResult;
  }

  /// Apply secondary photo specific rules
  PhotoPrescreenResult _applySecondaryPhotoRules(
    PhotoPrescreenResult mlResult,
  ) {
    final faceAnalysis = mlResult.faceAnalysis;
    final bodyAnalysis = mlResult.bodyAnalysis;

    // No local ML data: cannot enforce person checks locally; defer to Gemini.
    if (faceAnalysis == null || bodyAnalysis == null) {
      return mlResult;
    }

    // A gallery photo needs at least one complete face or full body. This
    // deliberately allows groups and distant people, but not a fragment such
    // as a partial head in an otherwise empty room.
    if (!faceAnalysis.completeFaceDetected &&
        !bodyAnalysis.completeBodyDetected) {
      return PhotoPrescreenResult.failed(
        reason: PrescreenFailureReason.noFaceOrBody,
        confidence: mlResult.confidence,
      );
    }

    // Do not impose face count, size, position, crop, or confidence rules on
    // gallery photos. One detector-recognized person is enough, whether the
    // photo shows an individual or a group, faces/bodies, and near/far views.
    // Gemini performs the final content and authenticity review.
    return mlResult;
  }
}

/// Provider for photo prescreen service
final photoPrescreenServiceProvider = Provider<PhotoPrescreenService>(
  (ref) => PhotoPrescreenService(),
);
