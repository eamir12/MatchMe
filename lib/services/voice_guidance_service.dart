// Voice guidance: on-device text-to-speech coaching for complex flows
// (profile wizard photo upload, profile verification, onboarding tour).
//
// Design notes:
// - Speech output only — no microphone, no new permissions, works offline.
// - Text is resolved through the existing localization system so guidance
//   always matches the user's selected UI language (DB translations first,
//   built-in English fallbacks otherwise).
// - The TTS engine language is matched to the UI locale with a graceful
//   fallback: exact locale (e.g. he-IL) → plain language code (he) → English.
//   If the device has no suitable voice at all, guidance silently no-ops —
//   it must never crash or garble a flow.
// - Voice quality: instead of accepting the engine's default voice (usually
//   the low-quality "compact" one), we prefer the Google TTS engine on
//   Android, then rank the installed voices for the target locale and pick
//   the best one — neural / network / premium / enhanced voices first,
//   compact / pico / eSpeak-style fallbacks heavily penalized — degrading to
//   the default when none can be found. Rate/pitch are tuned per language
//   for a calm, natural coaching tone (slow-draggy rates sound robotic), and
//   spoken text is normalized ("…" → sentence break, no symbols) so engines
//   produce smooth prosody. On iOS guidance ducks any background audio
//   instead of stopping it.
// - Every public method is wrapped defensively; callers never need try/catch.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

class VoiceGuidanceService {
  VoiceGuidanceService._internal();
  static final VoiceGuidanceService instance = VoiceGuidanceService._internal();

  /// Wired from main.dart bootstrap so the service can resolve translations
  /// (same pattern as AdminBroadcastService.setProviderContainer).
  static ProviderContainer? _container;
  static void setProviderContainer(ProviderContainer container) {
    _container = container;
  }

  static const String _prefsEnabledKey = 'voice_guidance_enabled';

  /// Legacy key from when onboarding had a separate mute toggle; read once
  /// during load so users who muted there keep their intent (voice off).
  static const String _prefsMutedKey = 'voice_guidance_muted';

  /// Minimum delay between two different spoken messages. New speech always
  /// interrupts old speech, but this prevents rapid-fire hook points from
  /// turning into a wall of overlapping announcements.
  static const Duration _minGapBetweenMessages = Duration(seconds: 2);

  /// Re-announcing the same guidance key within this window is suppressed
  /// (rebuilds and repeated taps must not repeat the same sentence).
  static const Duration _sameKeySuppressWindow = Duration(seconds: 6);

  FlutterTts? _tts;
  bool _initFailed = false;
  bool _currentVoiceAvailable = false;
  bool _loadedFromPrefs = false;

  bool _enabled = true;
  DateTime _lastSpeakAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastSpokenKey;
  DateTime _lastSpokenKeyAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Completer resolved by the engine handlers when the current utterance
  /// finishes or is cancelled. Only non-null while [speakAndWait] is in
  /// flight — the regular coaching hooks never await speech.
  Completer<void>? _speechDoneCompleter;
  Timer? _speechWatchdog;

  /// The text currently being spoken via [speakAndWait], or null when idle.
  /// Lets tour visuals sync with the narration (e.g. the onboarding
  /// online-toggle demo times its flips to the spoken explanation).
  /// Fire-and-forget [speakKey]/[speakText] coaching blurbs do not touch this.
  final ValueNotifier<String?> spokenText = ValueNotifier<String?>(null);

  /// True once the utterance belonging to the pending [speakAndWait] has
  /// actually started. Interrupting a previous utterance (stop() before a new
  /// speak) fires the cancel handler asynchronously, so completion/cancel
  /// events are only honored after the new utterance's start event — stale
  /// events from the interrupted one must not advance the tour early.
  bool _speechStarted = false;

  bool get _isWindows => !kIsWeb && Platform.isWindows;

  /// Whether guidance is currently allowed to speak. Mirrors the persisted
  /// preference; the settings provider keeps this in sync via [setEnabled].
  bool get enabled => _enabled;

  /// True once we know the platform has no usable TTS voice for the current
  /// language AND not for the English fallback. Used purely to skip work.
  bool get isAvailable => !_initFailed;

