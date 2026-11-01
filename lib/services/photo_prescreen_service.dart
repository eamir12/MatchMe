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
import 'photo_prescreen_windows_stub.dart'
    if (dart.library.io) 'photo_prescreen_windows.dart';

/// Result of photo prescreening analysis
class PhotoPrescreenResult {
  final bool passed;
  final PrescreenFailureReason? failureReason;

  /// Every failed rule, in display order. [failureReason] is the first entry —
  /// kept for non-UI callers; the failure dialog renders all of them so one
  /// retake can fix everything at once.
  final List<PrescreenFailureReason> failureReasons;
  final double confidence;
  final FaceAnalysis? faceAnalysis;
  final BodyAnalysis? bodyAnalysis;
  final TextAnalysis? textAnalysis;
  final ImageQuality? imageQuality;

  /// Text block overlapping the face region (native detectors only).
  final bool textOverFace;

  /// Object (hand/salient rectangle) overlapping the face region.
  final bool objectOverFace;

  /// Card/document visible near the face but not clearly covering it.
  final bool documentNearFace;

  /// Normalized top-left-origin box of the largest detected face, when the
  /// native analyzer reported one. Used to draw the overlay in the failure
  /// dialog.
  final Map<String, double>? faceBox;

  /// Normalized {x,y,w,h,label} boxes locating the problem regions (text
  /// blocks or objects over the face), for the failure dialog overlay.
  final List<Map<String, dynamic>> issueBoxes;

  /// 64-bit dHash of the analyzed image, for perceptual duplicate checks.
  final String perceptualHash;

  /// Native analyzer contract version reported by this build (absent on
  /// web/desktop/stale binaries). Shown in the failure dialog's details so a
  /// stale Kotlin/Swift binary is identifiable from a screenshot.
  final int? nativePrescreenVersion;
  final String? errorMessage;

  const PhotoPrescreenResult({
    required this.passed,
    this.failureReason,
    this.failureReasons = const [],
    required this.confidence,
    this.faceAnalysis,
    this.bodyAnalysis,
    this.textAnalysis,
    this.imageQuality,
    this.textOverFace = false,
    this.objectOverFace = false,
    this.documentNearFace = false,
    this.faceBox,
    this.issueBoxes = const [],
    this.perceptualHash = '',
    this.nativePrescreenVersion,
    this.errorMessage,
  });

  factory PhotoPrescreenResult.passedWithConfidence({
    required double confidence,
    FaceAnalysis? faceAnalysis,
    BodyAnalysis? bodyAnalysis,
    TextAnalysis? textAnalysis,
    ImageQuality? imageQuality,
    bool textOverFace = false,
    bool objectOverFace = false,
    bool documentNearFace = false,
    Map<String, double>? faceBox,
    List<Map<String, dynamic>> issueBoxes = const [],
    String perceptualHash = '',
    int? nativePrescreenVersion,
  }) {
    return PhotoPrescreenResult(
      passed: true,
      confidence: confidence,
      faceAnalysis: faceAnalysis,
      bodyAnalysis: bodyAnalysis,
      textAnalysis: textAnalysis,
      imageQuality: imageQuality,
      textOverFace: textOverFace,
      objectOverFace: objectOverFace,
      documentNearFace: documentNearFace,
      faceBox: faceBox,
      issueBoxes: issueBoxes,
      perceptualHash: perceptualHash,
      nativePrescreenVersion: nativePrescreenVersion,
    );
  }

  factory PhotoPrescreenResult.failed({
    required List<PrescreenFailureReason> reasons,
    String? errorMessage,
    double confidence = 0.0,
    Map<String, double>? faceBox,
    List<Map<String, dynamic>> issueBoxes = const [],
    ImageQuality? imageQuality,
    FaceAnalysis? faceAnalysis,
    BodyAnalysis? bodyAnalysis,
    TextAnalysis? textAnalysis,
    int? nativePrescreenVersion,
  }) {
    final ordered = orderPrescreenFailures(reasons);
    return PhotoPrescreenResult(
      passed: false,
      failureReason: ordered.isEmpty ? null : ordered.first,
      failureReasons: ordered,
      confidence: confidence,
      faceBox: faceBox,
      issueBoxes: issueBoxes,
      imageQuality: imageQuality,
      faceAnalysis: faceAnalysis,
      bodyAnalysis: bodyAnalysis,
      textAnalysis: textAnalysis,
      nativePrescreenVersion: nativePrescreenVersion,
      errorMessage: errorMessage,
    );
  }
}

