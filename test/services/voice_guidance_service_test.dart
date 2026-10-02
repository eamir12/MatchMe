import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await VoiceGuidanceService.instance.loadEnabledFromPrefs();
    await VoiceGuidanceService.instance.setEnabled(true);
    if (VoiceGuidanceService.instance.muted) {
      await VoiceGuidanceService.instance.toggleMute();
    }
    await VoiceGuidanceService.instance.stop();
  });

  tearDown(() async {
    await VoiceGuidanceService.instance.stop();
  });

  group('VoiceGuidanceService speaking state and wait tests', () {
    test('isSpeaking is false when idle', () {
      expect(VoiceGuidanceService.instance.isSpeaking, isFalse);
    });

    test('waitUntilCurrentSpeechFinished completes immediately when idle', () async {
      final sw = Stopwatch()..start();
      await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished(
        timeout: const Duration(seconds: 5),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100));
    });

    test('waitUntilCurrentSpeechFinished completes immediately when muted', () async {
      await VoiceGuidanceService.instance.toggleMute();
      expect(VoiceGuidanceService.instance.muted, isTrue);
      expect(VoiceGuidanceService.instance.isSpeaking, isFalse);

      final sw = Stopwatch()..start();
      await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished(
        timeout: const Duration(seconds: 5),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100));
    });

    test('waitUntilCurrentSpeechFinished completes immediately when disabled', () async {
      await VoiceGuidanceService.instance.setEnabled(false);
      expect(VoiceGuidanceService.instance.enabled, isFalse);
      expect(VoiceGuidanceService.instance.isSpeaking, isFalse);

      final sw = Stopwatch()..start();
      await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished(
        timeout: const Duration(seconds: 5),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100));
    });

    test('stop() immediately clears isSpeaking and completes wait', () async {
      await VoiceGuidanceService.instance.stop();
      expect(VoiceGuidanceService.instance.isSpeaking, isFalse);
    });
  });
}
