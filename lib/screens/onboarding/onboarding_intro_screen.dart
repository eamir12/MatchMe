// Onboarding introduction tour — player screen.
//
// A guided, narrated walk through MatchMe that plays inside a phone frame:
// each chapter shows a replica of a real screen (onboarding_scenes.dart) and
// narrates it beat by beat with the SAME localized string used for the
// on-screen subtitle bar, so audio and captions always match and follow the
// user's UI language (including RTL).
//
// Playback model ("watch mode"): when playing, every beat is spoken via
// VoiceGuidanceService.speakAndWait — the loop advances when the utterance
// finishes (or after a timed fallback when speech is muted/unavailable) —
// then after a short pause the next beat starts. Any user action (pause,
// next, back, chapter dots) bumps a playback generation that immediately
// invalidates the in-flight loop, so controls always win over autoplay.
//
// Skip (or system back) exits at any point and marks the tour as seen; the
// same flag is what triggers the auto-run after profile completion and can
// be reset by replaying from Settings.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/screens/onboarding/onboarding_scenes.dart';
import 'package:matchme/services/onboarding_intro_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OnboardingIntroScreen extends ConsumerStatefulWidget {
  const OnboardingIntroScreen({super.key});

  @override
  ConsumerState<OnboardingIntroScreen> createState() =>
      _OnboardingIntroScreenState();
}

class _OnboardingIntroScreenState extends ConsumerState<OnboardingIntroScreen> {
  int _chapterIndex = 0;
  int _beatIndex = 0;
  bool _playing = false;

  /// Bumped on every navigation/playback state change; any loop awaiting an
  /// old generation exits instead of advancing.
  int _playbackGeneration = 0;