  /// Whether an utterance is currently being spoken and has not finished yet.
  bool get isSpeaking =>
      _enabled &&
      _speechDoneCompleter != null &&
      !_speechDoneCompleter!.isCompleted;

  /// Waits until the current spoken utterance finishes.
  /// If nothing is currently speaking, or if voice guidance is disabled,
  /// completes immediately.
  /// Includes a safety timeout so it will never stall indefinitely.
  Future<void> waitUntilCurrentSpeechFinished({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!_enabled) return;
    final completer = _speechDoneCompleter;
    if (completer == null || completer.isCompleted) return;
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // Timeout or error: proceed anyway without blocking
    }
  }

  /// Reads the persisted preference. Called during bootstrap; safe to call
  /// multiple times. Must complete before the wizard relies on [_enabled].
  Future<void> loadEnabledFromPrefs() async {
    if (_loadedFromPrefs) return;
    _loadedFromPrefs = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Legacy onboarding muted via a separate flag; when no explicit enabled
      // value was ever stored, a legacy mute means the user wanted voice off.
      final explicit = prefs.getBool(_prefsEnabledKey);
      final legacyMuted = prefs.getBool(_prefsMutedKey) ?? false;
      _enabled = explicit ?? !legacyMuted;
      print('[VOICE_GUIDANCE] loadEnabledFromPrefs: enabled=$_enabled (explicit=$explicit, legacyMuted=$legacyMuted)');
    } catch (_) {
      // Default to enabled when storage is unavailable.
      _enabled = true;
      print('[VOICE_GUIDANCE] loadEnabledFromPrefs: using default (enabled=true)');
    }
  }

  /// Updates the preference, persists it, and immediately silences current
  /// speech when turning guidance off.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsEnabledKey, value);
      // The separate mute toggle is gone; clear the legacy key so a later
      // defaulting pass can't resurrect a stale mute.
      await prefs.remove(_prefsMutedKey);
    } catch (_) {}
    if (!value) {
      await stop();
    }
  }

  /// Speaks the localized string for [key]. Resolves the text through the
  /// localization provider so DB translations and built-in fallbacks apply,
  /// and uses the current UI locale for voice selection.
  Future<void> speakKey(
    String key, {
    Map<String, String>? params,
    String? fallbackText,
  }) async {
    if (!_enabled || key.isEmpty) return;
    final container = _container;
    if (container == null) return;
    try {
      final l10n = container.read(localizationProvider);
      String text;
      if (l10n.containsKey(key)) {
        text = l10n.getString(key, params: params);
        // getString returns "[key]" when the key is missing everywhere
        // (NO-TRUNCATION POLICY: never a "key..." ellipsis fallback).
        if (text == '[$key]' || text == '$key...') {
          text = fallbackText ?? '';
        }
      } else {
        text = fallbackText ?? '';
      }
      if (text.trim().isEmpty) return;
      await _speak(text, key: key);
    } catch (e) {
      print('[VOICE_GUIDANCE] speakKey($key) failed: $e');
    }
  }

  /// Speaks already-localized text (e.g. dynamic messages produced by the
  /// backend and translated elsewhere in the app).
  Future<void> speakText(String text) async {
    if (!_enabled) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      await _speak(trimmed);
    } catch (e) {
      print('[VOICE_GUIDANCE] speakText failed: $e');
    }
  }

  /// Speaks [text] after the utterance currently in progress has finished,
  /// waiting out the mandatory gap between messages. Used to read on-screen
  /// content aloud in order (accessibility: everything the user can see must
  /// also be spoken) without cutting the previous line short — and without
  /// being silently dropped by the rate limiter the way back-to-back
  /// [speakText] calls would be. Resolves once the utterance has *started*;
  /// callers that must chain further announcements should follow up with
  /// [waitUntilCurrentSpeechFinished].
  Future<void> speakTextAfterCurrent(String text) async {
    if (!_enabled) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final genAtCall = _generation;
    try {
      await waitUntilCurrentSpeechFinished();
      if (genAtCall != _generation) return;
      final sinceLast = DateTime.now().difference(_lastSpeakAt);
      if (sinceLast < _minGapBetweenMessages) {
        await Future<void>.delayed(_minGapBetweenMessages - sinceLast);
      }
      if (genAtCall != _generation) return;
      await _speak(trimmed);
    } catch (e) {
      print('[VOICE_GUIDANCE] speakTextAfterCurrent failed: $e');
    }
  }

  /// Bumped by [stop] so utterances that are still awaiting engine setup
  /// when a screen goes away never start speaking on the next screen.
  int _generation = 0;

  /// Stops current speech immediately (used when muting mid-sentence or when
  /// the hosting screen is disposed).
  Future<void> stop() async {
    _generation++;
    _completeSpeechDone();
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  void _completeSpeechDone() {
    _speechWatchdog?.cancel();
    _speechWatchdog = null;
    spokenText.value = null;
    _speechStarted = false;
    final completer = _speechDoneCompleter;
    _speechDoneCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Completion/cancel event from the engine. Events for an utterance that
  /// never started (stale cancel from a just-interrupted previous one) are
  /// dropped so they cannot resolve the current waiter prematurely.
  void _onSpeechEnded() {
    // On Windows, we manually set _speechStarted to true, so always complete
    // On other platforms, only complete if speech actually started
    if (!_isWindows && !_speechStarted) return;
    _completeSpeechDone();
  }

  /// Speaks [text] and resolves only when the utterance has finished (or been
  /// cancelled / timed out). Used by the onboarding tour, which must know
  /// when a narration ends before advancing to the next step. Unlike the
  /// coaching hooks it bypasses the rate limiter — stepping back and forth in
  /// the tour legitimately re-speaks the same line — and reports whether the
  /// utterance actually started, so silent setups (voice guidance disabled,
  /// no TTS voice installed) fall back to timed pacing.
  ///
  /// [timeout] guards against platforms that never fire the completion
  /// handler; the tour then advances on its own estimate.
  Future<bool> speakAndWait(
    String text, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final genAtCall = _generation;
    final trimmed = text.trim();
    print('[VOICE_GUIDANCE] speakAndWait called with text: "$trimmed"');
    if (!_enabled) {
      print('[VOICE_GUIDANCE] speakAndWait aborted - voice guidance disabled');
      return false;
    }
    if (trimmed.isEmpty) {
      print('[VOICE_GUIDANCE] speakAndWait aborted - empty text');
      return false;
    }
    if (!await _ensureInitializedForCurrentLocale()) {
      print('[VOICE_GUIDANCE] speakAndWait aborted - TTS not initialized');
      return false;
    }
    final tts = _tts;
    if (tts == null) {
      print('[VOICE_GUIDANCE] speakAndWait aborted - TTS instance is null');
      return false;
    }
    try {
      _completeSpeechDone();
      _speechStarted = false; // stale cancel events from stop() must be ignored
      final completer = Completer<void>();
      _speechDoneCompleter = completer;
      await tts.stop();
      // Speak the prosody-normalized form, but publish the original text so
      // visuals synced on [spokenText] (tour demos, subtitles) keep matching.
      final languageCode = _currentLanguageCode();
      final speechText = _naturalizeForSpeech(trimmed, languageCode);
      if (genAtCall != _generation) {
        // stop() was called while awaiting setup (host screen went away).
        print('[VOICE_GUIDANCE] speakAndWait aborted - superseded by stop()');
        return false;
      }
      print('[VOICE_GUIDANCE] speakAndWait speaking: "$speechText" on ${Platform.operatingSystem}');
      await tts.speak(speechText);
      _lastSpeakAt = DateTime.now();
      spokenText.value = trimmed;

      // Windows does not support completion handlers - use estimated duration
      if (_isWindows) {
        final estimatedDuration = _estimateSpokenDuration(trimmed);
        print('[VOICE_GUIDANCE] Windows mode - using estimated duration: ${estimatedDuration.inSeconds}s');
        // On Windows, mark speech as started immediately since we can't detect it
        _speechStarted = true;
        _speechWatchdog = Timer(estimatedDuration, _completeSpeechDone);
      } else {
        print('[VOICE_GUIDANCE] Non-Windows mode - using timeout: ${timeout.inSeconds}s');
        _speechWatchdog = Timer(timeout, _completeSpeechDone);
      }

      await completer.future;
      print('[VOICE_GUIDANCE] speakAndWait completed successfully');
      return true;
    } catch (e) {
      print('[VOICE_GUIDANCE] speakAndWait failed: $e');
      _completeSpeechDone();
      return false;
    }
  }

  Future<void> _speak(String text, {String? key}) async {
    final genAtCall = _generation;
    final now = DateTime.now();
    if (key != null &&
        key == _lastSpokenKey &&
        now.difference(_lastSpokenKeyAt) < _sameKeySuppressWindow) {
      print('[VOICE_GUIDANCE] Speak suppressed - same key within window: $key');
      return;
    }
    if (now.difference(_lastSpeakAt) < _minGapBetweenMessages) {
      print('[VOICE_GUIDANCE] Speak suppressed - too soon since last speak');
      return;
    }

    if (!_enabled) {
      print('[VOICE_GUIDANCE] Speak aborted - disabled');
      return;
    }

    _completeSpeechDone();
    _speechStarted = false;
    final completer = Completer<void>();
    _speechDoneCompleter = completer;

    if (!await _ensureInitializedForCurrentLocale()) {
      print('[VOICE_GUIDANCE] Speak aborted - TTS not initialized');
      _completeSpeechDone();
      return;
    }

    try {
      // Interrupt whatever is currently spoken so guidance never queues up
      // and lags behind the user's actions.
      if (!_enabled) {
        print('[VOICE_GUIDANCE] Speak aborted - disabled');
        _completeSpeechDone();
        return;
      }
      await _tts!.stop();
      if (genAtCall != _generation) {
        // stop() was called while awaiting setup (host screen went away).
        print('[VOICE_GUIDANCE] Speak aborted - superseded by stop()');
        _completeSpeechDone();
        return;
      }
      final speechText = _naturalizeForSpeech(text, _currentLanguageCode());
      print('[VOICE_GUIDANCE] Speaking: "$speechText" (key: $key)');
      await _tts!.speak(speechText);
      _lastSpeakAt = DateTime.now();
      if (key != null) {
        _lastSpokenKey = key;
        _lastSpokenKeyAt = DateTime.now();
      }

      final estimatedDuration = _estimateSpokenDuration(speechText);
      if (_isWindows) {
        _speechStarted = true;
        _speechWatchdog = Timer(estimatedDuration, _completeSpeechDone);
      } else {
        final watchdogDuration = estimatedDuration + const Duration(seconds: 4);
        _speechWatchdog = Timer(watchdogDuration, _completeSpeechDone);
      }
    } catch (e) {
      print('[VOICE_GUIDANCE] speak failed: $e');
      _completeSpeechDone();
    }
  }

  /// Lazily creates the TTS engine and selects the best voice for the current
  /// UI locale. Returns false when no usable voice exists (guidance stays
  /// silent rather than speaking the wrong language).
  Future<bool> _ensureInitializedForCurrentLocale() async {
    if (_initFailed) return false;

    // NOTE: Windows uses the MatchMe fork (third_party/flutter_tts) whose
    // native plugin never InvokeMethods from background threads (MediaEnded /
    // SpeakComplete waiters are no-ops). Dart keeps using estimated durations
    // on Windows (no completion handlers), same as before.

    String languageCode = 'en';
    try {
      languageCode =
          _container?.read(localizationProvider).currentLocale.languageCode ??
          'en';
    } catch (_) {}

    if (_tts == null) {
      try {
        final tts = FlutterTts();
        await tts.awaitSpeakCompletion(false);
        await tts.setVolume(1.0);
        // Engine lifecycle handlers feed speakAndWait(): when an utterance
        // finishes or is interrupted, the waiting tour step may advance.
        // Regular coaching calls ignore these events (no completer pending).
        // Note: Windows does not support these handlers - see flutter_tts issues #326, #327
        if (!_isWindows) {
          tts.setStartHandler(() => _speechStarted = true);
          tts.setCompletionHandler(_onSpeechEnded);
          tts.setCancelHandler(_onSpeechEnded);
        }
        // Android: never queue — guidance interrupts itself so narration
        // can't lag behind taps. Flush mode also avoids two utterances
        // blending into one robotic run-on.
        try {
          await tts.setQueueMode(0);
        } catch (_) {}
        // Android: prefer the Google TTS engine when installed. OEM engines
        // (Samsung, Pico, eSpeak fallbacks) are the classic "robot voice".
        try {
          final dynamic engines = await tts.getEngines;
          if (engines is List) {
            final names = engines
                .map((e) => e.toString().toLowerCase())
                .toList();
            final hasGoogle = names.any(
              (n) =>
                  n.contains('com.google.android.tts') || n.contains('google'),
            );
            if (hasGoogle) {
              await tts.setEngine('com.google.android.tts');
            }
          }
        } catch (_) {
          // iOS/web have no engine switch — ignore.
        }
        // iOS: share the audio session and duck (lower) any background
        // audio while speaking instead of pausing it — guidance feels like
        // a polite assistant rather than a takeover. Playback category also
        // makes guidance audible on the silent switch, which is what the
        // user asked for by leaving it enabled. spokenAudio mode tells iOS
        // this is continuous narration (tour), which gets smoother mixing.
        try {
          await tts.setSharedInstance(true);
          await tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
            IosTextToSpeechAudioCategoryOptions.duckOthers,
          ], IosTextToSpeechAudioMode.spokenAudio);
        } catch (_) {
          // Android/web have no iOS audio session — ignore.
        }
        _tts = tts;
        print('[VOICE_GUIDANCE] TTS initialized successfully on ${Platform.operatingSystem}');
      } catch (e) {
        print('[VOICE_GUIDANCE] TTS init failed: $e');
        _initFailed = true;
        return false;
      }
    }

    if (_localeMatchesCurrent(languageCode)) {
      return _currentVoiceAvailable;
    }

    _currentVoiceAvailable = await _selectVoice(languageCode);
    return _currentVoiceAvailable;
  }

  bool _localeMatchesCurrent(String languageCode) {
    // Cheap check: re-validate only when the locale changed since the last
    // successful voice selection. Track via the last selected code.
    return _currentVoiceAvailable && _selectedLanguageBaseCode == languageCode;
  }

  String? _selectedLanguageBaseCode;

  /// Current UI language base code (en/es/he…), used for prosody tuning and
  /// speech-text normalization.
  String _currentLanguageCode() {
    try {
      return _container
              ?.read(localizationProvider)
              .currentLocale
              .languageCode ??
          'en';
    } catch (_) {
      return 'en';
    }
  }

  /// Natural coaching prosody per language. flutter_tts uses a 0..1 rate
  /// scale on every platform. The old 0.47 rate dragged and sounded
  /// monotone-robotic; ~0.52 with a neutral-to-warm pitch sounds human for
  /// tour-length sentences. Hebrew runs slightly slower for clarity.
  Future<void> _applyProsody(String languageCode) async {
    final tts = _tts;
    if (tts == null) return;
    double rate;
    double pitch;
    switch (languageCode.toLowerCase()) {
      case 'es':
        rate = 0.53;
        pitch = 1.02;
        break;
      case 'he':
        rate = 0.50;
        pitch = 1.0;
        break;
      case 'en':
      default:
        rate = 0.52;
        pitch = 1.02;
        break;
    }
    try {
      await tts.setSpeechRate(rate);
    } catch (_) {}
    try {
      await tts.setPitch(pitch);
    } catch (_) {}
  }

  /// Converts subtitle text into a form TTS engines speak naturally.
  ///
  /// Subtitles stay untouched — only the string handed to the engine is
  /// rewritten:
  /// - "…" / "..." (used all over the tour as a written pause) become a
  ///   clean sentence break. Many engines either swallow the ellipsis
  ///   (run-on robot rush) or hold it far too long (creepy stall); a period
  ///   gives a consistent, natural beat.
  /// - em/en dashes become commas (shorter pause, same breath group).
  /// - symbols engines spell out ("★", "•", "&", quotes) are removed or
  ///   expanded to words so the voice doesn't chant "black star" mid-tour.
  String _naturalizeForSpeech(String text, String languageCode) {
    var out = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    // Written pause → spoken sentence break.
    out = out.replaceAll('…', '. ');
    out = out.replaceAll(RegExp(r'\.{2,}'), '. ');
    // Dashes → comma pause (keeps the clause in one breath).
    out = out.replaceAll(RegExp(r'\s+[—–-]\s+'), ', ');
    // Symbols engines read aloud literally.
    out = out.replaceAll(RegExp(r'[★☆•●►»«""“”„‟]'), '');
    out = out.replaceAll('&', _andWord(languageCode));
    out = out.replaceAll(RegExp(r'\s+([,.!?;:])'), r'$1');
    out = out.replaceAll(RegExp(r'\s+'), ' ');
    out = out.replaceAll(RegExp(r'\.\s*\.\s*'), '. ');
    return out.trim();
  }

  String _andWord(String languageCode) {
    switch (languageCode.toLowerCase()) {
      case 'es':
        return ' y ';
      case 'he':
        return ' ו';
      default:
        return ' and ';
    }
  }

  /// A rough spoken-duration estimate used when text-to-speech completion
  /// handlers are unavailable (e.g., Windows) or disabled, so the tour still
  /// auto-advances at a readable pace.
  Duration _estimateSpokenDuration(String text) {
    final words = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    final seconds = 2.2 + words * 0.42;
    return Duration(milliseconds: (seconds.clamp(2.5, 30.0) * 1000).round());
  }

  Future<bool> _selectVoice(String languageCode) async {
    final tts = _tts;
    if (tts == null) return false;

    print('[VOICE_GUIDANCE] Selecting voice for language: $languageCode');

    // Windows (flutter_tts 4.2.5) does not implement isLanguageAvailable —
    // it returns NotImplemented, which surfaces as a MissingPluginException on
    // the Dart side. Calling it made _selectVoice fail on every candidate and
    // silently disabled all guidance. On Windows we pick the voice directly
    // from getVoices() (which IS implemented) and call setVoice instead.
    if (_isWindows) {
      return _selectVoiceWindows(languageCode);
    }

    final candidates = _languageCandidates(languageCode);
    for (final candidate in candidates) {
      try {
        print('[VOICE_GUIDANCE] Trying language candidate: $candidate');
        if (await tts.isLanguageAvailable(candidate)) {
          print('[VOICE_GUIDANCE] Language $candidate is available, setting it');
          await tts.setLanguage(candidate);
          await _applyProsody(languageCode);
          _selectedLanguageBaseCode = languageCode;
          await _applyBestVoice(candidate);
          print('[VOICE_GUIDANCE] Voice selected successfully for $candidate');
          return true;
        }
      } catch (e) {
        print('[VOICE_GUIDANCE] Error setting language $candidate: $e');
      }
    }

    // Fall back to English before giving up — a slightly wrong-language voice
    // would be worse than English for guidance the user can also read on
    // screen.
    for (final candidate in const ['en-US', 'en']) {
      try {
        print('[VOICE_GUIDANCE] Trying fallback language: $candidate');
        if (await tts.isLanguageAvailable(candidate)) {
          print('[VOICE_GUIDANCE] Fallback language $candidate is available, setting it');
          await tts.setLanguage(candidate);
          await _applyProsody('en');
          _selectedLanguageBaseCode = languageCode;
          await _applyBestVoice(candidate);
          print('[VOICE_GUIDANCE] Fallback voice selected successfully for $candidate');
          return true;
        }
      } catch (e) {
        print('[VOICE_GUIDANCE] Error setting fallback language $candidate: $e');
      }
    }

    print(
      '[VOICE_GUIDANCE] No TTS voice available for "$languageCode" or "en"',
    );
    _selectedLanguageBaseCode = languageCode;
    return false;
  }

  /// Windows voice selection: rank installed voices from [tts.getVoices] and
  /// call [tts.setVoice] for the best match. Falls back to English, then to a
  /// bare [tts.setLanguage] so the engine's default voice is used if no
  /// explicit match exists — better than silence.
  Future<bool> _selectVoiceWindows(String languageCode) async {
    final tts = _tts!;
    final voices = await _getVoicesSafe();

    Future<bool> tryLocale(String candidate, String prosodyCode) async {
      final best = _rankVoices(voices, candidate);
      if (best != null) {
        try {
          await tts.setVoice(best);
          await _applyProsody(prosodyCode);
          _selectedLanguageBaseCode = languageCode;
          print(
            '[VOICE_GUIDANCE] Windows: using voice "${best['name']}" (${best['locale']})',
          );
          return true;
        } catch (e) {
          print('[VOICE_GUIDANCE] Windows setVoice failed: $e');
        }
      }
      return false;
    }

    for (final candidate in _languageCandidates(languageCode)) {
      if (await tryLocale(candidate, languageCode)) return true;
    }

    // Fall back to English before giving up.
    for (final candidate in const ['en-US', 'en']) {
      if (await tryLocale(candidate, 'en')) return true;
    }

    // No ranked match at all — try setLanguage so the engine uses its default
    // voice for the requested language rather than staying silent.
    for (final candidate in _languageCandidates(languageCode) +
        const ['en-US', 'en']) {
      try {
        await tts.setLanguage(candidate);
        await _applyProsody(languageCode);
        _selectedLanguageBaseCode = languageCode;
        print(
          '[VOICE_GUIDANCE] Windows: setLanguage($candidate) (no ranked voice match)',
        );
        return true;
      } catch (e) {
        print('[VOICE_GUIDANCE] Windows setLanguage($candidate) failed: $e');
      }
    }

    print(
      '[VOICE_GUIDANCE] No TTS voice available for "$languageCode" or "en"',
    );
    _selectedLanguageBaseCode = languageCode;
    return false;
  }

  /// Normalized list of voice maps from [tts.getVoices], empty on any failure.
  Future<dynamic> _getVoicesSafe() async {
    final tts = _tts;
    if (tts == null) return const [];
    try {
      final dynamic raw = await tts.getVoices;
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      print('[VOICE_GUIDANCE] getVoices failed: $e');
    }
    return const [];
  }

  /// Engine tags to try, most specific first (e.g. he → he-IL).
  List<String> _languageCandidates(String code) {
    switch (code.toLowerCase()) {
      case 'en':
        return const ['en-US', 'en-GB', 'en'];
      case 'es':
        return const ['es-ES', 'es-MX', 'es-US', 'es'];
      case 'he':
        return const ['he-IL', 'he'];
      default:
        return [code];
    }
  }

  /// Preferred voice per locale, in priority order. Windows 11 ships two voice
