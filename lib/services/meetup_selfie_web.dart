import 'package:flutter/widgets.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/meetup_selfie_contract.dart';
import 'package:matchme/web_imports.dart' as web;

export 'meetup_selfie_contract.dart';

/// Browser selfie capture. The generic camera bridge falls back to a file
/// input when getUserMedia fails; that fallback is disabled here so a Spot me
/// "selfie" can only come from the live camera.
Future<MeetupSelfieResult> captureMeetupSelfie({
  required BuildContext context,
  required LocalizationState l10n,
}) async {
  String? error;
  try {
    final bytes = await web.pickImageBytesFromCamera(
      capture: 'user',
      captureButtonText: l10n.getString('meetupSpotMeSelfie'),
      cancelButtonText: l10n.getString('cancel'),
      allowFileFallback: false,
      onError: (code) => error = code,
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