  @override
  void initState() {
    super.initState();
    print('[ONBOARDING] initState called');
    // Autoplay the tour: the user should be able to just watch. Controls
    // (pause, next, back, skip) take over instantly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      print('[ONBOARDING] PostFrame callback executing');
      if (mounted) {
        print('[ONBOARDING] Starting playback');
        _startPlayback();
      }
    });
  }

  @override
  void dispose() {
    _invalidatePlayback();
    unawaited(VoiceGuidanceService.instance.stop());
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Navigation helpers
  // -------------------------------------------------------------------------

  OnboardingChapter get _chapter => kOnboardingChapters[_chapterIndex];
  OnboardingBeat get _beat => _chapter.beats[_beatIndex];

  bool get _isFirstBeat => _chapterIndex == 0 && _beatIndex == 0;
  bool get _isLastBeat =>
      _chapterIndex == kOnboardingChapters.length - 1 &&
      _beatIndex == _chapter.beats.length - 1;

  int get _globalBeatIndex {
    var n = 0;
    for (var i = 0; i < _chapterIndex; i++) {
      n += kOnboardingChapters[i].beats.length;
    }
    return n + _beatIndex;
  }

  String _beatText(LocalizationState l10n) => l10n.getString(_beat.bodyKey);

  /// Moves to the next beat (or the next chapter's first beat). Returns false
  /// when the tour is already at the end.
  bool _advanceBeat() {
    if (_isLastBeat) return false;
    if (_beatIndex < _chapter.beats.length - 1) {
      _beatIndex++;
    } else {
      _chapterIndex++;
      _beatIndex = 0;
    }
    return true;
  }

  void _invalidatePlayback() {
    _playbackGeneration++;
  }

  // -------------------------------------------------------------------------
  // Playback
  // -------------------------------------------------------------------------

  void _startPlayback() {
    _invalidatePlayback();
    setState(() => _playing = true);
    unawaited(_playLoop(_playbackGeneration));
  }

  void _pausePlayback() {
    _invalidatePlayback();
    setState(() => _playing = false);
    unawaited(VoiceGuidanceService.instance.stop());
  }

  void _togglePlayback() {
    if (_playing) {
      _pausePlayback();
    } else {
      _startPlayback();
    }
  }

  /// The autoplay loop: speak the current beat, wait for its natural end (or
  /// a timed fallback), pause briefly, then advance. Exits as soon as the
  /// generation it was started with is superseded.
  Future<void> _playLoop(int generation) async {
    print('[ONBOARDING] _playLoop started, generation=$generation');
    while (mounted && _playing && generation == _playbackGeneration) {
      final l10n = ref.read(localizationProvider);
      final text = l10n.getString(_beat.bodyKey);
      final estimate = estimateSpokenDuration(text);
      print('[ONBOARDING] Beat $_chapterIndex:$_beatIndex, text: "$text"');

      var spoke = false;
      final service = VoiceGuidanceService.instance;
      print('[ONBOARDING] Service state: enabled=${service.enabled}, available=${service.isAvailable}, muted=${service.muted}');
      if (service.enabled && service.isAvailable) {
        print('[ONBOARDING] Calling speakAndWait...');
        spoke = await service.speakAndWait(
          text,
          timeout: estimate + const Duration(seconds: 12),
        );
        print('[ONBOARDING] speakAndWait returned: $spoke');
      } else {
        print('[ONBOARDING] speakAndWait skipped (enabled=${service.enabled}, available=${service.isAvailable})');
      }
      if (!mounted || generation != _playbackGeneration || !_playing) return;

      // Muted or unavailable TTS: advance on a reading-pace timer so the
      // tour still plays itself with subtitles only.
      await Future<void>.delayed(
        spoke ? const Duration(milliseconds: 900) : estimate,
      );
      if (!mounted || generation != _playbackGeneration || !_playing) return;

      if (!_advanceBeat()) {
        setState(() => _playing = false);
        return;
      }
      setState(() {});
    }
    print('[ONBOARDING] _playLoop ended');
  }

  /// Applies a navigation change (chapter dots) and restarts playback.
  void _goToChapter(int chapter) {
    _invalidatePlayback();
    unawaited(VoiceGuidanceService.instance.stop());
    setState(() {
      _chapterIndex = chapter.clamp(0, kOnboardingChapters.length - 1);
      _beatIndex = 0;
    });
    if (_playing) {
      unawaited(_playLoop(_playbackGeneration));
    }
  }

  /// Fast-forwards one beat, crossing chapter boundaries.
  void _goNext() {
    if (_isLastBeat) return;
    _invalidatePlayback();
    unawaited(VoiceGuidanceService.instance.stop());
    setState(_advanceBeat);
    if (_playing) {
      unawaited(_playLoop(_playbackGeneration));
    }
  }

  /// Rewinds one beat, crossing chapter boundaries.
  void _goPrevious() {
    if (_isFirstBeat) return;
    _invalidatePlayback();
    unawaited(VoiceGuidanceService.instance.stop());
    setState(() {
      if (_beatIndex > 0) {
        _beatIndex--;
      } else {
        _chapterIndex--;
        _beatIndex = kOnboardingChapters[_chapterIndex].beats.length - 1;
      }
    });
    if (_playing) {
      unawaited(_playLoop(_playbackGeneration));
    }
  }

  /// Replays the narration of the current beat without changing position.
  Future<void> _replayBeatNarration() async {
    _invalidatePlayback();
    await VoiceGuidanceService.instance.stop();
    if (!mounted) return;
    if (_playing) {
      unawaited(_playLoop(_playbackGeneration));
      return;
    }
    final l10n = ref.read(localizationProvider);
    final text = l10n.getString(_beat.bodyKey);
    await VoiceGuidanceService.instance.speakAndWait(
      text,
      timeout: estimateSpokenDuration(text) + const Duration(seconds: 12),
    );
  }

  // -------------------------------------------------------------------------
  // Exit
  // -------------------------------------------------------------------------

  Future<void> _exitTour() async {
    _invalidatePlayback();
    await VoiceGuidanceService.instance.stop();
    String? userId;
    try {
      userId = Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {}
    await OnboardingIntroService.instance.markIntroSeen(userId: userId);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    print('[ONBOARDING] build called');
    final l10n = ref.watch(localizationProvider);
    final colors = Theme.of(context).colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final beatText = _beatText(l10n);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _invalidatePlayback();
          unawaited(VoiceGuidanceService.instance.stop());
          String? userId;
          try {
            userId = Supabase.instance.client.auth.currentUser?.id;
          } catch (_) {}
          unawaited(
            OnboardingIntroService.instance.markIntroSeen(userId: userId),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.getString('onboardingTourTitle')),
          actions: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  l10n.getString(
                    'onboardingStepOf',
                    params: {
                      'current': '${_globalBeatIndex + 1}',
                      'total': '$kOnboardingTotalBeats',
                    },
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: _exitTour,
              child: Text(l10n.getString('onboardingSkip')),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;
              // Phone frame sized to fit both phones, tablets and web windows.
              // Portrait gives the frame most of the height (the narration
              // card below scrolls internally), landscape shares the width.
              // The frame never grows taller than the body itself, so short
              // landscape screens get a smaller phone instead of an overflow.
              var frameHeight =
                  (constraints.maxHeight * (isLandscape ? 0.75 : 0.64)).clamp(
                    280.0,
                    640.0,
                  );
              if (frameHeight > constraints.maxHeight) {
                frameHeight = constraints.maxHeight;
              }
              var frameWidth = frameHeight / 1.85;
              if (frameWidth >
                  constraints.maxWidth * (isLandscape ? 0.45 : 0.82)) {
                frameWidth = constraints.maxWidth * (isLandscape ? 0.45 : 0.82);
                frameHeight = frameWidth * 1.85;
              }

              if (isLandscape) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: frameWidth,
                      height: frameHeight,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: rtl
                                  ? const Offset(-0.06, 0)
                                  : const Offset(0.06, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: PhoneFrame(
                          key: ValueKey('onboarding-chapter-$_chapterIndex'),
                          child: buildOnboardingReplica(
                            _chapter.scene,
                            OnboardingSceneData(
                              text: l10n.getString,
                              highlight: _beat.highlight,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Flexible(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            flex: 10,
                            child: _buildSubtitleCard(
                              context,
                              l10n,
                              colors,
                              beatText,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildChapterDots(context, colors, l10n),
                          const SizedBox(height: 10),
                        ],
                      ),
                    ),
                  ],
                );
              }

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    children: [
                      SizedBox(height: constraints.maxHeight * 0.02),
                      SizedBox(
                        width: frameWidth,
                        height: frameHeight,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 420),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: rtl
                                        ? const Offset(-0.06, 0)
                                        : const Offset(0.06, 0),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: PhoneFrame(
                            key: ValueKey('onboarding-chapter-$_chapterIndex'),
                            child: buildOnboardingReplica(
                              _chapter.scene,
                              OnboardingSceneData(
                                text: l10n.getString,
                                highlight: _beat.highlight,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(flex: 1),
                      _buildChapterDots(context, colors, l10n),
                      const SizedBox(height: 10),
                      // The narration must always show completely, in every
                      // language and on every screen size: the card takes the
                      // available space and its text scrolls internally
                      // instead of truncating.
                      Flexible(
                        flex: 10,
                        child: _buildSubtitleCard(
                          context,
                          l10n,
                          colors,
                          beatText,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Controls live in the bottom bar, pinned to the bottom of the
        // screen on every device size and orientation — they can never be
        // pushed off-screen by the phone frame or long narration text.
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _buildControls(context, l10n, colors, rtl),
          ),
        ),
      ),
    );
  }

  Widget _buildChapterDots(
    BuildContext context,
    ColorScheme colors,
    LocalizationState l10n,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(kOnboardingChapters.length, (i) {
          final active = i == _chapterIndex;
          return Semantics(
            button: true,
            selected: active,
            label: l10n.getString(kOnboardingChapters[i].titleKey),
            child: GestureDetector(
              onTap: () => _goToChapter(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: active ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active
                        ? colors.primary
                        : colors.onSurface.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildSubtitleCard(
    BuildContext context,
    LocalizationState l10n,
    ColorScheme colors,
    String text,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 74),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.getString(_chapter.titleKey),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Full narration text — never truncated: when it outgrows
                  // the available space (long translations, small screens)
                  // this region scrolls instead of clipping.
                  Flexible(
                    child: SingleChildScrollView(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        // Captions for the hearing impaired and for muted
                        // playback — always the exact narration text.
                        child: Text(
                          text,
                          key: ValueKey('subtitle-$_globalBeatIndex'),
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.35,
                            color: colors.onSurface.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: l10n.getString('onboardingReplayAudioTooltip'),
              onPressed: _replayBeatNarration,
              icon: Icon(Icons.replay, size: 20, color: colors.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    LocalizationState l10n,
    ColorScheme colors,
    bool rtl,
  ) {
    final showFinish = _isLastBeat;
    // Button labels must show completely in every language: the text buttons
    // share the leftover width (Flexible) and their labels wrap instead of
    // clipping or overflowing (e.g. long words on narrow screens).
    Widget buttonLabel(String text) {
      return Flexible(
        child: Text(
          text,
          textAlign: TextAlign.center,
          softWrap: true,
          overflow: TextOverflow.visible,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Back button pinned left. NOTE: Scaffold.bottomNavigationBar
          // gives its child unbounded height, and a plain Align/Center
          // (null width/height factors) expands to fill it — the bar then
          // takes the whole screen and the body (phone mock + subtitles)
          // collapses to zero height. heightFactor: 1.0 keeps Align sized
          // to its child so the bar keeps its intrinsic height.
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1.0,
              child: OutlinedButton(
                onPressed: _isFirstBeat ? null : _goPrevious,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.arrow_back, size: 18),
                    const SizedBox(width: 6),
                    buttonLabel(l10n.getString('generalBack')),
                  ],
                ),
              ),
            ),
          ),
          // Play/Pause and Mute/Unmute buttons centered
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                tooltip: l10n.getString(
                  _playing ? 'onboardingPauseTooltip' : 'onboardingPlayTooltip',
                ),
                onPressed: _togglePlayback,
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              // Mute/Unmute button for audio control
              IconButton.filledTonal(
                tooltip: l10n.getString(
                  VoiceGuidanceService.instance.muted
                      ? 'onboardingUnmuteTooltip'
                      : 'onboardingMuteTooltip',
                ),
                onPressed: () {
                  setState(() {
                    VoiceGuidanceService.instance.toggleMute();
                  });
                },
                icon: Icon(
                  VoiceGuidanceService.instance.muted
                      ? Icons.volume_off
                      : Icons.volume_up,
                ),
              ),
            ],
          ),
          // Next/Finish button right-aligned (same heightFactor note as
          // above: keeps the bar at its intrinsic height).
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              heightFactor: 1.0,
              child: !showFinish
                  ? FilledButton(
                      key: const ValueKey('next-button'),
                      onPressed: _goNext,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          buttonLabel(l10n.getString('generalNext')),
                          const SizedBox(width: 6),
                          Icon(Icons.arrow_forward, size: 18),
                        ],
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: _exitTour,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      icon: const Icon(Icons.celebration, size: 18),
                      label: Text(
                        l10n.getString('onboardingGetStarted'),
                        textAlign: TextAlign.center,
                        softWrap: true,
                        overflow: TextOverflow.visible,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Decorative device frame around the replica scenes.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: colors.surface,
        border: Border.all(
          color: colors.onSurface.withValues(alpha: 0.35),
          width: 5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
