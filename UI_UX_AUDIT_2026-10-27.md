# MatchMe — Full UI/UX Audit, 27 October 2026

**Method:** design-system measurement (grep census across all 405 Dart files / 233k lines) + full-file read audits of 53 screens and 76 shared widgets, organised into six domains. Four domains (auth/onboarding, shell/home/matches, chat, events/meetup/maps) were audited screen-by-screen in depth. Two (profile/settings, monetization/notifications) were covered by direct structural inspection, not a full read — flagged in §9.

**Relationship to prior docs:** this supersedes nothing. `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` (28 Sep) remains authoritative on the two-lane match model and the 24h commitment filter, and its product constraints are respected throughout — no swipe deck, no browsing, no likes, no removal of the countdown, no exposure of un-matched users' locations or identities. This document's job is to record **what changed in the last month**, and to add the screen-level detail the September audit did not reach.

---

## 1. Verdict

MatchMe's problem has moved. In September it was "the app has no design system." **It now has a design system and the app isn't using it.** The token layer, a semantic-colour extension, button/card/component style classes, an AMOLED theme and a Material 3 shell all exist and are genuinely well-built — and roughly 80% of the UI still renders stock Material defaults because nothing imports them.

The second half of the verdict is the more uncomfortable one: **the screens that carry MatchMe's entire differentiator — the match moment, the map, the meet-up — are the least designed surfaces in the app.** A proximity product whose hero moment is a five-second toast, whose spatial data is rendered as text, and whose chat cannot send a photo, looks like a well-engineered database regardless of how good its tokens are.

Nothing here needs a rewrite. The logic layer (offline Hive sync, encrypted chat, four-provider calendar sync, the privacy-preserving map aggregation, three-locale enforcement including RTL) is stronger than most apps in the category, and the audit found several surfaces already at or above benchmark. This is presentation work, and it is unusually tractable because the foundations were laid in October.

---

## 2. Already at or above benchmark — protect these

Credit first, because a redesign that regresses these is a net loss.

| Surface | Why it's good |
|---|---|
| **The chat filter sheet** — `lib/widgets/list_filter_bar.dart` | `HapticFeedback.selectionClick` on every control (`:746, :862, :897, :939, :966`), removable state pills, sticky 52px "Show N results" CTA (`:982-1028`), `liveRegion` result count (`:1373-1394`), 48×52 filter button (`:547-593`). This is best-in-class and it proves the team can do it. |
| **In-message translation** | Pending-placeholder bubbles, translated-text-as-hero with original secondary, scroll-anchored toggle (`chat_screen.dart:336-472`), search over original *and* translation. No benchmark app has this. |
| **The narrated onboarding tour** | TTS-synced beats inside replica phone frames, captions, chapter dots with proper `Semantics(button/selected)` (`onboarding_intro_screen.dart:523-527`), per-section contextual prompts, replayable from Settings. Genuinely novel. |
| **Localisation** | **Zero** hardcoded English `Text('…')` literals across all 53 screens; everything routes through `l10n.getString`. RTL is handled centrally (`locale_provider.dart:53, :114`). This is rarer than it sounds. |
| **Dark + AMOLED theming** | Full dark `ThemeData`, AMOLED surface ramp, synced across devices (`app_theme_tokens.dart:78-85, :308`). |
| **Privacy-preserving map rendering** | Avatar-free aggregated cell bubbles, deterministic ≤30 m jitter with FNV seeding (`nearby_map_screen.dart:990-1075, :815-838`), pin-free coverage-circle mini-maps, payload-free deterministic beacon identity, server-side attendee resolution under RLS. The map screen is the most carefully-designed surface in the app. |
| **Optimistic send** | Instant composer clear + refocus + bubble insert (`chat_screen.dart:1418-1427`), read-receipt lifecycle gating, offline outbox. |
| **`SafeText` / no-truncation policy** | `safe_text.dart:1-33` — a deliberate accessibility stance, not an accident. |
| **`AppSkeletonBox`/`AppEmptyState`** | Shimmer honours `disableAnimations` and excludes semantics (`app_skeleton.dart:37-48, :65`). The components are correct; call sites just don't use them. |
| **Wizard progress header** | `LinearProgressIndicator` + "Step X of Y" + a live profile-completeness chip + `Semantics(container, label, value)` (`profile_wizard_screen.dart:10124-10172`). Good. |

---

## 3. Root cause: the system exists and isn't wired in

This is the highest-leverage finding in the document because almost every symptom below traces back to it.

### 3.1 The components were built and never imported

| File | Lines | Importers | Verdict |
|---|---|---|---|
| `lib/theme/app_theme_tokens.dart` | 463 | 8 | Partially adopted |
| `lib/theme/semantic_colors.dart` | 66 | 13 | Adopted, but defines **only `success`** |
| `lib/theme/app_button_styles.dart` | 166 | 3 | 18 call sites, all in **2 of 53 screens** |
| `lib/theme/app_component_styles.dart` | 430 | **0** | **Dead code** |
| `lib/theme/app_card_styles.dart` | 171 | **0** | **Dead code** |

601 lines of design system have literally never been referenced. `AppButtonStyles` is used in `email_change_screen.dart` and `invisibility_rules_screen.dart` and nowhere else.

### 3.2 `ThemeData` configures 10 sub-themes and omits 17

Configured: `appBarTheme`, `inputDecorationTheme`, `textTheme`, `cardTheme`, `chipTheme`, `navigationBarTheme`, `dividerTheme`, `filledButtonTheme`, `elevatedButtonTheme`, `outlinedButtonTheme` (`app_theme_tokens.dart:191, :270, :293, :320, :406, :427`).

**Not configured, so every instance falls through to stock Material:** `dialogTheme`, `snackBarTheme`, `bottomSheetTheme`, `listTileTheme`, `switchTheme`, `sliderTheme`, `radioTheme`, `checkboxTheme`, `progressIndicatorTheme`, `tooltipTheme`, `badgeTheme`, `popupMenuTheme`, `segmentedButtonTheme`, `expansionTileTheme`, `pageTransitionsTheme`, `textButtonTheme`, `tabBarTheme`.

Mapped against real call-site volume, this is why the app feels generic:

- **114 `showDialog`** calls with no `dialogTheme` → default Material 2-looking dialogs everywhere.
- **245 `showSnackBar`** calls with no `snackBarTheme` → and most pass raw `backgroundColor: Colors.red / Colors.green / Colors.orange.shade700`.
- **121 `CircularProgressIndicator`** with no `progressIndicatorTheme` → default spinners, against an existing shimmer system nobody calls.
- Every settings row, every switch, every bottom sheet, every popup menu = framework default.
- **No `pageTransitionsTheme`** → every screen change uses the stock Material slide-through. For a photo-centric social app this alone costs most of the perceived quality.

### 3.3 The measured debt, one month on

