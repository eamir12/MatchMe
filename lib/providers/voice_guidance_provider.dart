// Riverpod wrapper around VoiceGuidanceService so UI (settings switch,
// wizard/verification mute buttons) reacts to enable/disable changes.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    await _syncToServer(value);
  }

  /// Convenience toggle for the in-flow mute buttons.
  Future<void> toggle() => setEnabled(!state);

  /// Mirrors the preference onto the account so the other devices follow it.
  ///
  /// Offline the update is queued in the profile outbox and replayed when
  /// the connection is back - otherwise muting voice guidance on a plane
  /// would leave every other device talking.
  Future<void> _syncToServer(bool value) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    try {
      await Supabase.instance.client
          .from('users')
          .update({'voice_guidance_enabled': value})
          .eq('id', userId);
    } catch (_) {
      try {
        await ref.read(localDbProvider).saveProfileUpdateToOutbox(userId, {
          'userId': userId,
          'updates': {'voice_guidance_enabled': value},
        });
      } catch (_) {}
    }
  }
}
