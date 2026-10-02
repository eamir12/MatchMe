// Content model for the interactive onboarding introduction tour.
//
// The tour is a sequence of chapters; each chapter demonstrates one part of
// the app inside a mock replica (see onboarding_scenes.dart) and is narrated
// beat by beat. Every beat has:
//  * a translation key — the SAME string is used for the spoken narration
//    (VoiceGuidanceService) and for the on-screen subtitle bar, so audio and
//    captions can never drift apart, and both follow the user's UI language;
//  * an optional `highlight` id — the replica region to spotlight while the
//    beat is narrated (unhighlighted regions dim for focus).
//
// Sentences are written to be spoken aloud: short clauses, '…' for natural
// pauses, no keyboard symbols. Keys must exist as built-in English fallbacks
// in locale_provider.dart (see _defaultTranslations) with identical text, and
// in the onboarding translations migration for DB overrides (en/es/he).
//
// Invariant: within each chapter, beat highlights follow the visual
// top-to-bottom order of regions in the corresponding replica (no bouncing).
// Intent filters are explained exactly once (Matches4, relating the shared
// filters to both Matches and Chats); other chapters describe only their
// own screen.

/// Which replica scene a chapter renders inside the phone frame.
enum OnboardingScene {
  welcome,
  home,
  nearby,
  worldMap,
  matches,
  chats,
  events,
  profile,
  settings,
  finish,
}

class OnboardingBeat {
  const OnboardingBeat(this.bodyKey, {this.highlight});

  /// Translation key of the narration / subtitle line.
  final String bodyKey;

  /// Region id inside the chapter's replica to spotlight, or null to show
  /// the whole scene undimmed.
  final String? highlight;
}

class OnboardingChapter {
  const OnboardingChapter({
    required this.id,
    required this.titleKey,
    required this.scene,
    required this.beats,
  });

  final String id;
  final String titleKey;
  final OnboardingScene scene;
  final List<OnboardingBeat> beats;
}

const List<OnboardingChapter> kOnboardingChapters = [
  OnboardingChapter(
    id: 'welcome',
    titleKey: 'onboardingChapterWelcome',
    scene: OnboardingScene.welcome,
    beats: [
      OnboardingBeat('onboardingBeatWelcome1', highlight: 'hero'),
      OnboardingBeat('onboardingBeatWelcome2', highlight: 'steps'),
    ],
  ),
  OnboardingChapter(
    id: 'home',
    titleKey: 'onboardingChapterHome',
    scene: OnboardingScene.home,
    beats: [
      OnboardingBeat('onboardingBeatHome1', highlight: 'status'),
      OnboardingBeat('onboardingBeatHome2', highlight: 'stats'),
      OnboardingBeat('onboardingBeatHome4', highlight: 'filters'),
      OnboardingBeat('onboardingBeatHome3', highlight: 'recents'),
    ],
  ),
  OnboardingChapter(
    id: 'nearby',
    titleKey: 'onboardingChapterNearby',
    scene: OnboardingScene.nearby,
    beats: [OnboardingBeat('onboardingBeatNearby1', highlight: 'map')],
  ),
  OnboardingChapter(
    id: 'worldmap',
    titleKey: 'onboardingChapterWorldMap',
    scene: OnboardingScene.worldMap,
    beats: [OnboardingBeat('onboardingBeatWorldMap1', highlight: 'markers')],
  ),
  OnboardingChapter(
    id: 'matches',
    titleKey: 'onboardingChapterMatches',
    scene: OnboardingScene.matches,
    beats: [
      OnboardingBeat('onboardingBeatMatches4', highlight: 'filters'),
      OnboardingBeat('onboardingBeatMatches3', highlight: 'sort'),
      OnboardingBeat('onboardingBeatMatches1', highlight: 'cards'),
      OnboardingBeat('onboardingBeatMatches2', highlight: 'expiry'),
    ],
  ),
  OnboardingChapter(
    id: 'chats',
    titleKey: 'onboardingChapterChats',
    scene: OnboardingScene.chats,
    beats: [
      OnboardingBeat('onboardingBeatChats1', highlight: 'list'),
      OnboardingBeat('onboardingBeatChats2', highlight: 'list'),
    ],
  ),
  OnboardingChapter(
    id: 'events',
    titleKey: 'onboardingChapterEvents',
    scene: OnboardingScene.events,
    beats: [
      OnboardingBeat('onboardingBeatEvents1', highlight: 'cards'),
      OnboardingBeat('onboardingBeatEvents2', highlight: 'calendar'),
    ],
  ),
  OnboardingChapter(
    id: 'profile',
    titleKey: 'onboardingChapterProfile',
    scene: OnboardingScene.profile,
    beats: [
      OnboardingBeat('onboardingBeatProfile1', highlight: 'photos'),
      OnboardingBeat('onboardingBeatProfile2', highlight: 'verify'),
      OnboardingBeat('onboardingBeatProfile3', highlight: 'edit'),
    ],
  ),
  OnboardingChapter(
    id: 'settings',
    titleKey: 'onboardingChapterSettings',
    scene: OnboardingScene.settings,
    beats: [
      OnboardingBeat('onboardingBeatSettings1', highlight: 'entry'),
      OnboardingBeat('onboardingBeatSettingsTour', highlight: 'tour'),
      OnboardingBeat('onboardingBeatSettingsDisplay', highlight: 'display'),
      OnboardingBeat('onboardingBeatSettings2', highlight: 'matching'),
      OnboardingBeat('onboardingBeatSettings3', highlight: 'prefs'),
      OnboardingBeat('onboardingBeatSettings4', highlight: 'invisibility'),
      OnboardingBeat('onboardingBeatSettingsNotifs', highlight: 'notifs'),
      OnboardingBeat('onboardingBeatSettingsPaywall', highlight: 'paywall'),
      OnboardingBeat('onboardingBeatSettingsBilling', highlight: 'billing'),
      OnboardingBeat('onboardingBeatSettingsInvite', highlight: 'invite'),
      OnboardingBeat('onboardingBeatSettings5', highlight: 'verify'),
      OnboardingBeat('onboardingBeatSettingsSecurity', highlight: 'security'),
      OnboardingBeat('onboardingBeatSettingsAccount', highlight: 'account'),
    ],
  ),
  OnboardingChapter(
    id: 'finish',
    titleKey: 'onboardingChapterFinish',
    scene: OnboardingScene.finish,
    beats: [OnboardingBeat('onboardingBeatFinish1')],
  ),
];

/// Total number of narrated beats across all chapters (progress "Step x of y").
final int kOnboardingTotalBeats = kOnboardingChapters.fold(
  0,
  (sum, chapter) => sum + chapter.beats.length,
);

/// A rough spoken-duration estimate used when text-to-speech is unavailable
/// or disabled, so the tour still auto-advances at a readable pace.
Duration estimateSpokenDuration(String text) {
  final words = text
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .length;
  final seconds = 2.2 + words * 0.42;
  return Duration(milliseconds: (seconds.clamp(3.0, 14.0) * 1000).round());
}

/// Tiny value object the player passes to replicas; keeps the scenes
/// decoupled from Riverpod.
class OnboardingSceneData {
  const OnboardingSceneData({required this.text, required this.highlight});

  /// Resolves a translation key for replica labels (real app keys, not invented ones).
  final String Function(String key, {Map<String, String>? params}) text;

  /// Currently spotlighted region id, or null.
  final String? highlight;
}