| Signal | 28 Sep | 27 Oct | Direction |
|---|---|---|---|
| Files under `lib/` | 324 | 405 | +25% |
| Hardcoded `Colors.*` (outside theme) | 1,216 | **654** | **▼46% — real progress** |
| Hardcoded `fontSize:` literals | 407 | **440** | ▲ worse |
| Distinct `fontSize` values | — | **26** (6.5 → 32) | no type scale |
| Text below 9px | — | **33 occurrences** | WCAG 1.4.4 fail |
| `textScaler` references | 0 | **10** | ▲ but ~0 |
| `Semantics(` | 50 | 63 | ▲ |
| `semanticLabel` | — | **9** | icon-only buttons are silent |
| `MaterialTapTargetSize.shrinkWrap` | 13 | **15** | ▲ worse |
| `HapticFeedback` | 1 | **6** | ▲ but ~0 |
| `Hero(` | — | **0** | no shared-element transitions anywhere |
| `AnimatedContainer`/`Switcher`/`Opacity` | 10 | **20** | across 233k lines ≈ no motion system |
| `showSnackBar` | — | **245** | no unified toast |
| `OrientationBuilder` / breakpoints | — | **0 / one (900px)** | 6 shipping platforms, 1 layout |

**Interpretation:** colour debt halved, everything else moved sideways or backwards. The type scale was never built, and text scaling, motion and haptics are still essentially absent. `profile_wizard_screen.dart` grew from 11,184 to **12,601 lines** — the single largest UI file in the app and the one users must survive to reach the product.

### 3.4 Typography is structurally capped

`pubspec.yaml` ships **Noto Sans Regular (400) and Bold (700) only**. There is no Light, Medium, SemiBold or Black. A modern type hierarchy is built from weight × size × colour; with two weights available, the only remaining lever is size — which is exactly why the census found 26 distinct sizes and 6.5px text. **You cannot fix the type system without adding weights.** This is the cheapest, highest-return visual change in the document.

### 3.5 Contrast: the tokens pass, the bypasses don't

Verified by computation on the token values themselves:

| Pair | Ratio | WCAG |
|---|---|---|
| `lightPrimary #4F46E5` + white | 6.29:1 | ✅ AA |
| `darkPrimary #818CF8` on `darkSurface #0F172A` | 5.99:1 | ✅ AA |
| `darkOnSurfaceVariant #B7C3D9` on `darkSurface` | 10.06:1 | ✅ AAA |
| `lightSecondary #EC4899` + defined `onSecondary #3D0723` | 4.75:1 | ✅ AA (barely) |
| `lightSecondary #EC4899` + **white** | 3.53:1 | ❌ fail |
| `lightTertiary #F59E0B` + **white** | 2.15:1 | ❌ fail — and **`lightOnTertiary` is not defined** |

`colorScheme.tertiary` is used as an accent in `home_screen.dart:256, :263, :836`, `main_navigation_screen.dart:381`, `notification_inbox_screen.dart:762, :766` — with no guaranteed on-colour, so any white text or icon on it fails hard.

Concrete failures found in screens:
- `match_box.dart:650-660, :897-985` — `onSurface` at **alpha 0.55** on 12–13px meta text ≈ **3.5:1** ❌
- `new_user_badge.dart:37-58` — white 12px on `Colors.green` ≈ **2.8:1** ❌
- `offline_indicator.dart:22-38` — `amber.shade800` on `amber.shade100` with **no dark variant at all**
- `calendar_sync_screen.dart:333-351` — `orange.shade100` bg + `orange.shade800` text at fontSize 10 ❌ dark
- `beacon_screen.dart:240-336` — expired state white @0.4 on black ≈ 3:1 ❌
- `chat_list_item.dart:448` — timestamp in `disabledColor`, not contrast-guaranteed in either theme

---

## 4. Domain findings

### 4.1 Shell, Home, Matches

**Shell** (`main_navigation_screen.dart`). Material 3 `NavigationBar` with `NavigationRail` above 900px, `IndexedStack` state preservation, per-tab scroll controllers, re-tap-to-top — all correct. The problems:

1. **A 112px-tall app bar on every tab.** `preferredSize = kToolbarHeight + 56` (`:1344-1348`) hosts the visibility/connectivity status strip: ~11 chips and labels at `fontSize: 11` (`:215-220, :259-264, :308-313, :348-352, :373-377, :412-416, :447-451, :498-510`) and a `Switch` shrunk with `Transform.scale(0.8/0.88)` + `shrinkWrap` (`:231-241, :277-287, :454-467, :517-528`) → effective target far below 48dp. This is the September recommendation that was not implemented, and it still eats ~15% of the viewport on every screen.
2. **Logout sits permanently in the app bar** with an error-tinted background (`:1430-1452`) — a once-a-year destructive action given top real estate on all five tabs.
3. **Zero tab-transition motion.** `IndexedStack` hard-swaps (`:1197`).
4. **RTL badge bug.** The app-bar badge uses `PositionedDirectional` (`:1377-1398`) but `_NavBadgeIcon` uses physical `Positioned(right: 0, top: 0)` (`:1761-1796`) — in Hebrew the tab badge lands on the wrong side. Badge text is `fontSize: 8.5` (`:1391`).
5. Deep links only restore the last tab (`:896`); no route into a specific match or chat.

**Home** (`home_screen.dart`) is still a dashboard: greeting → completeness banner → pinned-location card → live-location card → three stat tiles → Recent Matches → Recent Chats → inline ad. No face, no photo, no hero above the fold. Three specific defects:
- `error: (e, s) => const SizedBox.shrink()` for both the matches and chats streams (`:1601, :1994`) — **sections silently disappear**, no message, no retry.
- `_buildEmptyList` is plain centred text with no CTA (`:962-972`) while the filtered path correctly uses `AppEmptyState` with a clear-filters action (`:1570-1583`).
- Skeletons for lists (`:950-960`) but literal `"..."` strings inside stat cards (`:1244, :1290`).

**Matches** (`matches_screen.dart` + `match_box.dart`). Rows sit in one `Card(elevation:2)` with `Divider(height:1)` (`match_box.dart:1449-1473`): 56px avatar, name 16 bold, 13px icons, 12px meta at alpha 0.55, 11px chips. Three issues:
- **The list is not lazy** — every row is built in a `SingleChildScrollView` + `Column` (`:497-513`). Jank grows with match count.
- **The expiry row deletes itself.** `match_box.dart:142` returns `SizedBox.shrink()` when `remaining <= Duration.zero` — the September `missed`-state recommendation, still unbuilt. For a proximity product this is the most likely outcome of the headline scenario, handled by erasure.
- Rating stars `Colors.amber.shade700` (`:1361`), SnackBars `Colors.green/red.shade700` (`:309, :338`), retro banner `Colors.teal.shade700` (`:787-800`) — all bypass tokens.

**The match moment** (`match_notification_overlay.dart`). Technically sound: 500ms `easeOutBack` slide-in (`:49-59`), `HapticFeedback.mediumImpact()` (`:91`), reduced-motion respected (`:95-123`), `Semantics(liveRegion: true)` (`:247`), gradient radius 16, 60px avatar. But it is a **notification, not a celebration** — 5s auto-dismiss (`:104-110`), no full-screen moment, no confetti, no sound. The app already ships `confetti: ^0.8.0` and uses it for birthdays (`birthday_overlay.dart:3, :88-99`), so the peak emotional event of a dating product gets less theatre than a birthday.

