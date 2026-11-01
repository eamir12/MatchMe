import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/meetup_selfie_contract.dart';
import 'package:matchme/services/meetup_selfie_windows.dart' as windows;
import 'package:matchme/widgets/custom_camera_widget.dart';

export 'meetup_selfie_contract.dart';

/// Front-camera-only selfie for the Spot me card. Mobile uses the native
/// camera plugin; Windows uses a WebView2 page because the camera plugin has
/// no Windows implementation. Other desktop platforms report `unavailable`
/// so the composer can fall back to outfit details and a note.
Future<MeetupSelfieResult> captureMeetupSelfie({
  required BuildContext context,
  required LocalizationState l10n,
}) async {
  try {
    if (Platform.isWindows) {
      return await windows.captureMeetupSelfieWindows(
        context: context,
        l10n: l10n,
      );
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const MeetupSelfieResult.failed('unavailable');
    }

    String? error;
    final bytes = await showCustomCamera(
      context: context,
      useFrontCamera: true,
      frontOnly: true,
      onCameraError: (code) => error = code,
    );
    if (bytes != null && bytes.isNotEmpty) {
      return MeetupSelfieResult(bytes: bytes);
    }
    if (error != null) return MeetupSelfieResult.failed(error!);
    return const MeetupSelfieResult.cancelled();
  } catch (_) {
    return const MeetupSelfieResult.failed('failed');
  }
}
