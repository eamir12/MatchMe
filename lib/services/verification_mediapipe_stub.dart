// Unused when IO implementation is selected; kept for API compatibility.
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// No-op stub (used only when web is selected via conditional export).
void openMediaPipeVerificationCapture({
  required String gestureCode,
  required void Function(Uint8List?) onPhoto,
  String? gestureLabel,
  Map<String, String>? captureStrings,
  Uint8List? inputImageBytes,
  BuildContext? context,
}) {
  onPhoto(null);
}