**Match profile** (`match_profile_screen.dart`, 4,747 lines). ~15 stacked `Card` sections in one flat list, bottom actions `Chat/Meet/Unmatch` at `Size(0,48)`. Photos — the primary attraction surface — are a **140px-tall strip of 140×140 radius-8 thumbnails** (`:1796-1877`) with a `Colors.black54` "Primary photo" overlay at white fontSize 10, opening via `showDialog` with no hero transition (`:1580-1594`). Sub-48dp targets at `:2449-2463` (compact `IconButton`, 18px icon, `EdgeInsets.zero`), `:4151-4158` and `:4638` (`Size(0,32)`). The worst token drift in the app: `Colors.purple.shade700/50` (`:2822-2868`), `Colors.teal` (`:2871-2920`), `Colors.pink/blue` social links (`:3735-3769`), `Colors.blue[50]/[200]/[800]` (`:3386-3435`), `Colors.green[50]/[200]/[700]` (`:3589-3675`). Zero haptics in 4,747 lines.

### 4.2 Chat — the highest-traffic screen, and the largest feature gap

The bubble palette is a faithful WhatsApp clone (`#D9FDD3`/`#005C4B` outgoing, `#FFFFFF`/`#1F2C34` incoming at `chat_screen.dart:3798-3801`, cream canvas `#EFEAE2`/`#0B141A` at `chat_background.dart:30-41`), radius 12 with a 4px tail-corner, time + ticks inside. Visually credible. Substantively it is **text-only**.

Ranked by user impact:

1. **There is no media at all.** `ChatMessageModel` has no image, video, voice-note, location, contact or link-preview type. Bubbles render through `RichText` with emoji spans only (`:2241-2247`). No photo in a dating app's chat is the single largest parity gap in this audit.
2. **No failed-message state.** Status covers pending/sent/delivered/read (`:3812-3843`) but a send error only fires a SnackBar (`:1502-1509`) and **the bubble stays on `watch_later` forever**. No red `!`, no tap-to-resend. In an app asking two strangers to arrange a physical meeting, a silently-undelivered message is a trust-destroying event.
3. **No bubble grouping.** Every bubble gets identical 4px vertical padding, full 12px radii (`:4067-4072, :4094-4106`) and a repeated timestamp + ticks (`:4270-4351`). Grouping is *the* visual signature of WhatsApp/Telegram polish. `otherUserLastReadAt` is already computed and threaded in (`:2308-2318, :3493`) but never rendered — dead plumbing for a "read up to here" divider.
4. **RTL is broken inside the conversation** — physical `Alignment.centerRight/centerLeft` (`:4076-4077`), physical `EdgeInsets.only(left: 56 / right: 56)` (`:4067-4072`), physical `Border(left:)` on both quote blocks (`:3179-3184, :3655`). Hebrew is a first-class, DB-enforced locale; sent messages do not change side. By the owner's own rule this is a defect, not a divergence.
5. **No attachment/camera/mic entry point.** The composer row is emoji | text | send (`:3306-3411`); `canSubmitChatComposer` is literally `!isSending && text.trim().isNotEmpty` (`chat_composer_utils.dart:1-3`).
6. **The emoji picker is a fixed 300px slab** appended to the Column (`:3015-3059`) with no keyboard-height sync and no animation — switching keyboard↔picker visibly jumps the whole conversation.
7. **No swipe-to-reply, no anchored long-press sheet, no selectable text.** Long-press opens a full bottom sheet (`message_options.dart:29`); `RichText` blocks selection.
8. **Header wastes its status line.** "You are chatting with" is permanent caption text (`:2386, :2451-2464`) where WhatsApp/Telegram show online/last-seen/typing — and `is_online` data already exists (`home_providers.dart:4020`).
9. **Conversation list:** no swipe actions anywhere, and **no pin or mute at all** — `ChatModel` has only `archivedAt` (`chat_model.dart:52`). Rows are ~90px shadowed cards with 16px margins (`chat_list_item.dart:254-277, :333`) against WhatsApp's flat full-bleed ~72px — ~25% fewer conversations per screen, and the card chrome fights the unread border highlight. No date section headers. Search chrome is permanently stacked above the list (`:553-714`). Returning from a chat invalidates the whole list provider (`chat_list_item.dart:327-330`).
10. **Screen-reader semantics are the wrong shape.** `Semantics(container: true, button: true, label: primaryText)` (`:4054-4060`) announces *"Hey, button"* — no sender, no time, no delivery status in the read-out. WhatsApp announces "You sent, message, 3:42 PM, read."
11. **Performance/hygiene in the hottest screen:** `_chatFlickerDiagnosticsEnabled = true` (`:75`) drives `debugPrintSynchronously` on every bubble state change and every scroll frame (`:84-96, :2862-2884, :3983-3989`) on the UI isolate in release; `_searchMessageKeys` accumulates a `GlobalKey` per built message even when not searching and never prunes (`:268, :2926-2930`); the list renders the **entire decrypted history** with no windowing (`chat_provider.dart:469-490`). The chat canvas and bubbles also hardcode their palette, so **AMOLED users get `#0B141A` instead of true black in the one screen where it matters most**.
12. `PendingMutationsIndicator`'s detail sheet renders raw internals to end users — `"RPC mark_messages_as_read"`, mutation ids, raw errors (`pending_mutations_indicator.dart:201-252`).

### 4.3 Events, Meet-up, Maps

The map is the most technically accomplished screen; events and meet-up are the least designed.

**Events list** (`events_screen.dart`): text-only cards with **no image, no attendee avatars, no distance** (`:1084-1236`), rendered as label-column tables (96px label column, `fontSize: 14` hardcoded, alpha 0.85/0.7 text at `:1031-1072, :1428-1467`). The overlapping-avatar stack already exists (`event_matched_attendees.dart:56-106`) and is simply not mounted. Settings switches and import buttons sit **above** the event list (`:650-871`), pushing events below the fold. No calendar view, no date or category chips — only a "show past" switch (`:728-755`). Loading is a bare spinner (`:979-988`) despite `AppSkeletonBox` existing.

**Event "detail"** is `attendees_screen.dart` — no hero, no map preview, **no RSVP, no invite**. It has `EventMatchedAttendees` ListTiles (`:503-648`) and a deep-link to Google Maps (`:406-452`), with `Colors.black.withValues(alpha: 0.05/0.04)` shadows that vanish in dark mode (`:309-321`).

**Add event** (`add_event_screen.dart`): the three input modes with `Semantics` selected-state are good (`:1032-1168`), but venue is a bare `TextFormField` (`:850-867`) with **no place autocomplete** while the OSM/Google landmark providers already exist for meet-up suggestions; **no cover photo**; stock `showDatePicker`/`showTimePicker` (`:450-487`); a hardcoded English date format `DateFormat('EEE, MMM d, yyyy')` (`:1220-1227`); end time silently `start + 1 hour` with no visible field (`:649`); and **two sequential confirm dialogs** before save (`:574-598, :551-570`) when the good privacy disclosure card (`:497-549`) could absorb both. 13 raw `Colors.orange/blue/red/green` SnackBars.

