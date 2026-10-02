// Riverpod wrapper around VoiceGuidanceService so UI (settings switch,
// wizard/verification mute buttons) reacts to enable/disable changes.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/voice_guidance_service.dart';

/// True when voice guidance is currently enabled. Defaults to enabled; the
/// persisted preference is loaded asynchronously and updates the state.
final voiceGuidanceEnabledProvider =
    NotifierProvider<VoiceGuidanceEnabledNotifier, bool>(
      VoiceGuidanceEnabledNotifier.new,
    );

class VoiceGuidanceEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final service = VoiceGuidanceService.instance;
    // Kick off the persisted-premium load once; the state flips when it lands.
    Future<void>(() async {
      await service.loadEnabledFromPrefs();
      if (state != service.enabled) {
        state = service.enabled;
      }
    });
    return service.enabled;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await VoiceGuidanceService.instance.setEnabled(value);
  }

  /// Convenience toggle for the in-flow mute buttons.
  Future<void> toggle() => setEnabled(!state);
}
