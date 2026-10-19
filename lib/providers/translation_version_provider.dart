// lib/providers/translation_version_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'translation_version_provider.g.dart';

// Temporary flicker diagnostics (see chat_screen.dart). Uses
// `debugPrintSynchronously` because main.dart replaces `debugPrint` with a
// substring whitelist that would drop these lines. Flip to false (or remove)
// once the behavior is verified.
const bool _chatFlickerDiagnosticsEnabled = true;

void _translationVersionDiag(String message) {
  if (!_chatFlickerDiagnosticsEnabled) return;
  debugPrintSynchronously('[ChatFlicker][provider] $message');
}

/// Integer version provider with debounce used to force re-evaluation of
/// translation providers when the app language / translation target changes.
///
/// Multiple rapid calls to increment() are coalesced into a single
/// state change via a 100ms debounce timer.
///
/// Increment the value when the app language is changed:
///   ref.read(translationVersionProvider.notifier).increment();
@riverpod
class TranslationVersion extends _$TranslationVersion {
  Timer? _debounceTimer;

  @override
  int build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
      _debounceTimer = null;
    });
    return 0;
  }

  /// Coalesce rapid increments into a single state change.
  /// Without debounce, every call invalidates all translationFamilyProvider
  /// instances, triggering N × (language detection + DB reads) per message.
  void increment() {
    _translationVersionDiag('version-schedule (current=$state)');
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (!ref.mounted) return;
      state++;
      _translationVersionDiag('version-bump v=$state');
    });
  }
}