**Calendar import**: `calendar_sync_screen.dart` and `online_providers_screen.dart` contain **~450 duplicated lines** of detection/normalization (`:670-1002` ≈ `:117-464`) plus two near-identical event cards (`:248-523` ≈ `:2328-2562`), now drifting — an 82px label column in one, 96px in the other. No visible step indicator; back on step 1 does `popUntil(isFirst)` (`:1794-1800`), a surprising full-tab exit; `lastSyncedAt` is stored (`:711, :829, :1448`) and never displayed. `apple_calendar_import_screen.dart`'s help URL exists only for en/es (`:32-38`) — **Hebrew users get English Apple support**.

**Nearby map**: privacy-correct and well-built, but a **144px app bar** (`:1274-1394`), **no bottom sheet or detents at all** — selected-cell info floats at `bottom: 120` (`:1679-1722`) while the recenter FAB sits at `bottom: 110` (`:1595-1622`), the collision-prone absolute-positioning pattern modern map apps abandoned. No layers, no compass, no accuracy ring. `OnlineWorldMapScreen` country pills are wrapped in `IgnorePointer` (`:3133-3201`) — untappable data with no Semantics.

**Location share**: consent and duration UX are solid (config-driven 15/30/60/120 + "until I turn it off" with second confirm, `location_share_duration_dialog.dart:91-126`). But the status badge is **hardcoded English `'LIVE'/'PAUSED'/'STOPPED'`** at white 10px on `Colors.green/orange/red/grey` (`:476-516`) — untranslated and colour-only; scale-bar labels `'10 m'…'10 km'` are hardcoded with no imperial despite `unitSystemProvider` existing (`:689-750`); all overlays are `Colors.black` @0.5-0.75 ignoring theming (`:371-428, :649-687, :1052-1125`); bottom controls are bare `GestureDetector`s with no ripple (`:752-907`); and `LatLngSmoother` animates only your own marker (`:200-218`) so **the partner marker teleports** each realtime tick.

**Meet-up hub / plan flow**: the proposal step is a **`CheckboxListTile` list with no map** (`meetup_screen.dart:477-587, :914-931`). The active view has **no countdown to the agreed time**, no arrival celebration, no "they're nearby" cue. Hub accents hardcoded via `accentInk` (`meetup_hub_screen.dart:363-372`); header has no partner avatar (`:533-586`).

**Beacon**: the deterministic colour+shape identity (6 colours × 5 shapes, `beacon_screen.dart:20-27, :109-193`) is a genuinely clever payload-free design — and the September doc's most valuable structural idea still isn't wired. The pulse animation (`:52-107`) **ignores `disableAnimations`** even though the nearby map honours it. **There is not one `HapticFeedback` call anywhere in the meetup or location code.** Feed items appear with no entrance animation (`meetup_coordination_widgets.dart:533-641`); the incoming beacon card is static (`animate: false`, `:207-266`); the alert-dismiss target is ~30px (`meetup_alert_overlay.dart:103-116`).

**Duplication**: three copies of `_ScaleBarPainter` (`match_location_mini_map.dart:743-789` and two more — only one localized and imperial-aware), three copies of zoom controls, three of `_formatDateOnly`.

### 4.4 Auth and first-run

**Structural problem: value comes last.** The tour is the *reward* for finishing auth → OTP → the entire profile wizard (`onboarding_content.dart:24-26`, `main_navigation_screen.dart:706`). **There is no pre-auth welcome flow** — no value proposition, no one-tap entry, no social proof — before any product is shown. This is the single biggest activation lever in the scope and it is currently inverted.

`auth_screen.dart` (3,135 lines):
- **Dark-mode-broken error states**: `Colors.red.shade50` fill + `shade200` border + `shade700` icon + `shade800` text (`:3005-3037`), password field `red.shade50`/`red.shade400` (`:2429-2432, :2772-2786`). `colorScheme.errorContainer/onErrorContainer` exist and are ignored.
- **No autofill.** Email, password and confirm declare no `autofillHints` and aren't in an `AutofillGroup` (`:2694-2742, :2762-2845, :2920-2970`) — disabling Android Credential Manager and iOS AutoFill. The OTP screens do it right (`signup_email_code_screen.dart:237`), so the pattern is known.
- **Signup is remotely gated**: password fields are `readOnly` until server email-screening approves (`:2765, :2923`), CTA disabled (`:2974-2976`), explained only in helper text. Offline, this reads as a broken form.
- **Three competing mode toggles** on one screen (`:2589-2638, :2640-2692, :3089-3098`) instead of one `SegmentedButton`.
- **Two permanently dead OAuth buttons** — Apple and Facebook render `isUnavailable: true` (`:3073-3087`), ~25% of the screen un-actionable.
- Loading replaces the whole body with logo + spinner (`:2535-2545`). The CTA is mid-scroll after ~600px of content with **no pinned bottom bar** — with the keyboard open on a small phone, submit is off-screen. `textStyle: const TextStyle(inherit: false)` on the CTA (`:2979, :2988`) discards the theme's font family and size.
- **Production debug surface**: double-tap on the error banner reveals raw developer error text (`:2996-3003`); 7-tap on the logo opens a debug sign-out dialog (`:2327-2338, :2556-2564`).

**OTP screens**: a single-line `TextFormField` instead of 6 segmented boxes, and **no auto-submit on the sixth digit** (`signup_email_code_screen.dart:233-255`) — every benchmark app verifies the instant the code completes. The resend cooldown isn't armed on arrival (`_lastResendAt` starts null, `:29`, `password_reset_otp_screen.dart:38`), so the first tap orphans the code already in the inbox — the exact failure their own comment warns about. Success is a green SnackBar + `popUntil`. The reset screen's back button resets `_otpVerified = false` and forces re-verification (`:291-303`) — a trap for Android system-back.

**Cold start**: `profile_check_screen.dart:198-209` holds the user on a **silent pulsing logo** with no copy, no progress, no skeleton (8s watchdog at `:71`, 30s ceiling). On a cold cache after the wizard, a user can watch a logo pulse for many seconds and churn. The reduce-motion handling in the loader (`startup_loader.dart:139-148`) is correct and deserves credit.

**The tour's own defects**: replica text at `fontSize: 7.5 / 6.5 / 7 / 8` (`onboarding_scenes.dart:388, :422, :989, :493`) — illegible and blind to text scaling. The fake status bar, battery icons, demo chat rows and settings labels are **real `Text`/`Icon` widgets with no `ExcludeSemantics`**, so screen-reader users hear decorative fake content interleaved with narration. Chapter dots are ~14×8dp (`onboarding_intro_screen.dart:529-542`), ~1/3 of minimum. `_WorldMapPainter` paints a **light `0xFFD4EBF4` sea in both themes** (`onboarding_scenes.dart:1501, :2174`) — verified — a blinding pale rectangle inside a dark phone frame. The intro's `AnimatedSwitcher` (`:358-374, :431-447`) does not check `disableAnimations` even though the scenes' `HighlightableRegion`/`GentlePulse` do. Beats advance only by button/TTS — no swipe. The finish beat is a static gradient circle + `Icons.celebration_outlined` (`:3641-3675`) — no confetti, no haptic.