/// Canonical display order for accumulated prescreen failures (most
/// fundamental problem first).
const List<PrescreenFailureReason> _prescreenFailureOrder = [
  PrescreenFailureReason.duplicatePhoto,
  PrescreenFailureReason.invalidFormat,
  PrescreenFailureReason.fileTooLarge,
  PrescreenFailureReason.fileTooSmall,
  PrescreenFailureReason.resolutionTooLow,
  PrescreenFailureReason.aspectRatioInvalid,
  PrescreenFailureReason.imageCorrupted,
  PrescreenFailureReason.noFaceOrBody,
  PrescreenFailureReason.noFaceDetected,
  PrescreenFailureReason.multipleFaces,
  PrescreenFailureReason.multiplePeople,
  PrescreenFailureReason.personCheckUnavailable,
  PrescreenFailureReason.bodyShotNotAllowed,
  PrescreenFailureReason.faceNotVisible,
  PrescreenFailureReason.faceTooSmall,
  PrescreenFailureReason.eyesClosed,
  PrescreenFailureReason.textOverFace,
  PrescreenFailureReason.objectOverFace,
  PrescreenFailureReason.documentDetected,
  PrescreenFailureReason.textDetected,
  PrescreenFailureReason.imageTooBlurry,
  PrescreenFailureReason.imageTooDark,
  PrescreenFailureReason.imageTooBright,
];

List<PrescreenFailureReason> orderPrescreenFailures(
  Iterable<PrescreenFailureReason> reasons,
) {
  final seen = reasons.toSet();
  final ordered = _prescreenFailureOrder.where(seen.contains).toList();
  // Keep any reason not yet in the canonical list (defensive) at the end.
  ordered.addAll(seen.difference(ordered.toSet()));
  return ordered;
}

/// Single-person gate for the Spot me selfie: pass with exactly one person,
/// whether the detector found a face, a body, or both. A second face or body
/// fails the gate. Platform body counts can be conservative (Android's pose
/// model is single-person), in which case group detection relies on the face
/// count.
List<PrescreenFailureReason> singlePersonGateFailures({
  required int faceCount,
  required int bodyCount,
}) {
  final failures = <PrescreenFailureReason>[];
  if (faceCount > 1 || bodyCount > 1) {
    failures.add(PrescreenFailureReason.multiplePeople);
  }
  if (faceCount < 1 && bodyCount < 1) {
    failures.add(PrescreenFailureReason.noFaceOrBody);
  }
  return failures;
}

/// Hamming distance between two 64-char dHash bit strings. Returns a large
/// sentinel when either hash is missing so comparisons fail closed.
int perceptualHashDistance(String a, String b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 64;
  var distance = 0;
  for (var i = 0; i < a.length; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) distance++;
  }
  return distance;
}

/// On-device text analysis (ML Kit on Android, Apple Vision on iOS). Null
/// when the native detector doesn't report text metrics — the web bridge and
/// desktop have no local text detector, so those platforms defer to the
/// server-side AI unchanged.
class TextAnalysis {
  final double textContentAreaRatio;
  final double largestBlockAreaRatio;
  final double largestBlockHeightRatio;
  final double largestBlockWidthRatio;
  final int largestBlockCharCount;

  /// Normalized (0..1, top-left origin) bounding boxes of detected text
  /// blocks, for optional highlighting in the editor.
  final List<Map<String, double>> blocks;

  const TextAnalysis({
    required this.textContentAreaRatio,
    required this.largestBlockAreaRatio,
    required this.largestBlockHeightRatio,
    required this.largestBlockWidthRatio,
    required this.largestBlockCharCount,
    this.blocks = const [],
  });

  /// Substantial text = a block big enough to be a card, sign, watermark, or
  /// screenshot. Incidental text (shirt prints, distant background signs)
  /// stays below these thresholds and is left to the server-side AI, which
  /// judges context.
  bool get hasSubstantialText =>
      (largestBlockAreaRatio >= 0.05 && largestBlockCharCount >= 3) ||
      (largestBlockHeightRatio >= 0.06 &&
          largestBlockWidthRatio >= 0.15 &&
          largestBlockCharCount >= 12);
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

  /// Worst-case head rotation in degrees as reported by the native detector
  /// (iOS Vision roll/yaw, ML Kit euler angles). Null on platforms that do
  /// not report it. Diagnostics for the failure dialog — never a rule itself.
  final double? headTiltDegrees;

  /// Both eyes of the largest face are confidently closed (Android ML Kit
  /// eye classification). False on platforms without classification.
  final bool bothEyesClosed;