/// tiers: the older "desktop" V110 voices (David, Zira, Helena, Asaf…) and a
/// separate set of free "natural" neural voices (Aria, Jenny, Guy, Elvira,
/// Alvaro…) that Microsoft's own MOS testing rates ~4.3 vs ~3.9 for desktop.
/// Natural voices are free to install (Settings → Speech → Manage voices) and
/// are reachable through the same SpeechSynthesizer API this plugin already
/// uses, so whenever one is installed it wins automatically. The desktop
/// names are the fallback for machines that haven't installed them (this
/// machine has none — only the 7 V110 voices).
  /// - en-US: Aria (female natural) → Jenny (female natural) → Guy (male
  ///   natural) → Zira (female desktop) → Mark → David. Female voices rate
  ///   higher in TTS naturalness studies; David's 91.9 Hz is unusually deep
  ///   and reads unnaturally (ttschoice measured Zira at 176.9 Hz).
  /// - es-ES: Elvira (female natural) → Alvaro (male natural) → Helena →
  ///   Laura → Pablo (all desktop, same tier).
  /// - he-IL: Asaf — no natural Hebrew voice exists locally; the better
  ///   Avri/Hila neural voices need Azure/internet, which the app can't use
  ///   offline.
  /// Keys must stay lowercase: [languageTag] is normalized to lowercase
  /// before the lookup, so camel-cased region keys ('en-US') never matched
  /// and no preferred voice ever scored a bonus.
  static const Map<String, List<String>> _preferredVoices = {
    'en-us': ['Aria', 'Jenny', 'Guy', 'Zira', 'Mark', 'David'],
    'es-es': ['Elvira', 'Alvaro', 'Helena', 'Laura', 'Pablo'],
    'he-il': ['Asaf'],
  };

  /// Selects the highest-quality installed voice for [languageTag].
  ///
  /// Engines pick their default voice per language, and the default is
  /// typically the low-quality compact one — even when better voices are
  /// installed. This ranks the available voices and promotes the best:
  /// - Android: Google voices; `network` entries are Google's streamed
  ///   high-fidelity voices (quality 500 vs the local 300 fallbacks), so a
  ///   reported quality score plus network/name bonuses rank them first.
  ///   Known-robotic fallbacks (pico, espeak, eloquence, compact) are
  ///   heavily penalized so they only win when nothing else is installed.
  /// - iOS: `neural` / `natural` / `…premium` / `…enhanced` downloadable
  ///   voices rank above the compact defaults.
  /// Any failure leaves the engine default in place.
  Future<void> _applyBestVoice(String languageTag) async {
    final tts = _tts;
    if (tts == null) return;
    try {
      final voices = await _getVoicesSafe();
      final best = _rankVoices(voices, languageTag);
      if (best != null) {
        await tts.setVoice(best);
        print(
          '[VOICE_GUIDANCE] Using voice "${best['name']}" for $languageTag',
        );
      }
    } catch (e) {
      // getVoices/setVoice unsupported on some platforms — engine default is
      // fine.
      print('[VOICE_GUIDANCE] Best-voice selection skipped: $e');
    }
  }

  /// Ranks the normalized voice list and returns the best match for
  /// [languageTag] as a `{name, locale}` map, or null when nothing matches.
  ///
  /// Shared by the non-Windows [setVoice] path and the Windows-only
  /// [isLanguageAvailable]-free selection. Windows voices report a `locale`
  /// like "en-US" and a `name` like "Mark" (SpeechSynthesizer) — the same
  /// shape this ranks — so the ranking works across platforms.
  Map<String, String>? _rankVoices(List<Map<String, dynamic>> voices, String languageTag) {
    final base = languageTag.split(RegExp('[-_]')).first.toLowerCase();
    final normalizedTag = languageTag.replaceAll('_', '-').toLowerCase();
    final preferred = _preferredVoices[normalizedTag];

    Map<String, dynamic>? bestEntry;
    String? bestName;
    String? bestLocale;
    var bestScore = -1000000;
    for (final entry in voices) {
      final name = entry['name']?.toString() ?? '';
      final locale = (entry['locale']?.toString() ?? '').replaceAll('_', '-');
      final localeBase = locale.split('-').first.toLowerCase();
      if (name.isEmpty || localeBase != base) continue;

      final lower = name.toLowerCase();
      var score = 0;
      final quality = entry['quality'];
      if (quality is num) score += quality.toInt();
      // High-fidelity neural / streamed voices first — this is the
      // biggest anti-robot lever on both platforms.
      if (lower.contains('neural')) score += 90;
      if (lower.contains('natural')) score += 80;
      if (lower.contains('wavenet')) score += 70;
      if (lower.contains('premium')) score += 60;
      if (lower.contains('network')) score += 50;
      if (lower.contains('enhanced')) score += 45;
      if (lower.contains('siri')) score += 40;
      if (lower.contains('samantha') ||
          lower.contains('jenny') ||
          lower.contains('aria') ||
          lower.contains('guy') ||
          lower.contains('carmit') ||
          lower.contains('paulina') ||
          lower.contains('monica') ||
          lower.contains('jorge')) {
        score += 30;
      }
      if (lower.contains('google')) score += 25;
      // Exact region match (en-US voice for en-US tag) beats a generic one.
      if (locale.toLowerCase() == normalizedTag) score += 20;
      // Preferred voice for this locale (most natural tone) outranks every
      // other same-tier voice, including higher-quality-but-wrong-tone ones.
      if (preferred != null) {
        for (var i = 0; i < preferred.length; i++) {
          if (lower.contains(preferred[i].toLowerCase())) {
            // Weighted by rank, not a flat bonus: a flat +100 made every
            // preferred name tie, so the engine's enumeration order decided
            // (it listed "Microsoft David" first, so the deepest, most
            // robotic tier won). Each later preference costs 10 points.
            score += 100 - (i * 10);
            break;
          }
        }
      }
      // Robotic / legacy fallbacks last — only when nothing better exists.
      if (lower.contains('compact')) score -= 120;
      if (lower.contains('pico')) score -= 120;
      if (lower.contains('espeak') || lower.contains('e-speak')) score -= 120;
      if (lower.contains('eloquence')) score -= 100;
      if (lower.contains('robot')) score -= 100;
      if (lower.contains('fallback') || lower.contains('default')) {
        score -= 10;
      }
      if (score > bestScore) {
        bestScore = score;
        bestEntry = entry;
        bestName = name;
        bestLocale = locale.isEmpty ? languageTag : locale;
      }
    }

    if (bestEntry == null) return null;
    return {
      'name': bestName!,
      'locale': bestLocale!,
    };
  }
}