**Dead scaffolding**: `captcha_widget.dart:20-22` and `password_requirement_checker.dart:14-16` both render `SizedBox.shrink()`; `auth_entry_point.dart:20-22` takes an `onToggle` it never uses. Password-requirement logic is copy-pasted three times (`auth_screen.dart:171-183`, `password_reset_otp_screen.dart:66-78`, `:91-118`).

### 4.5 Profile and Settings *(structural inspection — see §9)*

**Settings IA has genuinely improved** since September: `settings_screen.dart` now groups items (`settingsSectionGeneral`, `settingsSectionMatching`, `settingsNotifications`, `settingsSectionPremium`, `settingsSectionAccount`), each with a label **and a description**, plus a **settings search** (`:240-260`), and `arrow_forward_ios` is gone (replaced by RTL-aware `directionalForwardIos`).

What's left on that screen: `_buildMenuCard` (`:169-236`) renders **each row's title in that row's own accent colour at fontSize 18 bold**, with a gradient tint, a bordered container and a coloured chevron — a rainbow list rather than a hierarchy, and the card shows no **current value** (you can't see your radius or visibility state without tapping in). 60 hardcoded `Colors.*` across `lib/screens/settings/`; `account_management_screen.dart` alone uses `Colors.red`/`Colors.green` SnackBars at `:123, :557, :569, :628, :643, :721, :743`.

**The profile wizard is still the funnel's biggest hole** — and it has grown to **12,601 lines**. It keeps 28 `showSnackBar` validations with **zero `errorText`** — validation fires as a transient bar rather than attached to the offending field. 69 hardcoded colours. The progress header is good (§2); the per-field feedback is not.

**Profile photos mirror the match-profile problem** — `profile_screen.dart:1013-1054` uses the same 140×140 thumbnail strip, so both your own profile and someone else's present faces at postage-stamp size.

### 4.6 Monetization and Notifications *(structural inspection — see §9)*

**Paywall: two of the three September trust defects are fixed** — the hardcoded white scaffold is gone (0 `Colors.white`), and SnackBars now use `semantic.success` / `colorScheme.error` (`paywall_screen.dart:364, :499, :513`); the Terms/Privacy links are wired (a comment at `:1643` records the fix). **The third is not**: `bool get _supportsNativePurchases => false;` (`:38`) still hard-disables native purchases, and when no external checkout URL is configured the app **silently simulates a successful purchase** (`:319-332`, verified). A user who "buys" Gold on web/desktop today receives money-for-nothing behaviour in code. Also still present: helper text at `fontSize: 8` (`:1223`).

**Ads remain inside the decision surfaces** — `AdSlot` is placed in `matches_screen.dart:509`, `chats_screen.dart:788, :802`, `events_screen.dart:949, :964`, `home_screen.dart:2046`, `profile_screen.dart:2539`. An ad directly beside "this person is 40 m away" is a credibility problem for a product that asks people to meet strangers physically.

**Notification inbox** (`notification_inbox_screen.dart`) is clean — 1 hardcoded colour, `_InboxRow`/`_InboxTypeIcon`/`_InboxDetailSheet` structure — but has **no date or type grouping, no collapse of repeated notifications, and no mark-all-read**, which the project's own notification-experience goals call for.

**Verification** (`verification_screen.dart`) contains no haptics and no meaningful animation — the flow that establishes "this is a real person" is inert.

---

## 5. Scorecard against 2026 category norms

| Dimension | State | Gap severity |
|---|---|---|
| Design tokens exist | ✅ built Oct 16-19 | — |
| Tokens actually adopted | ❌ 601 dead lines, 8/53 screens | **Severe — root cause** |
| Type system | ❌ 26 sizes, 2 weights, 33 sub-9px | **Severe** |
| Text scaling (WCAG 1.4.4) | ❌ 10 refs, 15 `shrinkWrap` | **Severe — non-compliant** |
| Touch targets (WCAG 2.5.8) | ❌ 6+ classes under 48dp | **Severe** |
| Contrast in dark/AMOLED | ❌ ~40 hardcoded light-only surfaces | **Severe** |
| Motion system | ❌ 0 `Hero`, 20 animated widgets, no `pageTransitionsTheme`, no haptics | **Severe** |
| Chat feature parity | ❌ no media, no failed state, no grouping, no pin/mute/swipe | **Severe** |
| Match moment craft | ❌ 5s toast; confetti package unused | **Severe** |
| Spatial presentation | ⚠ good map, but text-first lists, no detents, no meetup map | High |
| Events as a product surface | ❌ text-only cards, no RSVP, no detail screen, no cover | High |
| First-run order | ❌ value last; no pre-auth welcome | **High — activation** |
| Cold-start feedback | ❌ silent pulsing logo, no progress | High |
| Autofill / OTP automation | ❌ none on auth; no auto-submit | High |
| Validation UX | ❌ 245 SnackBars app-wide, 0 inline `errorText` in wizard | High |
| Responsive/adaptive (6 platforms) | ❌ one 900px breakpoint, 0 `OrientationBuilder` | High |
| Silent failures | ❌ `SizedBox.shrink()` on Home errors; permanent pending bubbles | High |
| Screen-reader semantics | ⚠ 63 `Semantics`, only 9 `semanticLabel`, fake tour content exposed | Moderate-High |
| RTL | ⚠ central support excellent; 46 physical `EdgeInsets.only`, broken chat bubbles, wrong-side tab badge | Moderate |
| Localisation coverage | ✅ 0 hardcoded English literals | **Strength** |
| Dark/AMOLED architecture | ✅ full theme, AMOLED ramp | **Strength** |
| Privacy-preserving UI | ✅ aggregation, jitter, pin-free, payload-free beacon | **Strength** |
| Offline / encrypted chat | ✅ real, at benchmark | **Strength** |

---

## 6. Visual direction — three choices

This is a decision only you can make, so it is framed as experience, not code. Everything in Batches 0-2 below is direction-independent; the choice only changes Batch 3+.

**Option A — "Quiet Slate" (evolve what exists).**
Keep the indigo/slate/pink palette and the current radius language; complete the token wiring, add Medium/SemiBold weights, replace elevation with tonal surface steps, keep 12/16 radii, and add one expressive move — a large photo-forward hero treatment on match cards and profiles.
*Feels like:* Telegram meets Hinge. Restrained, calm, legible, credible for an older demographic.
*Cost:* lowest risk, lowest differentiation. It will look like a very good 2026 utility app, not a distinct brand.

**Option B — "Presence" (spatial-first identity).**
Build the visual language around the thing Tinder cannot copy: space and time. Dark-mode-first, deep slate/near-black canvases, one high-chroma accent, distance and ETA as the largest numerals in the app (tabular figures), map chrome as the design system rather than a screen, soft radial glows instead of elevation shadows, photo-forward cards with full-bleed imagery and scrim text.
*Feels like:* Snap Map meets Apple Weather meets Bumble. The most "cutting edge" and the most on-brand for a proximity product; matches the September plan's spatial-card thesis.
*Cost:* larger visual jump, needs a real illustration/icon set, and dark-first needs care against the light-mode default.