  const FaceAnalysis({
    required this.faceDetected,
    required this.faceCount,
    required this.faceConfidence,
    required this.faceSizeRatio,
    required this.facePositionedCenter,
    required this.faceTouchesImageEdge,
    required this.completeFaceDetected,
    required this.faceObstructed,
    this.headTiltDegrees,
    this.bothEyesClosed = false,
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

  /// Bodies detected in the frame. Android's ML Kit pose model is
  /// single-person, so it reports at most 1; iOS Vision and the web
  /// PoseLandmarker can report more. Platforms that do not report a count
  /// fall back to "1 when a body was detected".
  final int bodyCount;

  const BodyAnalysis({
    required this.bodyDetected,
    required this.bodyConfidence,
    required this.upperBodyOnly,
    required this.fullBodyVisible,
    required this.completeBodyDetected,
    required this.bodyCount,
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
    case PrescreenFailureReason.multiplePeople:
      return 'photoErrorMultiplePeople';
    case PrescreenFailureReason.personCheckUnavailable:
      return 'photoErrorPersonCheckUnavailable';
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
    case PrescreenFailureReason.textDetected:
      return 'photoErrorTextDetected';
    case PrescreenFailureReason.textOverFace:
      return 'photoErrorTextOverFace';
    case PrescreenFailureReason.objectOverFace:
      return 'photoErrorObjectOverFace';
    case PrescreenFailureReason.documentDetected:
      return 'photoErrorDocumentDetected';
    case PrescreenFailureReason.eyesClosed:
      return 'photoErrorEyesClosed';
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
  // A substantial text block (card, sign, watermark, screenshot) was detected
  // on-device. Both photo kinds reject these: primary prompts forbid any
  // visible text, and secondary rejects watermarks/screenshots.
  textDetected,
  // Text overlapping the face region — a card/sign held over the face. This
  // is a fraud signal (documents held to the face) and an occlusion signal,
  // so it rejects regardless of recognized character count or block size.
  textOverFace,
  // An object (hand holding something, salient rectangle) overlaps the face
  // region — same fraud/occlusion reasoning as [textOverFace] but caught
  // without OCR, so low-contrast unreadable cards are still rejected.
  objectOverFace,
  // A card/document is visible near the face but not clearly covering it.
  // Documents are not allowed in photos regardless of position; the message
  // reflects that instead of claiming the face is covered.
  documentDetected,
  // Both eyes of the primary subject are confidently closed.
  eyesClosed,
  // Primary-photo-only reasons: the first photo must be a face-only selfie
  // with exactly one face. Body-only shots (e.g. someone laying on a beach)
  // must never pass the primary prescreen, even when a body is detected.
  noFaceDetected,
  bodyShotNotAllowed,
  // Single-person gate (Spot me selfie): either the face count or the body
  // count exceeded one, so someone else is in the frame. Kept distinct from
  // [multipleFaces] because a second body may be the only signal.
  multiplePeople,
  // Single-person gate could not run: no local detector on this platform or
  // the detector failed. The gate fails closed instead of sharing an
  // unchecked photo.
  personCheckUnavailable,
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

  /// Whole-frame brightness floor, checked before the face region is known.
  /// Below this the entire photo is black; the face-region rule
  /// ([minBrightness]) runs afterwards so a dark background with a lit face
  /// is not rejected.
  final double minGlobalBrightness;

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
    this.minGlobalBrightness = 0.12,
  });

  /// Config for primary photos (stricter requirements)
  static const PrescreenConfig primaryPhoto = PrescreenConfig(
    minFileSize: 20480, // 20KB
    maxFileSize: 10485760, // 10MB
    minResolution: 400,
    minAspectRatio: 0.33,
    maxAspectRatio: 3.0,
    minFaceSizeRatio: 0.15,
    // 0.65, not 0.75: Apple Vision's confidence is poorly calibrated for
    // dim or low-angle faces and rejected sharp, clearly visible selfies as
    // "face not clearly visible". Face size, crop, and blur are enforced by
    // their own rules and do not depend on this score.
    minFaceConfidence: 0.65,
    minBodyConfidence: 0.6,
    minBlurScore: 0.4,
    minBrightness: 0.2,
    maxBrightness: 0.9,
    minGlobalBrightness: 0.12,
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

  /// 64-bit dHash bit string ('0'/'1' chars) for perceptual duplicate
  /// detection. Empty when hashing failed.
  final String perceptualHash;

  const _DecodedImageMetrics({
    required this.width,
    required this.height,
    required this.blurScore,
    required this.brightnessScore,
    this.perceptualHash = '',
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
    perceptualHash: _calculatePerceptualHashSync(image),
  );
}

/// dHash: downscale to 9x8 and compare horizontally adjacent luminance,
/// producing a 64-char bit string. Compared with a Hamming distance this
/// survives re-encoding/resizing that would break the exact-byte MD5 check.
/// Kept as a bit string (not an int) so JS builds behave identically to VM
/// builds — 32-bit `<<` truncation in dart2js would silently fold the hash.
String _calculatePerceptualHashSync(img.Image image) {
  try {
    final small = img.copyResize(image, width: 9, height: 8);
    final bits = StringBuffer();
    double luma(int x, int y) {
      final p = small.getPixel(x, y);
      return (p.r + p.g + p.b) / 3;
    }

    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        bits.write(luma(x, y) > luma(x + 1, y) ? '1' : '0');
      }
    }
    return bits.toString();
  } catch (_) {
    return '';
  }
}

/// Standalone perceptual hash for callers that only need the hash (e.g. the
/// wizard recording a photo it just accepted).
Future<String> computePerceptualHash(Uint8List bytes) async {
  return compute(_computePerceptualHashIsolate, bytes);
}

String _computePerceptualHashIsolate(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return '';
    return _calculatePerceptualHashSync(image);
  } catch (_) {
    return '';
  }
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

/// Normalized region used for face brightness sampling: the detector's face
/// box grown by [margin] of its own size on every side (the skin around the
/// face counts as lit too), clamped to the frame. Null when no usable face
/// box exists — callers then fall back to the global brightness score.
@visibleForTesting
Map<String, double>? faceRegionRect(
  Map<String, double>? faceBox, {
  double margin = 0.15,
}) {
  if (faceBox == null) return null;
  final x = faceBox['x'] ?? 0;
  final y = faceBox['y'] ?? 0;
  final w = faceBox['w'] ?? 0;
  final h = faceBox['h'] ?? 0;
  if (w <= 0 || h <= 0) return null;
  final dx = w * margin;
  final dy = h * margin;
  final left = (x - dx).clamp(0.0, 1.0);
  final top = (y - dy).clamp(0.0, 1.0);
  final right = (x + w + dx).clamp(0.0, 1.0);
  final bottom = (y + h + dy).clamp(0.0, 1.0);
  if (right - left <= 0 || bottom - top <= 0) return null;
  return {'x': left, 'y': top, 'w': right - left, 'h': bottom - top};
}

/// Mean brightness (0..1) of [rect] (normalized) inside [bytes], decoded off
/// the UI thread. Only called when the global score is already near the
/// threshold, so the extra decode cost is limited to dim photos.
Future<double> _faceRegionBrightness(
  Uint8List bytes,
  Map<String, double> rect,
) async {
  try {
    return await compute(_faceRegionBrightnessIsolate, (bytes, rect));
  } catch (_) {
    // Fail closed: the caller only reaches here when the frame is already
    // below the global threshold, so treating it as dark is conservative.
    return 0.0;
  }
}

double _faceRegionBrightnessIsolate((Uint8List, Map<String, double>) args) {
  final (bytes, rect) = args;
  final image = img.decodeImage(bytes);
  if (image == null) return 0.0;
  final left = (rect['x']! * image.width).round().clamp(0, image.width - 1);
  final top = (rect['y']! * image.height).round().clamp(0, image.height - 1);
  final right = ((rect['x']! + rect['w']!) * image.width).round().clamp(
    left + 1,
    image.width,
  );
  final bottom = ((rect['y']! + rect['h']!) * image.height).round().clamp(
    top + 1,
    image.height,
  );
  var total = 0.0;
  var count = 0;
  for (var y = top; y < bottom; y += 4) {
    for (var x = left; x < right; x += 4) {
      final pixel = image.getPixel(x, y);
      total += (pixel.r + pixel.g + pixel.b) / (3 * 255);
      count++;
    }
  }
  if (count == 0) return 0.0;
  return (total / count).clamp(0.0, 1.0);
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
  /// [existingPerceptualHashes] - dHash bit strings of session photos; a
  ///   Hamming distance of <= 10 flags a re-encoded duplicate of an already
  ///   added photo (catches what the exact-byte MD5 check cannot).
  /// [singlePersonOnly] - run the Spot me selfie gate instead of profile
  ///   rules: pass when exactly one face or one body is detected, reject a
  ///   second person, and ignore text/quality/over-face profile rules (those
  ///   exist to pre-approve profile photos; a meet-up selfie is judged only
  ///   on who is in it). Fails closed when no local detector is available
  ///   because there is no server-side AI fallback for this gate.
  ///
  /// Every rule runs and all failures are reported together, so the user can
  /// fix everything in a single retake instead of discovering issues one at a
  /// time. Only structural failures (unreadable/oversized file) abort early.
  Future<PhotoPrescreenResult> prescreenPhoto(
    Uint8List bytes, {
    bool isPrimary = false,
    Set<String>? existingHashes,
    Set<String>? existingPerceptualHashes,
    bool singlePersonOnly = false,
  }) async {
    final config = isPrimary
        ? PrescreenConfig.primaryPhoto
        : PrescreenConfig.secondaryPhoto;

    // 1. Basic file validation — fail fast: nothing downstream is meaningful
    //    for an unreadable or oversized file.
    final fileValidation = _validateFile(bytes, config);
    if (!fileValidation.passed) {
      return fileValidation;
    }

    final failures = <PrescreenFailureReason>{};

    // 2. Duplicate checks: exact-byte and perceptual.
    String candidateHash = '';
    if ((existingHashes != null && existingHashes.isNotEmpty) ||
        (existingPerceptualHashes != null &&
            existingPerceptualHashes.isNotEmpty)) {
      candidateHash = await compute(_computeImageHashIsolate, bytes);
      if (existingHashes != null &&
          existingHashes.isNotEmpty &&
          existingHashes.contains(candidateHash)) {
        failures.add(PrescreenFailureReason.duplicatePhoto);
      }
    }

    // 3. Image metrics (single decode pass, off the UI thread)
    final metrics = await compute(_computeImageMetricsIsolate, bytes);
    if (metrics.width == 0 || metrics.height == 0) {
      return PhotoPrescreenResult.failed(
        reasons: const [PrescreenFailureReason.imageCorrupted],
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

    if (!singlePersonOnly &&
        (metrics.width < config.minResolution ||
            metrics.height < config.minResolution)) {
      failures.add(PrescreenFailureReason.resolutionTooLow);
    }
    if (!singlePersonOnly &&
        (quality.aspectRatio < config.minAspectRatio ||
            quality.aspectRatio > config.maxAspectRatio)) {
      failures.add(PrescreenFailureReason.aspectRatioInvalid);
    }
    // The primary image is a clear face photo. Gallery images can be wide,
    // dark, distant, or intentionally stylized, so Gemini—not a coarse local
    // quality heuristic—is the authority for whether they are usable.
    if (isPrimary) {
      if (quality.blurScore < config.minBlurScore) {
        failures.add(PrescreenFailureReason.imageTooBlurry);
      }
      // Global floor: reject only a nearly black frame here. The real
      // "too dark" verdict needs the face region — a dark background with a
      // well-lit face is perfectly usable — and runs after the detector
      // reports where the face is (see step 7.5).
      if (quality.brightnessScore < config.minGlobalBrightness) {
        failures.add(PrescreenFailureReason.imageTooDark);
      }
      if (quality.brightnessScore > config.maxBrightness) {
        failures.add(PrescreenFailureReason.imageTooBright);
      }
    }

    // Perceptual duplicate: near-identical to a photo already added this
    // session even after re-encoding, cropping to near-identical framing, or
    // screenshotting.
    if (existingPerceptualHashes != null &&
        existingPerceptualHashes.isNotEmpty &&
        metrics.perceptualHash.isNotEmpty &&
        !failures.contains(PrescreenFailureReason.duplicatePhoto)) {
      for (final existing in existingPerceptualHashes) {
        if (perceptualHashDistance(metrics.perceptualHash, existing) <= 10) {
          failures.add(PrescreenFailureReason.duplicatePhoto);
          break;
        }
      }
    }

    // 4. Native ML detection (if available)
    final mlResult = await _performNativeDetection(bytes, config);
    if (!mlResult.passed) {
      return mlResult;
    }

    final faceAnalysis = mlResult.faceAnalysis;
    final bodyAnalysis = mlResult.bodyAnalysis;
    final hasNativeData = faceAnalysis != null && bodyAnalysis != null;

    // 4.5. Spot me selfie gate: exactly one person, face or body. Runs
    //      instead of the profile rules below — a meet-up selfie is not a
    //      profile photo, so text/blur/over-face/size rules do not apply.
    //      Fails closed when the platform has no local detector (desktop,
    //      unavailable web bridge), because no server-side AI reviews this.
    if (singlePersonOnly) {
      if (!hasNativeData) {
        debugPrint(
          '[photoPrescreen] single-person gate unavailable '
          '(no local detector) nativeV=${mlResult.nativePrescreenVersion}',
        );
        return PhotoPrescreenResult.failed(
          reasons: const [PrescreenFailureReason.personCheckUnavailable],
          imageQuality: quality,
          nativePrescreenVersion: mlResult.nativePrescreenVersion,
        );
      }

      final gate = singlePersonGateFailures(
        faceCount: faceAnalysis.faceCount,
        bodyCount: bodyAnalysis.bodyCount,
      );
      if (gate.isEmpty) {
        return PhotoPrescreenResult.passedWithConfidence(
          confidence: mlResult.confidence,
          faceAnalysis: faceAnalysis,
          bodyAnalysis: bodyAnalysis,
          imageQuality: quality,
          faceBox: mlResult.faceBox,
          issueBoxes: mlResult.issueBoxes,
          perceptualHash: metrics.perceptualHash,
          nativePrescreenVersion: mlResult.nativePrescreenVersion,
        );
      }

      debugPrint(
        '[photoPrescreen] single-person gate failed '
        'reasons=${gate.join(',')} '
        'faces=${faceAnalysis.faceCount} '
        'bodies=${bodyAnalysis.bodyCount} '
        'nativeV=${mlResult.nativePrescreenVersion}',
      );
      return PhotoPrescreenResult.failed(
        reasons: gate,
        confidence: mlResult.confidence,
        faceBox: mlResult.faceBox,
        issueBoxes: mlResult.issueBoxes,
        imageQuality: quality,
        faceAnalysis: faceAnalysis,
        bodyAnalysis: bodyAnalysis,
        nativePrescreenVersion: mlResult.nativePrescreenVersion,
      );
    }

    // 5. On-device text gate: cards, signs, watermarks, screenshots caught
    // before upload — zero AI calls for the most common bad photo. Only runs
    // when the native detector reported text metrics; web/desktop and older
    // native builds have none, and anything below the thresholds is left to
    // the server-side AI to judge in context.
    final textAnalysis = mlResult.textAnalysis;
    if (textAnalysis != null && textAnalysis.hasSubstantialText) {
      failures.add(PrescreenFailureReason.textDetected);
    }

    // 6. Text or objects overlapping the face: a card/document held over the
    // face is both an occlusion and a fraud signal (unreadable low-contrast
    // cards defeat OCR, so this must not depend on [hasSubstantialText]).
    // Primary only — gallery photos defer these judgements to Gemini.
    if (isPrimary && faceAnalysis != null && faceAnalysis.faceDetected) {
      if (mlResult.textOverFace) {
        failures.add(PrescreenFailureReason.textOverFace);
      }
      if (mlResult.objectOverFace) {
        failures.add(PrescreenFailureReason.objectOverFace);
      } else if (mlResult.documentNearFace) {
        // The document is visible near the face but not clearly covering it.
        // Still rejected — documents are not allowed in photos — but the
        // message must not claim the face is covered.
        failures.add(PrescreenFailureReason.documentDetected);
      }
      if (faceAnalysis.bothEyesClosed) {
        failures.add(PrescreenFailureReason.eyesClosed);
      }
    }

    // 7. Photo-type specific person rules.
    if (hasNativeData) {
      if (isPrimary) {
        _collectPrimaryPhotoFailures(
          failures,
          faceAnalysis,
          bodyAnalysis,
          config,
        );
      } else {
        _collectSecondaryPhotoFailures(failures, faceAnalysis, bodyAnalysis);
      }
    }

    // 7.5. Face-region darkness: the global score is dragged down by dark
    // backgrounds, so a well-lit face in a dim room passes while a genuinely
    // underexposed face still fails. Only runs when the global score is
    // below the face threshold — a bright frame skips the extra decode.
    if (isPrimary &&
        !failures.contains(PrescreenFailureReason.imageTooDark) &&
        quality.brightnessScore < config.minBrightness) {
      final faceRect = faceRegionRect(mlResult.faceBox);
      final faceScore = faceRect == null
          ? quality.brightnessScore
          : await _faceRegionBrightness(bytes, faceRect);
      if (faceScore < config.minBrightness) {
        failures.add(PrescreenFailureReason.imageTooDark);
      }
    }

    if (failures.isEmpty) {
      return PhotoPrescreenResult.passedWithConfidence(
        confidence: mlResult.confidence,
        faceAnalysis: faceAnalysis,
        bodyAnalysis: bodyAnalysis,
        textAnalysis: textAnalysis,
        imageQuality: quality,
        textOverFace: mlResult.textOverFace,
        objectOverFace: mlResult.objectOverFace,
        perceptualHash: metrics.perceptualHash,
        nativePrescreenVersion: mlResult.nativePrescreenVersion,
      );
    }

    // Diagnostics: one structured line per rejected photo so regressions
    // (e.g. background décor reported as documents) are visible without a
    // device attached. The failure dialog shows the same numbers under
    // "Details".
    debugPrint(
      '[photoPrescreen] failed isPrimary=$isPrimary '
      'reasons=${failures.join(',')} '
      'brightness=${quality.brightnessScore.toStringAsFixed(2)} '
      'blur=${quality.blurScore.toStringAsFixed(2)} '
      'faceConfidence=${faceAnalysis?.faceConfidence.toStringAsFixed(2)} '
      'headTilt=${faceAnalysis?.headTiltDegrees?.toStringAsFixed(0)} '
      'issueBoxes=${mlResult.issueBoxes.length} '
      'nativeV=${mlResult.nativePrescreenVersion}',
    );

    // Propagate the problem-region boxes so the failure dialog can draw the
    // overlay on the exact spots (face + offending text/object regions).
    return PhotoPrescreenResult.failed(
      reasons: failures.toList(),
      confidence: mlResult.confidence,
      faceBox: mlResult.faceBox,
      issueBoxes: mlResult.issueBoxes,
      imageQuality: quality,
      faceAnalysis: faceAnalysis,
      bodyAnalysis: bodyAnalysis,
      textAnalysis: textAnalysis,
      nativePrescreenVersion: mlResult.nativePrescreenVersion,
    );
  }

  /// Validate basic file properties
  PhotoPrescreenResult _validateFile(Uint8List bytes, PrescreenConfig config) {
    if (bytes.isEmpty) {
      return PhotoPrescreenResult.failed(
        reasons: const [PrescreenFailureReason.fileTooSmall],
      );
    }

    if (bytes.length < config.minFileSize) {
      return PhotoPrescreenResult.failed(
        reasons: const [PrescreenFailureReason.fileTooSmall],
      );
    }

    if (bytes.length > config.maxFileSize) {
      return PhotoPrescreenResult.failed(
        reasons: const [PrescreenFailureReason.fileTooLarge],
      );
    }

    final format = _detectFormat(bytes);
    if (!_supportedFormats.contains(format)) {
      return PhotoPrescreenResult.failed(
        reasons: const [PrescreenFailureReason.invalidFormat],
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
  /// Windows runs that same detector in a headless WebView2 (see
  /// photo_prescreen_windows.dart). Linux/macOS have no local ML. Any
  /// unavailable/failed detector falls back to Gemini validation instead of
  /// falsely rejecting.
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
    if (Platform.isWindows) {
      final windowsResult = await _performWindowsDetection(bytes, config);
      if (windowsResult != null) return windowsResult;
      // Runtime/models unavailable: skip person checks, Gemini still validates.
      return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
    }
    if (Platform.isLinux || Platform.isMacOS) {
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

      // Diagnostics: the native contract changes with app releases, but
      // Kotlin/Swift never arrive via hot reload — log the version so a stale
      // binary (all person/text checks silently absent) is visible in logs.
      final nativeVersion = (result['prescreenVersion'] as num?)?.toInt() ?? 0;
      debugPrint('[photoPrescreen] native analyzer version=$nativeVersion');

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

  /// Runs the same MediaPipe detector in the Windows WebView2 host, with a
  /// bounded wait for the first-run model download. Returns null when the
  /// runtime, page, or models are unavailable.
  Future<PhotoPrescreenResult?> _performWindowsDetection(
    Uint8List bytes,
    PrescreenConfig config,
  ) async {
    try {
      final map = await analyzePhotoPrescreenWindows(
        bytes,
      ).timeout(const Duration(seconds: 30));
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
              headTiltDegrees: (result['headTiltDegrees'] as num?)?.toDouble(),
              bothEyesClosed: result['bothEyesClosed'] == true,
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
        // Older native binaries do not report a count; presence still means
        // one body, which is all Android's single-pose model can detect.
        bodyCount:
            (result['bodyCount'] as num?)?.toInt() ?? (containsBody ? 1 : 0),
      );

      // Text metrics are optional: absent on the web bridge, desktop, and
      // native builds older than the text-recognition rollout.
      final textContentAreaRatio = (result['textContentAreaRatio'] as num?)
          ?.toDouble();
      TextAnalysis? textAnalysis;
      if (textContentAreaRatio != null) {
        final rawBlocks = result['textBlocks'];
        final blocks = <Map<String, double>>[];
        if (rawBlocks is List) {
          for (final entry in rawBlocks) {
            if (entry is Map) {
              blocks.add({
                'x': (entry['x'] as num?)?.toDouble() ?? 0.0,
                'y': (entry['y'] as num?)?.toDouble() ?? 0.0,
                'w': (entry['w'] as num?)?.toDouble() ?? 0.0,
                'h': (entry['h'] as num?)?.toDouble() ?? 0.0,
              });
            }
          }
        }
        textAnalysis = TextAnalysis(
          textContentAreaRatio: textContentAreaRatio,
          largestBlockAreaRatio:
              (result['largestTextAreaRatio'] as num?)?.toDouble() ?? 0.0,
          largestBlockHeightRatio:
              (result['largestTextHeightRatio'] as num?)?.toDouble() ?? 0.0,
          largestBlockWidthRatio:
              (result['largestTextWidthRatio'] as num?)?.toDouble() ?? 0.0,
          largestBlockCharCount:
              (result['largestTextCharCount'] as num?)?.toInt() ?? 0,
          blocks: blocks,
        );
      }

      final confidence = _calculateOverallConfidence(
        faceAnalysis,
        bodyAnalysis,
      );

      return PhotoPrescreenResult.passedWithConfidence(
        confidence: confidence,
        faceAnalysis: faceAnalysis,
        bodyAnalysis: bodyAnalysis,
        textAnalysis: textAnalysis,
        textOverFace: result['textOverFace'] == true,
        objectOverFace: result['objectOverFace'] == true,
        documentNearFace: result['documentNearFace'] == true,
        faceBox: _parseNormalizedBox(result['faceBox']),
        issueBoxes: _parseIssueBoxes(result['issueBoxes']),
        nativePrescreenVersion: (result['prescreenVersion'] as num?)?.toInt(),
      );
    } catch (_) {
      return PhotoPrescreenResult.passedWithConfidence(confidence: 0.0);
    }
  }

  /// Parses a normalized {x,y,w,h} box from the native result.
  static Map<String, double>? _parseNormalizedBox(Object? raw) {
    if (raw is! Map) return null;
    double? asDouble(Object? v) => (v is num) ? v.toDouble() : null;
    final x = asDouble(raw['x']);
    final y = asDouble(raw['y']);
    final w = asDouble(raw['w']);
    final h = asDouble(raw['h']);
    if (x == null || y == null || w == null || h == null) return null;
    if (w <= 0 || h <= 0) return null;
    return {'x': x, 'y': y, 'w': w, 'h': h};
  }

  /// Parses normalized {x,y,w,h,label} boxes from the native result.
  static List<Map<String, dynamic>> _parseIssueBoxes(Object? raw) {
    if (raw is! List) return const [];
    final boxes = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      double? asDouble(Object? v) => (v is num) ? v.toDouble() : null;
      final w = asDouble(entry['w']);
      final h = asDouble(entry['h']);
      if (w == null || h == null || w <= 0 || h <= 0) continue;
      boxes.add({
        'x': asDouble(entry['x']) ?? 0.0,
        'y': asDouble(entry['y']) ?? 0.0,
        'w': w,
        'h': h,
        'label': entry['label'] is String ? entry['label'] as String : 'text',
      });
    }
    return boxes;
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

  /// Collect primary photo rule failures.
  ///
  /// The primary (first) photo must contain exactly one face — a face-only
  /// selfie. Body-only shots (e.g. someone laying on a beach) are rejected,
  /// even when a body is detected with high confidence. When no local ML
  /// result is available (detector unavailable/failed), person checks are
  /// skipped so Gemini remains the final validator instead of crashing on a
  /// null dereference.
  void _collectPrimaryPhotoFailures(
    Set<PrescreenFailureReason> failures,
    FaceAnalysis faceAnalysis,
    BodyAnalysis bodyAnalysis,
    PrescreenConfig config,
  ) {
    // Exactly one face is required — group shots are rejected.
    if (faceAnalysis.hasMultipleFaces) {
      failures.add(PrescreenFailureReason.multipleFaces);
    }

    // No face at all: a body (or nothing) is never acceptable for primary.
    // This is the beach-photo fix — a detected body must NOT let a faceless
    // shot pass as the primary photo.
    if (!faceAnalysis.faceDetected) {
      if (bodyAnalysis.bodyDetected) {
        failures.add(PrescreenFailureReason.bodyShotNotAllowed);
      } else {
        failures.add(PrescreenFailureReason.noFaceDetected);
      }
      return;
    }

    // Defensive: exactly one face is required. Inconsistent native data
    // (faceDetected true but count != 1) is never valid for primary.
    if (faceAnalysis.faceCount == 0) {
      failures.add(PrescreenFailureReason.noFaceDetected);
      return;
    }
    if (faceAnalysis.faceCount > 1) {
      failures.add(PrescreenFailureReason.multipleFaces);
    }

    if (faceAnalysis.faceConfidence < config.minFaceConfidence) {
      failures.add(PrescreenFailureReason.faceNotVisible);
    }

    if (faceAnalysis.faceTouchesImageEdge || faceAnalysis.faceObstructed) {
      failures.add(PrescreenFailureReason.faceNotVisible);
    }

    if (faceAnalysis.faceSizeRatio < config.minFaceSizeRatio) {
      failures.add(PrescreenFailureReason.faceTooSmall);
    }
  }

  /// Collect secondary photo rule failures
  void _collectSecondaryPhotoFailures(
    Set<PrescreenFailureReason> failures,
    FaceAnalysis faceAnalysis,
    BodyAnalysis bodyAnalysis,
  ) {
    // A gallery photo needs at least one complete face or full body. This
    // deliberately allows groups and distant people, but not a fragment such
    // as a partial head in an otherwise empty room.
    if (!faceAnalysis.completeFaceDetected &&
        !bodyAnalysis.completeBodyDetected) {
      failures.add(PrescreenFailureReason.noFaceOrBody);
    }

    // Do not impose face count, size, position, crop, or confidence rules on
    // gallery photos. One detector-recognized person is enough, whether the
    // photo shows an individual or a group, faces/bodies, and near/far views.
    // Gemini performs the final content and authenticity review.
  }
}

/// Provider for photo prescreen service
final photoPrescreenServiceProvider = Provider<PhotoPrescreenService>(
  (ref) => PhotoPrescreenService(),
);
