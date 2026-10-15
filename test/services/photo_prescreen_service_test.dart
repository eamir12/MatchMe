import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matchme/services/photo_prescreen_service.dart';

/// Grayscale JPEG with per-pixel noise around [base] ± [amplitude]. The noise
/// keeps the file above the primary photo's 20KB minimum and the blur score
/// well above its threshold, so tests can control brightness independently of
/// the other quality rules. [amplitude] ≥ ~35 keeps blurScore at 1.0 after
/// JPEG encoding.
Uint8List _noiseJpeg({
  required int base,
  required int amplitude,
  int size = 480,
  int seed = 7,
}) {
  final random = Random(seed);
  final image = img.Image(width: size, height: size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final v = base + random.nextInt(amplitude * 2 + 1) - amplitude;
      final clamped = v.clamp(0, 255);
      image.setPixelRgb(x, y, clamped, clamped, clamped);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 100));
}

void main() {
  final service = PhotoPrescreenService();

  group('faceRegionRect', () {
    test('returns null without a usable face box', () {
      expect(faceRegionRect(null), isNull);
      expect(faceRegionRect({'x': 0.4, 'y': 0.3, 'w': 0, 'h': 0.3}), isNull);
      expect(faceRegionRect({'x': 0.4, 'y': 0.3, 'w': 0.2, 'h': -1}), isNull);
    });

    test('grows the face box by the margin on every side', () {
      final rect = faceRegionRect({'x': 0.4, 'y': 0.3, 'w': 0.2, 'h': 0.3})!;
      expect(rect['x'], closeTo(0.37, 1e-9));
      expect(rect['y'], closeTo(0.255, 1e-9));
      expect(rect['w'], closeTo(0.26, 1e-9));
      expect(rect['h'], closeTo(0.39, 1e-9));
    });

    test('clamps the grown region to the frame', () {
      final rect = faceRegionRect({'x': 0.0, 'y': 0.0, 'w': 0.1, 'h': 0.1})!;
      expect(rect['x'], 0.0);
      expect(rect['y'], 0.0);
      expect(rect['w'], closeTo(0.115, 1e-9));
      expect(rect['h'], closeTo(0.115, 1e-9));
    });
  });

  group('prescreenFailureL10nKey', () {
    test('maps the false-positive-sensitive reasons to their own messages', () {
      expect(
        prescreenFailureL10nKey(PrescreenFailureReason.documentDetected),
        'photoErrorDocumentDetected',
      );
      expect(
        prescreenFailureL10nKey(PrescreenFailureReason.objectOverFace),
        'photoErrorObjectOverFace',
      );
      expect(
        prescreenFailureL10nKey(PrescreenFailureReason.faceNotVisible),
        'photoErrorFaceNotVisible',
      );
      expect(
        prescreenFailureL10nKey(PrescreenFailureReason.imageTooDark),
        'photoErrorImageTooDark',
      );
    });
  });

  group('orderPrescreenFailures', () {
    test('puts face problems before document and brightness problems', () {
      final ordered = orderPrescreenFailures(const [
        PrescreenFailureReason.imageTooDark,
        PrescreenFailureReason.documentDetected,
        PrescreenFailureReason.faceNotVisible,
      ]);
      expect(ordered, const [
        PrescreenFailureReason.faceNotVisible,
        PrescreenFailureReason.documentDetected,
        PrescreenFailureReason.imageTooDark,
      ]);
    });
  });

  group('PhotoPrescreenResult.failed diagnostics', () {
    test('carries the values the failure dialog details show', () {
      const quality = ImageQuality(
        width: 480,
        height: 480,
        aspectRatio: 1.0,
        fileSize: 30000,
        format: 'jpeg',
        blurScore: 0.9,
        brightnessScore: 0.17,
      );
      const face = FaceAnalysis(
        faceDetected: true,
        faceCount: 1,
        faceConfidence: 0.62,
        faceSizeRatio: 0.3,
        facePositionedCenter: true,
        faceTouchesImageEdge: false,
        completeFaceDetected: true,
        faceObstructed: false,
        headTiltDegrees: 34,
      );
      final result = PhotoPrescreenResult.failed(
        reasons: const [PrescreenFailureReason.faceNotVisible],
        imageQuality: quality,
        faceAnalysis: face,
        nativePrescreenVersion: 5,
      );
      expect(result.imageQuality?.brightnessScore, 0.17);
      expect(result.faceAnalysis?.headTiltDegrees, 34);
      expect(result.nativePrescreenVersion, 5);
    });
  });

  group('prescreenPhoto brightness rules (primary)', () {
    test('a well-lit photo passes with its metrics attached', () async {
      final result = await service.prescreenPhoto(
        _noiseJpeg(base: 140, amplitude: 40),
        isPrimary: true,
      );
      expect(result.passed, isTrue);
      expect(result.failureReasons, isEmpty);
      expect(result.imageQuality, isNotNull);
      expect(result.imageQuality!.brightnessScore, greaterThan(0.2));
    });

    test('a nearly black photo fails on the global floor', () async {
      final result = await service.prescreenPhoto(
        _noiseJpeg(base: 16, amplitude: 40),
        isPrimary: true,
      );
      expect(result.passed, isFalse);
      expect(
        result.failureReasons,
        contains(PrescreenFailureReason.imageTooDark),
      );
      expect(result.imageQuality, isNotNull);
      expect(
        result.imageQuality!.brightnessScore,
        lessThan(PrescreenConfig.primaryPhoto.minGlobalBrightness),
      );
    });

    test(
        'a dim whole-frame photo (no native face box) still fails: '
        'the global score decides when no face region is available', () async {
      final result = await service.prescreenPhoto(
        _noiseJpeg(base: 40, amplitude: 40),
        isPrimary: true,
      );
      expect(result.passed, isFalse);
      expect(
        result.failureReasons,
        contains(PrescreenFailureReason.imageTooDark),
      );
      final score = result.imageQuality!.brightnessScore;
      expect(
        score,
        greaterThanOrEqualTo(PrescreenConfig.primaryPhoto.minGlobalBrightness),
      );
      expect(score, lessThan(PrescreenConfig.primaryPhoto.minBrightness));
    });

    test('rejects files below the primary minimum before any analysis',
        () async {
      final flat = img.Image(width: 480, height: 480);
      final tiny = Uint8List.fromList(img.encodeJpg(flat, quality: 50));
      final result = await service.prescreenPhoto(tiny, isPrimary: true);
      expect(result.passed, isFalse);
      expect(
        result.failureReasons,
        contains(PrescreenFailureReason.fileTooSmall),
      );
    });
  });
}
