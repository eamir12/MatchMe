// Primary-photo selfie capture via the shared MediaPipe capture page.
//
// Runs the same live capture UX as the profile-verification selfie, but in
// face-only mode (gesture code `FACE_ONLY`, see assets/verification_capture):
// the face oval turns green only while a single clear face is inside it, the
// checklist tracks face visibility, and the photo is captured automatically
// once the face criteria hold steady. A body-only shot (e.g. someone laying
// on a beach) can never satisfy the gate, so it can never be captured as the
// primary photo through this path. Returns the JPEG bytes, or null when the
// user backs out / capture fails.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/verification_mediapipe.dart';

/// Gesture code that switches the capture page to primary-selfie face-only
/// mode (no hand gesture ROI, readiness gated purely on the face).
const String primarySelfieFaceOnlyGestureCode = 'FACE_ONLY';

Future<Uint8List?> openPrimarySelfieCapture({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  final l10n = ref.read(localizationProvider);
  final completer = Completer<Uint8List?>();
  void completeOnce(Uint8List? bytes) {
    if (!completer.isCompleted) completer.complete(bytes);
  }

  openMediaPipeVerificationCapture(
    gestureCode: primarySelfieFaceOnlyGestureCode,
    gestureLabel: l10n.getString('primarySelfieCaptureInstruction'),
    gestureDescription: l10n.getString('primarySelfieCaptureDescription'),
    localeCode: l10n.currentLocale.languageCode,
    captureStrings: <String, String>{
      // Face-only overrides only. The primary photo never asks for a hand
      // gesture, so none of the verification gesture/hand vocabulary
      // (ShowGesture, PositionHand, UseCorrectHand, HandLeft/Right,
      // hand/gesture checklist rows) is forwarded to the capture page — it
      // would only ever describe a step that does not exist in this flow.
      'verificationCaptureLoading': l10n.getString(
        'primarySelfieCaptureLoading',
      ),
      'verificationCaptureInstruction': l10n.getString(
        'primarySelfieCaptureInstruction',
      ),
      'verificationCaptureStatusShowFace': l10n.getString(
        'verificationCaptureStatusShowFace',
      ),
      'verificationCaptureStatusAlignFace': l10n.getString(
        'verificationCaptureStatusAlignFace',
      ),
      'verificationCaptureStatusHoldSteady': l10n.getString(
        'verificationCaptureStatusHoldSteady',
      ),
      'verificationCaptureStatusCapturingBestFrame': l10n.getString(
        'verificationCaptureStatusCapturingBestFrame',
      ),
      // Page fallback for this key is "Gesture detected…" — always override
      // it so the ready line can never surface verification wording.
      'verificationCaptureStatusGestureDetected': l10n.getString(
        'verificationCaptureStatusGestureDetected',
      ),
      'verificationCaptureChecklistFaceVisible': l10n.getString(
        'verificationCaptureChecklistFaceVisible',
      ),
      'verificationCaptureCameraOrModelError': l10n.getString(
        'verificationCaptureCameraOrModelError',
      ),
      'verificationCaptureFailedToLoad': l10n.getString(
        'verificationCaptureFailedToLoad',
      ),
      'verificationCaptureCameraPermissionDenied': l10n.getString(
        'verificationCaptureCameraPermissionDenied',
      ),
      'verificationCaptureRetry': l10n.containsKey('verificationCaptureRetry')
          ? l10n.getString('verificationCaptureRetry')
          : 'Retry',
    },
    context: context,
    onPhoto: completeOnce,
    onClose: () => completeOnce(null),
  );

  return completer.future;
}
