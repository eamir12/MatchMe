// Content model for the interactive onboarding introduction tour.
//
// The tour is built from *chapters*; each chapter demonstrates one part of
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
//
// Playable experiences:
//  * [kOnboardingCoreTour] — the short tour auto-run once after the profile
//    is completed. Kept to the essential mental model (how matching works,
//    where matches/chats live) so the user reaches their first matches fast.
//  * Section tours ([kOnboardingSectionTours]) — one per app area. The ones
//    flagged [OnboardingTour.promptOnFirstVisit] are offered (via
//    OnboardingSectionPrompt) the first time the user opens that area; all of
//    them can be replayed any time from Settings → App tour.

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

  /// The same chapter carrying only the beats whose [OnboardingBeat.bodyKey]
  /// appears in [bodyKeys], in the original visual order. Used to cut the
  /// core tour down to its essentials and to trim the Settings chapter.
  OnboardingChapter selectBeats(List<String> bodyKeys) {
    final selected = [
      for (final beat in beats)
        if (bodyKeys.contains(beat.bodyKey)) beat,
    ];
    assert(
      selected.length == bodyKeys.length,
      'selectBeats: unknown beat key for chapter $id',
    );
    return OnboardingChapter(
      id: id,
      titleKey: titleKey,
      scene: scene,
      beats: selected,
    );
  }
}

/// A playable tour: an ordered list of (optionally trimmed) chapters.
class OnboardingTour {
  const OnboardingTour({
    required this.id,
    required this.titleKey,
    required this.chapters,
    this.promptOnFirstVisit = false,
  });

  /// Stable id: [kOnboardingCoreTourId] for the auto-run tour, otherwise the
  /// section id also used for the per-section "already offered" flag.
  final String id;

  /// Display name (chapter / appbar title key).
  final String titleKey;

  final List<OnboardingChapter> chapters;

  /// True when the tour should be offered the first time the user opens its
  /// section (the rest are replay-only from Settings).
  final bool promptOnFirstVisit;

  bool get isCore => id == kOnboardingCoreTourId;

  int get totalBeats =>
      chapters.fold(0, (sum, chapter) => sum + chapter.beats.length);
}

const String kOnboardingCoreTourId = 'core';

// ---------------------------------------------------------------------------
// Chapter definitions (canonical order and beat order, full narratives).
// ---------------------------------------------------------------------------

const OnboardingChapter kOnboardingChapterWelcome = OnboardingChapter(
  id: 'welcome',
  titleKey: 'onboardingChapterWelcome',
  scene: OnboardingScene.welcome,
  beats: [
    OnboardingBeat('onboardingBeatWelcome1', highlight: 'hero'),
    OnboardingBeat('onboardingBeatWelcome2', highlight: 'steps'),
  ],
);

const OnboardingChapter kOnboardingChapterHome = OnboardingChapter(
  id: 'home',
  titleKey: 'onboardingChapterHome',
  scene: OnboardingScene.home,
  beats: [
    OnboardingBeat('onboardingBeatHome1', highlight: 'status'),
    OnboardingBeat('onboardingBeatHome2', highlight: 'stats'),
    OnboardingBeat('onboardingBeatHome4', highlight: 'filters'),
    OnboardingBeat('onboardingBeatHome3', highlight: 'recents'),
  ],
);

const OnboardingChapter kOnboardingChapterNearby = OnboardingChapter(
  id: 'nearby',
  titleKey: 'onboardingChapterNearby',
  scene: OnboardingScene.nearby,
  beats: [OnboardingBeat('onboardingBeatNearby1', highlight: 'map')],
);

const OnboardingChapter kOnboardingChapterWorldMap = OnboardingChapter(
  id: 'worldmap',
  titleKey: 'onboardingChapterWorldMap',
  scene: OnboardingScene.worldMap,
  beats: [OnboardingBeat('onboardingBeatWorldMap1', highlight: 'markers')],
);

const OnboardingChapter kOnboardingChapterMatches = OnboardingChapter(
  id: 'matches',
  titleKey: 'onboardingChapterMatches',
  scene: OnboardingScene.matches,
  beats: [
    OnboardingBeat('onboardingBeatMatches4', highlight: 'filters'),
    OnboardingBeat('onboardingBeatMatches3', highlight: 'sort'),
    OnboardingBeat('onboardingBeatMatches1', highlight: 'cards'),
    OnboardingBeat('onboardingBeatMatches2', highlight: 'expiry'),
  ],
);

const OnboardingChapter kOnboardingChapterChats = OnboardingChapter(
  id: 'chats',
  titleKey: 'onboardingChapterChats',
  scene: OnboardingScene.chats,
  beats: [
    OnboardingBeat('onboardingBeatChats1', highlight: 'list'),
    OnboardingBeat('onboardingBeatChats2', highlight: 'list'),
  ],
);

const OnboardingChapter kOnboardingChapterEvents = OnboardingChapter(
  id: 'events',
  titleKey: 'onboardingChapterEvents',
  scene: OnboardingScene.events,
  beats: [
    OnboardingBeat('onboardingBeatEvents1', highlight: 'cards'),
    OnboardingBeat('onboardingBeatEvents2', highlight: 'calendar'),
  ],
);

const OnboardingChapter kOnboardingChapterProfile = OnboardingChapter(
  id: 'profile',
  titleKey: 'onboardingChapterProfile',
  scene: OnboardingScene.profile,
  beats: [
    OnboardingBeat('onboardingBeatProfile1', highlight: 'photos'),
    OnboardingBeat('onboardingBeatProfile2', highlight: 'verify'),
    OnboardingBeat('onboardingBeatProfile3', highlight: 'edit'),
  ],
);