**Option C — "Warm Human" (soft, editorial, low-gloss).**
Raise the radius scale, replace hard shadows with soft ambient ones, introduce a genuine 6-weight type pairing (display serif or rounded for names, Noto for body), illustrated empty states and onboarding scenes, generous whitespace, one warm accent + neutral chrome, motion everywhere with spring curves.
*Feels like:* Duolingo meets BeReal meets Are.na. The most inviting and least intimidating — strongest for retention and for users anxious about dating apps.
*Cost:* furthest from the current look; needs an illustration library (the app currently ships **only `logo.png`, `logosmall.png` and provider logos** — zero illustrations or custom icons), which is real art-direction work.

**My recommendation: B, borrowing C's warmth.** The product's differentiator is spatial and live; a restrained utility palette (A) under-sells it, and there is no brand equity to protect pre-launch. But keep Option C's typographic warmth specifically for match and profile cards, because the emotional risk to the user is real and a pure "map app" feel would be cold. Note that B and C both require the Batch 2 foundations regardless.

---

## 7. Recommended batches

Ordered so nothing is removed before its replacement is live (the Bumble lesson the September doc records: swipe killed May 2026, replacement slipped to 2027, revenue −15%/quarter). Each batch is independently shippable.

### Batch 0 — Credibility and correctness *(days; no design decisions needed)*
Nothing here is "modernization." These are defects that cost trust.

1. Kill the **silent simulated purchase** (`paywall_screen.dart:38, :319-332`) — real RevenueCat or an explicit "not available on this platform" state.
2. Remove production debug surface: **7-tap logo sign-out** and **double-tap raw error** (`auth_screen.dart:2996-3003, :2327-2338`) behind `kDebugMode`; `_chatFlickerDiagnosticsEnabled` → `false` and delete the synchronous prints (`chat_screen.dart:75-96`); prune the ~30 `print()` calls in events/map paths.
3. Give Home's two error branches a real message + retry instead of `SizedBox.shrink()` (`home_screen.dart:1601, :1994`).
4. Fix the **RTL tab badge** (`main_navigation_screen.dart:1761-1796` → `PositionedDirectional`) and **chat bubble mirroring** (`chat_screen.dart:3179, :3655, :4067-4077` → `EdgeInsetsDirectional`/`AlignmentDirectional`/`BorderDirectional`).
5. Localize `'LIVE'/'PAUSED'/'STOPPED'`, scale-bar units, `DateFormat('EEE, MMM d, yyyy')`, `pinnedFormatExpiry`'s `d.m.y`, and add the Hebrew Apple help URL.
6. Wrap the tour's phone replicas in `ExcludeSemantics` (`onboarding_scenes.dart`) so screen readers don't read fake content.
7. Add `HapticFeedback` to the meetup/beacon/location-share flow (currently zero calls) and honour `disableAnimations` in `beacon_screen.dart:52-107` and `BirthdayOverlay`.

*Blast radius:* all six platforms. *Effort:* S.

### Batch 1 — Wire in the system you already built *(1-2 weeks; the unblocker)*
1. Register the **17 missing sub-themes** in `app_theme_tokens.dart`. This single file change restyles 114 dialogs, 245 SnackBars, every list tile, switch, sheet, badge and popup app-wide, with no per-screen edits.
2. Add `pageTransitionsTheme` (shared-axis / fade-through) so tab switches and route pushes stop being stock Material.
3. Extend `SemanticColors` from success-only to a full status set: `success`, `warning`, `danger`, `info`, `live`, `missed`, `rating`, plus on-colours — including the currently-undefined `lightOnTertiary`.
4. **Delete or adopt `AppComponentStyles` and `AppCardStyles`** (601 lines, zero importers) in the same batch.
5. Add a lint rule forbidding new hardcoded `Colors.*` and `fontSize:` outside `lib/theme/`, then retire the 654 existing ones screen-by-screen.
6. Rebuild `SemanticColors`-driven snackbars via a shared `showAppToast()` so the 245 call sites stop passing raw `Colors.red/green/orange`.

*Blast radius:* app-wide visual, both themes + AMOLED. *Effort:* M. *Risk:* low — this is additive; nothing is removed.

### Batch 2 — Type, scaling, targets *(1 week; the compliance batch)*
1. **Add weights**: Noto Sans Medium (500), SemiBold (600) at minimum; consider a display face for names. This is the prerequisite for collapsing 26 sizes into a scale.
2. Define a 7-step type scale as tokens; map every `fontSize:` literal to it; **ban anything below 12sp** (33 occurrences today, incl. `fontSize: 6.5`, `8`, `8.5`, `10`, `10.5`, `11`).
3. Adopt a single `AppTextScaler` policy capping at 200% per WCAG 1.4.4, then audit the fixed-height containers that clip at 2x.
4. Remove all 15 `MaterialTapTargetSize.shrinkWrap`; raise every control to ≥48dp (the `Size(0,32)` buttons, 28×28 ad icons, compact 18px `IconButton`s, `Transform.scale(0.8)` switches, ~30px alert dismiss).
5. Fix the computed contrast failures: `onSurface` alpha 0.55 → `onSurfaceVariant`; `NewUserBadge` → `SemanticColors`; timestamps off `disabledColor`; add dark variants to the amber/orange offline and pending banners.
6. Make the tour replicas' text legible (≈+40% sizes) or render replicas as images with one semantic label.

*Blast radius:* app-wide; heavily affects the wizard, tour, settings, match rows. *Effort:* M.

### Batch 3 — Chat to benchmark *(2-3 weeks; highest user-visible value)*
1. **Failed-message state + tap-to-resend** — the trust fix (`chat_screen.dart:3812-3843, :1502-1509`).
2. **Photo/camera attachments and image bubbles** — model, encryption pipeline, composer, bubbles, list preview, notification. The largest parity gap.
3. **Bubble grouping** with last-bubble-only timestamps and tails; render the already-computed `otherUserLastReadAt` as a read divider.
4. **Composer rebuild**: pill container, `+` attach sheet, mic↔send morph, keyboard-height-synced emoji panel (replacing the 300px jump), character limit.
5. **Conversation list**: swipe actions, **pin + mute** (`ChatModel` needs the fields), read ticks in previews, flat full-bleed ~72px rows, date headers, collapsible search chrome.
6. **Presence + animated typing in the header**; kill the "You are chatting with" caption; dedupe `_TypingRow` vs `widgets/typing_row.dart`.
7. Long-press **anchored** context sheet (reaction strip above the bubble) + swipe-to-reply + `SelectableText`.
8. Header: unread divider + jump-to-first-unread, jump FAB with a count badge, sticky date headers, delete-for-everyone tombstones.
9. **Semantics rebuild per bubble** ("Maya, 3:42 PM, read, <text>"), drop `button: true`.
10. Theme-token sweep of the chat canvas so AMOLED gets true black; window history loading; prune leaked `GlobalKeys`.
11. Empty-state icebreakers instead of the bare string "Say hello" (`:3116-3122`).

