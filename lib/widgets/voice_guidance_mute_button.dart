// Shared app-bar mute/unmute control for voice guidance. Muting silences the
// current sentence immediately; unmuting speaks a short confirmation so the
// user knows the state flipped.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/voice_guidance_provider.dart';
import 'package:matchme/services/voice_guidance_service.dart';

class VoiceGuidanceMuteButton extends ConsumerWidget {
  const VoiceGuidanceMuteButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final voiceEnabled = ref.watch(voiceGuidanceEnabledProvider);

    return IconButton(
      icon: Icon(
        voiceEnabled
            ? Icons.record_voice_over_outlined
            : Icons.volume_off_outlined,
      ),
      tooltip: l10n.getString(
        voiceEnabled
            ? 'voiceGuidanceMuteTooltip'
            : 'voiceGuidanceUnmuteTooltip',
      ),
      onPressed: () async {
        if (voiceEnabled) {
          await ref
              .read(voiceGuidanceEnabledProvider.notifier)
              .setEnabled(false);
        } else {
          await ref
              .read(voiceGuidanceEnabledProvider.notifier)
              .setEnabled(true);
          await VoiceGuidanceService.instance.speakKey(
            'voiceGuidanceUnmuteTooltip',
            fallbackText: 'Voice guidance on',
          );
        }
      },
    );
  }
}