const OnboardingChapter kOnboardingChapterSettings = OnboardingChapter(
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
);

const OnboardingChapter kOnboardingChapterFinish = OnboardingChapter(
  id: 'finish',
  titleKey: 'onboardingChapterFinish',
  scene: OnboardingScene.finish,
  beats: [OnboardingBeat('onboardingBeatFinish1')],
);

/// Every chapter in canonical order (full narratives). Tours below select
/// subsets; this list is the master copy and translation-audit anchor.
const List<OnboardingChapter> kOnboardingChapters = [
  kOnboardingChapterWelcome,
  kOnboardingChapterHome,
  kOnboardingChapterNearby,
  kOnboardingChapterWorldMap,
  kOnboardingChapterMatches,
  kOnboardingChapterChats,
  kOnboardingChapterEvents,
  kOnboardingChapterProfile,
  kOnboardingChapterSettings,
  kOnboardingChapterFinish,
];

// ---------------------------------------------------------------------------
// Playable tours.
// ---------------------------------------------------------------------------

/// The short tour auto-run once after profile completion. Deliberately kept
/// to the essential mental model: what MatchMe is, visibility on Home, how
/// matches work (shared intent filters, expiry), and where chats live.
final OnboardingTour kOnboardingCoreTour = OnboardingTour(
  id: kOnboardingCoreTourId,
  titleKey: 'onboardingTourTitle',
  chapters: [
    kOnboardingChapterWelcome.selectBeats(const ['onboardingBeatWelcome1']),
    kOnboardingChapterHome.selectBeats(const ['onboardingBeatHome1']),
    kOnboardingChapterMatches.selectBeats(const [
      'onboardingBeatMatches4',
      'onboardingBeatMatches1',
      'onboardingBeatMatches2',
    ]),
    kOnboardingChapterChats.selectBeats(const ['onboardingBeatChats1']),
    kOnboardingChapterFinish,
  ],
);

/// Home deep-dive (stats, filter chips, recents). Replay-only: the core tour
/// already covered the essentials right where users land.
final OnboardingTour kOnboardingHomeSectionTour = OnboardingTour(
  id: 'home',
  titleKey: 'onboardingChapterHome',
  chapters: [kOnboardingChapterHome],
);

/// Matches deep-dive (sorting, expiry details). Replay-only (core covered it).
final OnboardingTour kOnboardingMatchesSectionTour = OnboardingTour(
  id: 'matches',
  titleKey: 'onboardingChapterMatches',
  chapters: [kOnboardingChapterMatches],
);

/// Chats deep-dive (encryption, translation, safety). Replay-only.
final OnboardingTour kOnboardingChatsSectionTour = OnboardingTour(
  id: 'chats',
  titleKey: 'onboardingChapterChats',
  chapters: [kOnboardingChapterChats],
);

/// Nearby map — offered the first time the user opens the Nearby screen.
final OnboardingTour kOnboardingNearbySectionTour = OnboardingTour(
  id: 'nearby',
  titleKey: 'onboardingChapterNearby',
  chapters: [kOnboardingChapterNearby],
  promptOnFirstVisit: true,
);

/// Online world map — offered the first time the user opens it.
final OnboardingTour kOnboardingWorldMapSectionTour = OnboardingTour(
  id: 'worldmap',
  titleKey: 'onboardingChapterWorldMap',
  chapters: [kOnboardingChapterWorldMap],
  promptOnFirstVisit: true,
);

/// Events — offered the first time the user opens the Events tab.
final OnboardingTour kOnboardingEventsSectionTour = OnboardingTour(
  id: 'events',
  titleKey: 'onboardingChapterEvents',
  chapters: [kOnboardingChapterEvents],
  promptOnFirstVisit: true,
);

/// Profile — offered the first time the user opens the Profile tab.
final OnboardingTour kOnboardingProfileSectionTour = OnboardingTour(
  id: 'profile',
  titleKey: 'onboardingChapterProfile',
  chapters: [kOnboardingChapterProfile],
  promptOnFirstVisit: true,
);

/// Settings — offered the first time the user opens Settings. Trimmed from
/// the original 13-beat chapter to the controls that actually shape the
/// matching experience; the rest of Settings is self-explanatory in place.
final OnboardingTour kOnboardingSettingsSectionTour = OnboardingTour(
  id: 'settings',
  titleKey: 'onboardingChapterSettings',
  chapters: [
    kOnboardingChapterSettings.selectBeats(const [
      'onboardingBeatSettings1',
      'onboardingBeatSettings2',
      'onboardingBeatSettings4',
      'onboardingBeatSettingsNotifs',
      'onboardingBeatSettingsPaywall',
      'onboardingBeatSettings5',
    ]),
  ],
  promptOnFirstVisit: true,
);

/// Every section tour, in the order shown in the Settings "App tour" hub.
final List<OnboardingTour> kOnboardingSectionTours = [
  kOnboardingHomeSectionTour,
  kOnboardingMatchesSectionTour,
  kOnboardingChatsSectionTour,
  kOnboardingNearbySectionTour,
  kOnboardingWorldMapSectionTour,
  kOnboardingEventsSectionTour,
  kOnboardingProfileSectionTour,
  kOnboardingSettingsSectionTour,
];

/// Resolves a section tour by id; null when the id is unknown.
OnboardingTour? onboardingSectionTourById(String id) {
  for (final tour in kOnboardingSectionTours) {
    if (tour.id == id) return tour;
  }
  return null;
}

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
