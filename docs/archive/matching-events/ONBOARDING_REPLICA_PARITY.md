# ONBOARDING REPLICA PARITY

The onboarding tour renders demos of real MatchMe screens (`lib/screens/onboarding/onboarding_scenes.dart`).
Every replica must stay faithful to the real screen it advertises — same layout regions,
same translated labels (real app keys, not invented ones), same chrome (bottom nav for tabs,
back-arrow app bars for pushed screens), and correct status-strip / FAB placement.

## Scene -> real screen map

| Tour scene | Real screen (source of truth) | Bottom nav | Status strip | App bar | Notes |
|---|---|---|---|---|---|
| welcome | onboarding home (unsigned state) | no | yes | mini title + tagline | hero + 3 steps |
| home | `lib/screens/home/home_screen.dart` | yes (tab 0) | yes | title `appName` + online pill (`homeOnline`, `youAreCurrentlyOnlineAndVisible`) | stats (line 719 `homeOnline`), shared intent chips (live filter demo), recents: section headers + See all (`homeSeeAll`), one `MatchBoxList`-style card of photo/name/star-rating/age-gender rows, chat rows with unread-count pill |
| nearby | `lib/screens/nearby/nearby_map_screen.dart` | no | no (pushed screen) | `homeNearbyMap` title + radius subtitle pill | single beat: single match-radius circle + own blue marker + five same-size plain dots (one per visible user, no counts); total pill (`mapShowingApproxUsers`, count 5 to match the dots); two-row legend (`mapLegendYou`, `mapLegendOnlineUsersApprox`); zoom, locate FAB. No country row — counts by country live only on the separate world map |
| worldmap | `lib/screens/nearby/nearby_map_screen.dart` (`OnlineWorldMapScreen`, separate route from the home online cards) | no | no (pushed screen) | `homeOnline` title + total pill (`onlineMapTotalOnline`) | single beat: painted continents (`_WorldMapPainter`: Americas/Europe/Africa/Asia/Australia over ocean `0xFFD4EBF4`, like the tiled map without network) with one name/count label per country (`localizedCountryNames`), each count sitting on its country |
| matches | `lib/screens/matches/matches_screen.dart` | yes (tab 1) | yes | intent chips (`generalAll`/`onboardingDemoIntentFriends`/`onboardingDemoIntentDating`, live filter demo) + sort pill (`sortByLabel`/`sortOptionNewest`) | shared-interest heart counts (never % scores), expiry countdown + Extend in the bottom details row of the card, as in `match_box.dart` |
| chats | `lib/screens/chats/chat_screen.dart` | yes (tab 2) | yes | header actions (person/share/translate/more-vert) | no lock / E2EE banner in demo; single chip row inside the spotlighted list (intent filters are narrated once, in Matches) |
| events | `lib/screens/events/events_screen.dart` | yes (tab 3) | yes | toggles (`settingsSharedEventMatching`, `showPastEvents`), import buttons, FAB.extended `eventAdd` | two distinct demo events; cards mirror the list item (title, venue/date/time meta, `eventViewDetails` link, map + delete actions) — no attendee stack, no Join button |
| profile | `lib/screens/profile/profile_screen.dart` | yes (tab 4) | yes | 3 photos, age/gender badges | code-painted mock person photos (head-shot main, head/body secondaries — no assets), FAB.extended `generalEdit` |
| settings | `lib/screens/settings/settings_screen.dart` | no | no (pushed screen) | `settingsTitle` | chapter titled per UI language (`Settings` / `Configuración` / `הגדרות`); 13 beats covering every sub-screen top to bottom (entry + all 12 rows); the three matching modes are narrated on the Matching beat, verification only on the verify beat; rows in a `SingleChildScrollView` (never lazy) so the spotlighted row always exists and auto-scroll + ring stay in sync |

## Invariants

1. **Tabs vs pushed screens.** Home/Matches/Chats/Events/Profile are `_DemoBottomNav` tabs
   (activeIndex 0-4). Nearby and Settings are pushed screens: back-arrow app bar,
   `showStatusStrip: false`, no bottom nav. Do not mix these up when editing scenes.
2. **Real keys only.** Prefer real app translation keys for library chrome (`navHome`,
   `sortByLabel`, `settingsMatching`, `homeNearbyMap`, `mapLegendYou`, …). Demo-only keys
   are prefixed `onboardingDemo`/`demo` and must be declared in `locale_provider.dart` AND
   in the onboarding translations migration (en/es/he). The script
   `scripts/check_onboarding_translations.js` enforces equal values across dart fallbacks
   and SQL seeds and reports keys present on only one side.
3. **Factory patterns.** Real `FloatingActionButton.extended` (radius 16, elevation 6) for
    event-add / profile-edit. Status strip reuses `youAreCurrentlyOnlineAndVisible` from the
    real status bar. Radius pill substitutes `{radius}` param in `homeNearbyMapRadius`.
4. **Manual scroll.** Settings auto-scrolls its `SingleChildScrollView` (`Scrollable.ensureVisible`) to
    the highlighted row in `SettingsReplica.didUpdateWidget`. The remaining scenes are static.
5. **Highlightids** (= beat `highlight`) must match a region id in the scene. Region ids
    (manual scroll targets / dim regions): `hero steps status stats recents filters map radius
    users cards expiry sort list total markers interests photos verify edit calendar
    tour display matching prefs invisibility notifs paywall billing invite security account
    entry`. Beats follow visual top-to-bottom order within each chapter (no bouncing);
    intent filters are narrated once (`Matches4`, covering both Matches and Chats).
6. **Live demos, not instructions.** The online toggle auto-plays online → invisible
    → online while spotlighted, timed to fractions of the spoken utterance
    (`VoiceGuidanceService.spokenText`, subtitle-paced fallback when muted);
    intent chips really filter their lists (All restores).
    Narration describes what the wizard shows, never asks the user to tap the mock.

## Verification

- Transcription/translation drifts: `node scripts/check_onboarding_translations.js`,
  `node scripts/check_onboarding_key_usage.js`, `node scripts/check_onboarding_hardcoded_text.js`
- Renders every beat in en/es/he inside a phone frame, asserts real narration strings are
  present and no overflow/exceptions: `flutter test test/onboarding`
- Static: `flutter analyze lib/screens/onboarding/onboarding_scenes.dart`