*Blast radius:* chat on all platforms; #2 touches the schema and encryption path. *Effort:* L.

### Batch 4 — The match moment and spatial discovery *(2 weeks; most on-brand)*
1. **Full-screen match celebration** — both photos, `confetti` (already in `pubspec.yaml`), escalating haptic, "Say hi"/"Later", adaptive dwell with the reason shown ("staying longer: you're 30 m away"), collapsing to a dot rather than vanishing. Keep the existing overlay as the small form.
2. **`missed` state** replacing `match_box.dart:142`'s self-deletion — kept visible, non-blaming, precise ("You were both here Tuesday, 4:40 PM"), one-tap reconnect. Respects the 24h filter; only changes what happens *after* it.
3. **Spatial match card** as specified in September: 72-96px photo, **distance + bearing as the hero number**, and a human sentence with nouns instead of `Intent: rock_climbing`. `match_reason_formatter.dart` and `match_score_utils.dart` already exist.
4. **Occurrence as the headline trust signal**; raise the cap above 3. Data already exists (`MatchModel.matchOccurrence`, `match_model.dart:149`).
5. Replace the 600ms blink with a colour ramp + plain-language "going quiet in 8 min" + one-tap **Ask them to extend** — reframing the deadline as shared rather than lost.
6. **Photo-first match profile**: full-bleed segmented `PageView` header, `Hero` transition from the list (currently 0 in the app), vertical swipe to the next profile, ~15 sections collapsed into expandables/tabs.
7. Make the Matches list lazy (`ListView.builder`) — fixes the eager `Column` build.
8. Rebuild Home as **Now** per the September spec, and delete the app-bar status strip (Batch-4 item, not Batch-0, because the replacement must ship first). Move logout to Profile.
9. The **"why you're not matching more" diagnostic**, with the events lever, shipped *in the same release* as the settings restructure. Every number computed from live counts.

*Blast radius:* Home, Matches, overlay, shell, map — the product's core loop. *Effort:* L.

### Batch 5 — Events and meet-up *(2 weeks; the differentiator's second lane)*
1. Event card rebuild (hero image slot, mount `EventMatchedAttendees`, distance/venue line) + a **real event detail screen with RSVP / going / not-going and invite**.
2. **Bottom-sheet detents** on Nearby and Location-share maps — replaces the 144px app bar and the `bottom:110/120` FAB collisions.
3. **Map in the meet-up plan flow** (pins with proposer-only distances preserved — privacy invariant).
4. Countdown to the agreed time + an arrival celebration that offers the Spot selfie.
5. Extract shared `AppMapZoomControls` / `AppScaleBar` / `AppMapStatusBadge`; delete the three duplicate copies.
6. Unify the two calendar-import screens into one engine + picker with a visible step indicator.
7. Add-event: place autocomplete (reuse the landmark providers), cover photo, visible end time, one merged confirm.
8. Theme the location-share overlays; smooth the partner marker too.

*Blast radius:* events + meetup + maps. *Effort:* L. *Privacy:* all of it must keep cell aggregation, jitter, pin-free mini-maps, payload-free beacon, server-side attendee resolution.

### Batch 6 — First-run and accessibility completion *(2 weeks)*
1. **Pre-auth welcome flow** — 3 swipeable value pages before any field. Move value to the front.
2. OTP: 6 segmented boxes, `AutofillHints.oneTimeCode`, **auto-submit on the 6th digit**, cooldown armed on entry, expiry countdown, "Open mail app".
3. `AutofillGroup` + hints across auth; remove the `readOnly` email-screening gate; pin the CTA in a keyboard-aware bottom bar; button-level spinners instead of body replacement; one `SegmentedButton`; hide unavailable OAuth providers.
4. Give cold start a face — progress copy + skeleton feed, cap visible wait ~3-4s since data already streams (`profile_check_screen.dart:500-516`).
5. **Wizard: 28 SnackBars → inline `errorText`**, and collapse page count per the September 11→4 plan with the strength meter that already exists.
6. Settings rows: neutral titles + **current value shown in the row** (radius, visibility, tier) instead of rainbow accent titles.
7. Adaptive layout beyond 900px — tablet, foldable, landscape phone, and real web/Windows/macOS layouts (currently one breakpoint for six platforms).
8. `semanticLabel` on all icon-only buttons (9 today), `Semantics` on world-map pills and mini-maps, icon+text status instead of colour-only.
9. Move `AdSlot` out of Matches and Chats.

*Blast radius:* auth, wizard, tour, cold start, settings, layouts. *Effort:* L.

### Batch 7 — Delight *(ongoing, low risk)*
Surface E2E encryption in the chat header and match profile ("a genuine trust asset that is currently invisible"); make verification more prominent; add the "asked to extend" and "Met" verdict affordances; hero transitions app-wide; consider abstract-identity (avatar) profile mode as an *option*.

---

## 8. Two rules that should govern the whole effort

1. **Never remove a working interaction before its replacement is live.** Batch 4 deliberately ships the Now tab *with* the status strip's deletion, and the diagnostic *with* the settings restructure.
2. **Do not "fix" toward benchmark where the privacy model diverges from it.** Snap Map shows friends' avatars on pins; MatchMe must not. WhatsApp interpolates both markers freely; the partner marker must still respect share consent. If a benchmark pattern conflicts with `PRIVACY_PRESERVING_DESIGN_CONSTRAINTS.md`, the privacy doc wins — that constraint *is* the differentiator.

---

## 9. Coverage gaps — what still needs a device or a deeper pass

- **Profile/settings** and **monetization/notifications** were inspected structurally (§4.5, §4.6), not read line-by-line; the dedicated deep audits for those two domains failed on a credit ceiling. Specifically unexamined in depth: `profile_completeness_*`, `photo_editor_widget`, `verification_screen` internals, `billing_screen`, `subscription_payment_screen`, `invite_friends_screen`, the ad widget family, and `security_center_screen` / `sensitive_action_verification` flow quality.
- **Nothing here was rendered on a device.** All contrast figures are computed from source values, not measured from screenshots. Before Batch 1 lands, a visual pass on Android + iOS + web at 200% text scale and in AMOLED is worth doing — several findings (keyboard-over-CTA, emoji-picker jump, fixed `bottom:110/120` collisions) are only confirmable in motion.
- **No user testing.** The September doc flagged the Now tab as the highest-uncertainty bet in the plan; that remains true and is a 5-8 participant test, not a code question.

---

## 10. Verified ledger — concerns removed from the action list

Each line below was re-checked against the tree on 27 October 2026 rather than carried over. **Twenty-two recommendations from `UI_UX_DEEP_DIVE_AND_REDESIGN.md` and `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` are already implemented and are struck from the plan.** Four root causes are new to this audit and had not been named before.

### Struck — already fixed, do not re-open

| Was recommended (Sept) | Now verified as |
|---|---|
| Paywall hardcodes a white scaffold | fixed — full `scheme` + `tertiaryContainer`, 0 `Colors.white` (`paywall_screen.dart:364, :485`) |
| Terms / Privacy links are dead | fixed — wired (`paywall_screen.dart:1643`) |
| Debug `http.post` inside chat build | fixed — gone |
| Raw exception text surfaced to users | fixed — gone |
| `ScrollController` created in `matches_screen` build | fixed — now a field (`:57`) |
| Settings has no IA | fixed — grouped General / Matching / Notifications / Premium / Account (`settings_screen.dart:255-401`) |
| Settings is unfindable | fixed — search added (`:240`) |
| `Icons.arrow_forward_ios` as universal affordance | fixed — RTL-aware `directionalForwardIos` |
| Settings rows are bare | fixed — per-item descriptions on every row |
| Wizard has no progress affordance | fixed — bar + "Step X of Y" + live completeness chip + `Semantics` value (`profile_wizard_screen.dart:10124`) |
| Blink ignores reduced motion | fixed — countdown honours `disableAnimations` (`match_box.dart:202`) |
| 1,216 hardcoded `Colors.*` | reduced to 654 (−46%) |
| Localisation gaps | **0 hardcoded English UI literals** across the census |
| Extend is invisible to the peer | built — `NotificationType.matchExtended`, push + in-app banner |
| Locale drift | built — en/es/he enforced by DB `CHECK` + six edge functions |
| AlertDialogs everywhere | improving — 24 `showModalBottomSheet` sites now (114 dialogs remain) |
| Notification inbox is crude | `notification_inbox_screen.dart:297-400` is one of the best-built widgets in the tree |
| Map leaks identity | aggregation is avatar-free with `Semantics`; pulsing dot honours reduced motion |
| Bubbles have no tail | tail corner already drawn (`chat_screen.dart:4094`) |
| Beacon is colour-only | deterministic 6-colour × 5-shape identity, colour-blind-safe by construction |
| Dark mode fragile | properly implemented and device-synced — **do not regress** |
| Narrated tour should be cut | kept — it is better than most commercial apps; only Settings comes out of it |

### Still open from September (re-verified unfixed)

`missed` state (`match_box.dart:142`) · occurrence not surfaced and cap still 3 · no Now tab (`home_screen.dart:59, :196, :1241`) · app-bar status strip (`main_navigation_screen.dart:112-520`) · `Transform.scale` switches (`:231, :277, :454, :517`) · 5-second match banner · 600 ms blink (`match_box.dart:73`) · **We met / We didn't verdict absent** · going / not-going absent · `EventMatchedAttendees` built but never mounted · matching diagnostic absent · bubbles ungrouped (`chat_screen.dart:4067, :4270`) · `IntrinsicWidth` per bubble (`:4078`) · no pin / mute / swipe · failed send pending forever (`:3812`) · ads in Matches / Chats / Events×2 · 0 `Hero` · wizard is one 12,601-line file (grew from 11,184) with 28 SnackBars and 0 `errorText` · paywall `fontSize: 8` badge (`:1223`).

### New in this audit — root causes, not symptoms

1. **`pubspec.yaml` ships Noto Sans at 400 + 700 only.** With no weight axis, size is the only hierarchy lever, which is *why* the app measures 26 distinct `fontSize` values and 33 sites under 9 px. The type system cannot be fixed before the weights are added.
2. **17 `ThemeData` sub-themes are absent** (10 are configured): `dialogTheme`, `bottomSheetTheme`, `switchTheme`, `sliderTheme`, `snackBarTheme`, `tabBarTheme`, `tooltipTheme`, `progressIndicatorTheme`, `textButtonTheme`, `listTileTheme`, `badgeTheme`, `pageTransitionsTheme`, `segmentedButtonTheme`, `expansionTileTheme`, `popupMenuTheme`, `radioTheme`, `checkboxTheme`. This single gap explains why 114 dialogs, 245 SnackBars and 121 spinners render as stock Material without any individual screen being wrong, and why screen changes feel like nothing.
3. **601 lines of design system have zero importers** — `app_component_styles.dart` (430) + `app_card_styles.dart` (171). `app_button_styles.dart` has 3 importers and 18 call sites in only two screens. The correct diagnosis is not "no design system" but "a parallel unused one."
4. **Silent failure is an app-wide convention** — 10 sites of `error: (e, s) => const SizedBox.shrink()` (`home_screen.dart:1196, :1206, :1601, :1994`, `profile_screen.dart:2528, :2532`, `match_box.dart:1378`, `paywall_screen.dart:1392`). In a product whose normal state *is* silence, "the backend failed" and "nobody is near you" render identically, and the user's only available conclusion is that the app is broken.
5. **`colorScheme.tertiary` has no `lightOnTertiary` defined** yet is used as an accent in 6 places (`home_screen.dart:256, :263, :836`). Amber on white computes to **2.15:1** — failing WCAG AA for text *and* the 3:1 non-text minimum. Secondary is correctly paired (`#EC4899` + `#3D0723` = 4.75:1); tertiary is not.

Plus the framing correction: **`alpha` is being used as the hierarchy mechanism** — 91 sites of `onSurface.withValues(alpha:` where a contrast-checked role already exists (218 sites correctly use `onSurfaceVariant`). That inconsistency, not any single screen, is the systemic reason dark and AMOLED contrast fails in scattered places — and it is why the fix is a token pass rather than a screen-by-screen pass.

---

## 11. Mockups

Nine before/after HTML mockups, rendered at 302 × 620 phone frames with the *measured* before values (112 px app bar, `fontSize: 11` chips, 140 × 140 radius-8 thumbs, 96 px event label column, 600 ms blink, `#D9FDD3` bubbles) so the comparison is honest rather than a caricature. They are in the chat session's visualization folder; the source fragments are `mm-01` … `mm-09`.

| # | Subject | Sections |
|---|---|---|
| 1 | Match card — blinking row → LIVE / PLAN / MISSED spatial card | `match_box.dart`, `matches_screen.dart` |
| 2 | Match moment + Home → Now + app-bar status strip | `main_navigation_screen.dart`, `home_screen.dart` |
| 3 | Chat — list rows, bubbles, composer, attach sheet | `chat_screen.dart`, `chat_list_item.dart` |
| 4 | Events → Plans, the matching diagnostic, Settings rows | `events_screen.dart`, `settings_screen.dart` |
| 5 | Match profile pager, paywall messaging, first minute + OTP | `match_profile_screen.dart`, `paywall_screen.dart`, auth |
| 6 | Design-system specimen — type, colour, spacing, motion, lint rules | `lib/theme/*`, `pubspec.yaml` |
| 7 | Map + detent sheet, walk-to-them, six-platform parity, a11y, RTL | `nearby_map_screen.dart`, `location_share_map_screen.dart` |
| 8 | The ledger + batch plan with effort and platform blast radius | this document |
| 9 | Three visual directions — Quiet Product / **Presence (recommended)** / Warm Human | skin, not structure |

**Visual direction recommended:** Option B **Presence** as the shell — dark ground, one high-chroma accent, distance as hero numerals, map chrome as the design language — with Option C's warmth reserved for surfaces where a *person* is on screen (match moment, profile pager, chat). Dark mode is already correct, so B builds on what works; C wants an illustration set the repo does not have; A is the cheapest and the best fit for the desktop targets.
