# MatchMe — UI/UX Deep Dive & Radical Redesign

**Date:** 28 September 2026
**Commit audited:** `fa9af8d`
**Supersedes:** `UI_UX_REDESIGN_PROPOSAL.md` (25 Sep 2026) — that document is largely still correct on measurement but is **too conservative**. This one takes the "nothing is sacred" brief seriously and proposes a structural redesign of the primary surfaces.
**Method:** static audit of all 324 Dart files under `lib/`, full reads of the navigation shell, Home, Matches, Match profile, Match card, Chat, Settings, Matching settings, Paywall, Profile wizard, Onboarding; plus a 2026 competitive teardown across ~30 apps.

---

> ### ⚠️ PARTIALLY SUPERSEDED — read `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` first
>
> This document assumed matches are **time-synchronous** (someone is near you *right now*). The product owner clarified that a match may equally be based on a shared event **weeks or months** in the past that will recur — *"they might not currently be near each other, but they will be, in the future."*
>
> **Still valid here:** §2 (audit), §4 Tier 0 (token layer, text scaling, trust defects), §4 1.1 (Now tab), 1.3 (delete the status strip), 1.5 (settings + diagnostic), 1.6 (wizard), Tier 3 (identity, culture, safety, verification), Tier 4 (motion, layout, Events), Tier 5 (monetization), and the whole of §6, §7, §8.
>
> **Superseded:** §4 1.2 and §4 1.4 (the match card and the notification are redesigned around a two-lane model — proximity-now vs. shared-event), §4 Tier 2 (meeting facilitation is reframed as Plans + proposal), and the "meet in 90 seconds" framing throughout §5.
>
> **Also revised:** §7's incremental, lint-gated token migration. The app is **pre-launch**, so the correct plan is a token-first **rebuild of the entire presentation layer** with a zero legacy budget, not a grind.
>
> **One item is actively wrong here:** §4 1.4's adaptive-notification-duration proposal and §5's urgency framing were partly premised on the flat 24h window being a defect. It is not — it is an intentional commitment filter. See §2 of the temporal model doc.

---

## 0. The one-paragraph version

MatchMe has already built the hardest part of a modern dating product — the thing Tinder, Hinge and Bumble spent a decade *failing* to build: **a system that finds people for you and never asks you to swipe.** Hinge is the only one of the three still growing, precisely because it moved away from volume. But MatchMe's **interface is designed for a hypothetical user who sits still, opens the app deliberately, and browses a list** — a user the product thesis explicitly says does not exist. The real user is on a bus. So the app throws away its single most valuable asset (spatial, live, *now*) and presents itself as a database with a Material skin.

**The fix is not cosmetic.** It is to stop designing a feed and start designing a **presence**.

---

## 1. What the competition actually does in 2026

### 1.1 The category is collapsing toward "place, not queue"

This is the single most important finding, and MatchMe is on the right side of it but not taking credit.

| Company | Signal |
|---|---|
| **Match Group** (Tinder + Hinge) | 13.3M paying users, **−6% YoY** |
| **Tinder** | MAU **−7%**, revenue $457.5M (−1%) |
| **Hinge** | Revenue **+22%**, paying users **+17%** |
| **Bumble** | Revenue **−15.2%**, paying users **−16.4%** |

Global dating downloads have fallen **six consecutive years**; category revenue declined for the first time ever.

Everyone is dismantling the mechanic that built their business:

- **Bumble (May 2026)** — CEO confirmed swipe elimination. "Fewer, better, more considered signals." They **ended women-message-first**, stretched the reply window **24h → 72h**, and shipped a "Opening Moves" prompt for one-word openers. Then, in Aug 2026, the *replacement* slipped to 2027 on a data-migration problem — and revenue kept falling 15%+/quarter. **Lesson: never remove a working interaction before the replacement is live.**
- **Tinder** — launched dating *modes* (Double Date, College). **Double Date produces 25% more messages per match** than one-on-one. Its **Events tab** (local dated outings) is the strongest disclosed retention mechanic in the category: LA pilot saw **71% of eligible 18–24s engage, and more than half returned the following week.** Tinder's CEO: *"a success story for a dating app is ultimately deleting it."*
- **Grindr** — the most aggressive AI deployment, and the most explicit about *why*. CEO George Arison: *"If I could be more transparent… this is what we know about you, this is what we know about them, this is why the connection makes sense — that's much more compelling."* Every recommendation ships with a "why these." It also ships a **real consent architecture** (2-tap AI opt-out, plain-language notices, "sensitive health data is categorically excluded") — and raised 2026 revenue guidance to **≥$535M**.
- **Meetup (Dec 2025)** — added **prominent reviews, attendee photos and demographic context before RSVP**, explicitly because *"an important consideration for many who experience anxiety in unfamiliar social situations."*
- **Soul (China)** — inverts identity: avatars, not faces. *"We focus on users' interests and personalities rather than their real-world identities."* Removes photo pressure and disclosure cost.
- **Muzz** — the most complete culturally-specific dating UI in production: mandatory selfie+ID+**manual admin review**, **screenshot/screen-recording blocking**, never requires phone-number sharing, and its signature **chaperone (wali) chat** — a third party who is *optional, visible to both daters, and revocable at any time*. Match Group cloned it for Salams.

### 1.2 A new proximity cluster has emerged — and it is not dating-shaped

A genuinely new 2026 category has appeared, and MatchMe's own mechanic is its centrepiece: **radar / meeting-now apps** (Radius, Vicinity, ProxiMeet, Bunchups, Buzzly, Offline Social).

Their shared design decisions are the most directly transferable ideas in this report:

1. **The shared *place* is the social object**, not a person.
2. **Location-gated rooms** (Vicinity's 80 venues: stadiums, parks, landmarks) — joinable *only when physically present*. In-person meetup becomes **structural, not negotiated.**
3. **Radius is an explicit, visible, user-set control** (Vicinity: 1–50 mi), never an opaque distance sort.
4. **No infinite feed, no "let's"** — explicitly rejected.
5. **Games as zero-risk interaction primitives** — a shared game gives strangers a reason to talk with no social cost.

### 1.3 The funnel math that should govern every MatchMe decision

```
100 matches → 10–15 conversations → 3–5 dates arranged → 1–3 dates actually attended
```

> *"Optimising conversation-to-date conversion could double real-world meetings without any improvement to matching quality. The most valuable untapped opportunity lies not in better algorithms but in better meeting facilitation."*

**MatchMe has zero meeting facilitation.** It has a chat and a location-share button. This is the single largest product-level UI gap, and it is worth more than any amount of matching tuning.

### 1.4 Cost-of-attention numbers (relevant to a push-driven product)

- Social notifications cause a **~7-second transient cognitive slowdown**; users average **63.5 notifications/day**.
- Mobile **resumption cost** is worse than interruption cost — the expense is returning to a half-finished conversation.
- **78% of dating-app users report burnout**; 40% cite "can't find a good connection."
- Meta-analysis of 17 studies (~26,000 people): dating-app users report **significantly worse psychological health** than non-users.

MatchMe's product is a push notification. Getting the *content* of that push right is the highest-leverage UI work in the app.

### 1.5 Accessibility is now a deadline, not a principle

**US HHS Section 504** requires web content *and mobile apps* to meet **WCAG 2.1 AA**: 15+ employees by **11 May 2026** (already passed), under 15 by **10 May 2027**. WCAG **3.3.7 Accessible Authentication** (new in 2.2) is directly relevant to age verification, selfie/liveness checks and CAPTCHAs.

For comparison, **Dateability** (~65,000 users) built a successful accessible dating product by shipping image descriptions, a neutral "Deets" disclosure taxonomy, a **permanently functional free tier**, and a **browser build** ("a web build is an accessibility feature, not a legacy channel").

---

## 2. Gap analysis: MatchMe vs. the category

| Dimension | Best in class | MatchMe today | Gap |
|---|---|---|---|
| **Match reason** | On the card, in a human sentence (Grindr "why these") | Behind a tap in `match_profile_screen.dart:3067`; list row shows `Intent: rock_climbing` metadata | **Severe.** The product's soul is hidden |
| **Freshness / urgency** | Dated, local, "tonight" (Tinder Events 71% engagement) | A countdown to *expiry*, not to *now* | **Severe.** Urgency points the wrong way |
| **Meeting facilitation** | Propose 3 times / they pick (CMB); chaperone (Muzz); location-gated rooms (Vicinity) | Nothing. Chat + a share button | **Severe. Largest single gap** |
| **Spatial presentation** | Radius as a first-class control; radar views | List first, map buried 3 taps deep; 40px avatars | **Severe.** Throws away the product's unique data |
| **Ambient / zero-attention use** | Snapchat Bitmoji presence; Live Activities | 5-second auto-dismissing toast | **Severe** |
| **Notification craft** | ≤25-char headline, inline action, Live Activity, 4-part test | 5s gradient toast with 🎉 and two icon buttons | **Severe** |
| **Onboarding friction** | CMB's blunt intent gate; Hinge prompts; DeepSync +23% completion by allowing fewer photos | 11–12 wizard pages, 7 required entries, 14 SnackBar validations | **Severe.** 20–40% never complete |
| **"Why am I not matching?"** | Grindr explainability; Nextdoor Faves agent | **Does not exist anywhere in the codebase** | **Severe** |
| **Identity fields** | Multi-select gender, free text, "prefer not to say", per-field visibility (Hinge/Taimi) | Required gender `DropdownButtonFormField`; FilterChips that cannot deselect the last | **Severe**, and an inclusivity problem |
| **First-meeting safety** | "I feel unsafe", trusted-contact location, discreet check-in (research-designed, under-shipped) | Report + Block in a chat menu | **Severe.** MatchMe's specific risk surface |
| **Verification** | Tinder Face Check: −60% bad-actor exposure, −40% suspicious reports; video deleted after check | Verification exists; the *guarantee* is never surfaced | Moderate |
| **Settings IA** | Task-oriented; "Your setup" summary | 11 giant gradient cards, 9× `arrow_forward_ios` | Moderate |
| **Paywall** | Sell the outcome | Hardcoded white scaffold, "Unlock Premium Features", dead Terms links, silent simulated purchase | **Severe — and a trust/legality problem, not just design** |
| **Text scaling** | 200% per WCAG 1.4.4 | **0 `textScaler` references; 407 hardcoded font sizes** | **Severe — WCAG failure** |
| **Touch targets** | 24×24 min (WCAG 2.5.8) | 13 × `MaterialTapTargetSize.shrinkWrap` | **Fails** |
| **Type system** | Enforced scale (M3 emphasized typography) | 8px, 10px, 11px, 11.5px, 12px, 13px, 13.5px, 14px… hand-mixed | **Severe** |
| **Color** | Tokenized roles | **1,216 hardcoded `Colors.*`** | **Severe** |
| **Motion** | Springs, reduce-motion honored | 10 animation primitives; reduced motion now partially honored (improvement) | Low |
| **Dark mode** | Baseline expectation | Properly implemented, synced across devices | **Strength** |
| **Voice guidance / accessibility of onboarding** | Rare | Narrated 32-beat tour with synchronized captions | **Strength — best-in-class** |
| **Offline-first** | Rare in social | Hive-encrypted, full offline operation | **Strength** |
| **Encrypted chat** | Rare | Real E2E-style with peer keys | **Strength — but never surfaced in UI** |

### Measured debt (verified today)

| Signal | Count |
|---|---|
| Dart files under `lib/` | 324 |
| Hardcoded `Colors.*` | **1,216** |
| Hardcoded `fontSize:` | **407** |
| `textScaler` references | **0** |
| `showDialog` / `AlertDialog` | 101 / 79 |
| `showModalBottomSheet` | 12 |
| `MaterialTapTargetSize.shrinkWrap` | 13 |
| `Semantics(` | 50 (was 24 — improving) |
| `LayoutBuilder` / `MediaQuery.size` | 12 / 13 |
| `HapticFeedback` | 1 |

**Improvements since the 25 Sep audit** (credit where due): reduced-motion is now honored by the flashing countdown (`match_box.dart:202-205`), haptics exist on match arrival, and `Semantics` doubled to 50.

### Code giants

| File | Lines |
|---|---|
| `profile_wizard_screen.dart` | **11,184** |
| `main.dart` | ~5,500 |
| `match_profile_screen.dart` | 4,757 |
| `chat_screen.dart` | 3,232 |
| `profile_screen.dart` | 2,640 |
| `settings_screen.dart` | 1,727 |
| `matching_settings_screen.dart` | 1,525 |
| `main_navigation_screen.dart` | 1,279 |
| `home_screen.dart` | 1,219 |

---

## 3. The diagnosis, stated honestly

**MatchMe's problem is not its visual style. It is that it is presenting a spatial, live, *now* product as a linear, static, *later* list.**

Five specific structural failures:

1. **Home is a dashboard that duplicates two of the five tabs.** It shows Recent Matches (tab 2) and Recent Chats (tab 3) again, plus three stat tiles, plus a status card that is really just a shortcut to the map. A user with 3 matches sees them on Home *and* on Matches. This is the most dated pattern in the app and it is on screen 100% of the time.

2. **The app-bar status strip is chrome pretending to be information.** A 56px pill strip on every tab, rendering connectivity + a visibility `Switch` at `fontSize: 11` with `Transform.scale(0.8)`, `shrinkWrap` tap targets, and text that truncates to `ellipsis`. Connectivity is not a user-facing status — Supabase being unreachable is an implementation fact.

3. **The match card is a 40-pixel avatar in a list.** MatchMe's data is *literally geospatial* — distance, bearing, live location, shared trajectory (`co_motion` matching!), match freshness. Every one of those is discarded for a `Row` of `Text` widgets with 11px captions. The product's unique data model is invisible in the product's primary view.

4. **The match notification is a 5-second toast.** `match_notification_overlay.dart:90` — `defaultValue: Duration(seconds: 5)`. The one moment the entire product exists for, given 5 seconds, as a gradient bar with a 🎉 emoji and two unlabeled icon buttons. And the real OS push notification is presumably worse.

5. **Silence is indistinguishable from broken.** There is no `why*`, `notMatching*`, or diagnostic surface anywhere in the codebase. If matching settings are misconfigured — and there are 2 dropdowns + 7 switches in `matching_settings_screen.dart`, 4 taps deep — the user gets *nothing*, with no explanation. For a product whose only output is matches, this is the worst possible failure mode.

---

## 4. Recommendations

### TIER 0 — Things that are not "modernization." These are credibility.

**0.1 Fix the trust-surface defects. Today.**
- `paywall_screen.dart:1566-1570` — **Terms and Privacy links have an empty `onTap` and a `// TODO`**. They are not tappable. This is a legal exposure, not a design nit.
- `paywall_screen.dart:36` — `bool get _supportsNativePurchases => false;` hard-codes RevenueCat off, making ~130 lines of purchase code dead, and leaves a **silent simulated purchase** path (`:317-330`).
- `paywall_screen.dart:721` — `Scaffold(backgroundColor: Colors.white)` **ignores dark mode entirely**.
- `chat_screen.dart:2541-2575` — a hard-coded `http.post` **debug beacon to `10.0.0.2:7777` fired from `build()`** in production code.
- `chat_screen.dart:1845-1849` — **raw exception text rendered to the user** in the chat error state.
- `matches_screen.dart:286` — a `ScrollController` allocated **inside `build()`**, never disposed.

> **Why first:** MatchMe asks people to meet strangers in physical space. Trust *is* the product. A dead Terms link and a broken paywall are a bigger threat to MatchMe than a dated gradient.

**0.2 Build the design-token layer for real.**
`app_theme_tokens.dart` is 19 lines and 1,216 hardcoded colors bypass it. Build: type scale (display/title/body/label × 3), spacing (4/8pt grid), radii, elevation, motion. Then **add a lint rule that forbids new hardcoded `Colors.*` and `fontSize:`** and retire existing ones per-screen as you touch them. No big-bang rewrite.

**0.3 Make it text-scale-safe and fix touch targets.**
0 `textScaler`. 407 hardcoded font sizes. 13 `shrinkWrap` targets. WCAG 1.4.4 requires 200%; 2.5.8 requires 24×24. This disproportionately affects your 55+ outdoor demographic — a core MatchMe user — and the HHS deadline is live.

---

### TIER 1 — The structural redesign

**1.1 ⭐ Replace Home with "Now." Delete the dashboard.**

Not a faster dashboard — a *different question*. Home currently answers "what is in my database?" **Now answers: "Am I findable right now, and what can I do in the next 5 minutes?"**

Layout, top to bottom:

```
┌─────────────────────────────────────┐
│  [status row — full width, readable] │  Visible · Matching on · 12:40 left
│  You're visible to people nearby     │  ← tappable, not a switch in a toolbar
├─────────────────────────────────────┤
│                                     │
│   ┌───────────────────────────────┐ │
│   │   (photo)   Maya, 29          │ │  ONE card, 88% of the fold
│   │             30 m · 2 min walk │ │  4-word reason
│   │             Climbing · Live   │ │
│   │             music            │ │
│   │   [ Say hi ]      [ Later ]   │ │
│   └───────────────────────────────┘ │
│                                     │
│   ── also near you ──               │
│   ○ Dan 120m  ○ Yuki 200m  ○ ...    │  ambient presence strip
├─────────────────────────────────────┤
│  Why you're seeing 3 people         │  diagnostic card
├─────────────────────────────────────┤
│  Your matching setup — 2 things     │  persistent, links to settings
│  could double this ›                │
└─────────────────────────────────────┘
```

**What gets deleted:** the three stat tiles, the duplicate Recent Matches list, the duplicate Recent Chats list, the status card that is just a map shortcut, and the `homeNoMatches` empty state that has no action button.

**What gets added:** a single hero match card with a real CTA; an ambient presence strip; a diagnostic card; a settings-health line.

> **Why:** Every user sees Home 100% of the time and it currently duplicates 40% of the rest of the app. A proximity app's home screen should be *the world right now*, not a data dump.

**1.2 ⭐ Make the match card spatial, not textual.**

Rebuild `match_box.dart` as a **large, glanceable, map-anchored card**:

| Element | Spec |
|---|---|
| Identity | 72px photo (not 40), name, age, verified badge |
| **Distance + bearing** | **The hero number.** "30 m · 2 min walk" |
| Reason | **A human sentence with actual nouns:** *"You both chose Climbing and Live music, and you're both within 200 m."* Not `Intent: rock_climbing`. |
| Freshness | "matched 4 min ago" / expiring pill, color-coded, non-blinking |
| Photo | Large enough to recognize a face you might be looking at right now |
| Actions | Inline primary action on the card, not two chevrons |

`match_reason_formatter.dart` and `match_score_utils.dart` already exist. Use them for *feeling*, not for filtering. Today the list row shows `Intent: rock_climbing, live_music` and `♥ 3` — a spreadsheet. Showing **"Climbing · Live music"** and **"30 m"** is the difference between a record and a *person*.

> **Why:** This is the single most on-brand thing you can build. Tinder literally cannot do it. It also makes the list scannable at arm's length, which is how a proximity app is actually used.

**1.3 ⭐ Delete the app-bar status strip. Move status into "Now."**

`_MainNavAppBarCenter` (`main_navigation_screen.dart:112-520`) is 400 lines rendering connectivity + a `Switch` at 11px with `Transform.scale(0.8)`, `shrinkWrap` targets, and text that ellipsizes. It is on every tab, always.

Replace it with: app bar shows **only** the screen name. Visibility/connectivity/invisibility-rule state become **full-width, readable status rows at the top of "Now."** This also unlocks the 56px of vertical space on every screen and lets you delete the gear icon (Settings moves to a tab).

> **Why:** Status is information, not chrome. This is the most "web dashboard" element in the app and the first thing every user sees every time.

**1.4 ⭐ Rebuild the match notification as the flagship surface.**

Today: 5-second toast. This is *the* screen of the product.

| Element | Spec |
|---|---|
| **Duration** | **Adaptive and legible:** ~6s for marginal, **~20s** for high-confidence + very close. Always explain *why* it stayed (a "staying for this" reason chip). Never manipulate silently. |
| **Identity** | Large photo + name |
| **Distance** | "**30 m · 2 min walk**" — hero, largest text |
| **Reason** | 3–4 words in plain language |
| **Primary** | **"Say hi"** — filled, thumb-reachable, ~56px tall |
| **Secondary** | "Later" — text, low emphasis |
| **Dismissal** | Swipe up/away, or tap-out. Never blocking. |
| **Haptics** | Escalating: light → medium → heavy as proximity increases |
| **On dismiss** | Becomes a dot on the Now tab. Never vanishes. |

**And redesign the OS notification too** — it is your real UI, since users close the app. Per the 2026 guidance: **≤25-character headline**, decision-relevant detail first, **one inline action** ("Say hi"), real-time grouping, and a **Live Activity / live update** for the time-bounded meet itself (start-to-end, alert **only** on the critical transition — "time to leave" — never alongside a push for the same event).

> **Why:** The entire product is this moment. Give it 5 seconds and you've wasted the product. The adaptive duration is honest because you show the reason. Research: users **cannot** be muted out of a product like this — self-interruption rises when notifications are suppressed — so you must make each one *worth* waking up for.

**1.5 ⭐ Un-nest Settings and give it a real information architecture.**

You said it directly: *"almost everything inside them affect the matching algorithm."* **But Settings is not a tab, and match radius is 4 taps deep** (gear → Matching card → Radius dropdown → value), with no radius or preference control anywhere on Home, Matches or Chats.

Two changes:

**(a) A persistent, plain-language diagnostic.** The single highest-value missing screen in the app:

> **"You're set to visible, but your radius is 500 m and you have 1 shared interest category. At 2 km you'd be visible to roughly 3× more people — about 4 more matches per day. [Widen it] [Choose more interests]"**

Every claim must be computed from real data (live nearby counts by radius bucket), never invented. This converts the product's worst failure mode — *silence that looks like a bug* — into a one-tap self-serve fix.

**(b) Restructure Settings around intent, not 11 gradient cards.** `settings_screen.dart` renders 11 near-identical ~90px gradient cards with `Icons.arrow_forward_ios` nine times. Replace with three groups and a summary header:

- **Getting found** — visibility, invisibility rules, radius, GPS behaviour, background matching
- **Who finds you** — match preferences (per intent), profile strength
- **The app** — display, language, notifications, safety, verification, account, billing

Add **"Your matching setup"** as a persistent summary at the top of the Now tab, always visible, with a health state (green / amber "2 things could help" / red "you're invisible").

> **Why:** A control that gates the product's only output is currently the most hidden thing in the app. And a settings screen that is 11 identical cards is not information architecture — it's a file listing.

**1.6 ⭐ Rebuild the Profile Wizard: 11 pages → 4 + progressive disclosure.**

A minimal romantic profile is currently **11 pages minimum (12 with review) and 7 required field entries** — with 14 SnackBar validations, no inline field errors, a required `*` marker shown *only* for business intent even though About You's 4 fields are always enforced, and a progress total that **silently changes** as intents are toggled.

New structure:

1. **What brings you here?** → intents (this is MatchMe's blunt CMB-style intent gate, and the *only* truly required first step)
2. **Who are you?** → name, birthday, gender, 1 photo
3. **What do you like?** → interests (search-first, not a 10-deep tree)
4. **How should people find you?** → visibility + radius

Then **progressive disclosure**: everything else (details, lifestyle, family, religion, languages, social links, height, education, occupation, filter preferences) lives behind a **profile-strength meter** that shows *"3 of 6 — a complete profile gets ~2× more matches."*

**Add Hinge's prompts.** 3–5 optional, personality-revealing, **chosen based on the selected intents**:

| Intent | Prompt |
|---|---|
| Romantic | *"A perfect Sunday looks like…"* |
| Friendship | *"I'm always down to…"* |
| Activity | *"My favourite way to spend a free hour is…"* |
| Business | *"I'm currently building…"* |

Hinge's 2025 Gen Z report (~30,000 daters): **85% are more likely to want a second date when asked thoughtful questions.** Prompts also solve MatchMe's blank-chat problem for free — they *are* the icebreakers.

**Add a live preview card** that updates as you answer, and **Deepsync's finding**: letting people start matching with fewer photos and encouraging more later raised completion **+23%**.

> **Why:** Activation is fatal here. Unlike a dating app you cannot fall back on browsing-while-undecided. If the profile isn't finished the user gets nothing and leaves permanently. 20–40% never complete — and the top documented cause is "too many required fields."

---

### TIER 2 — Meeting facilitation (the biggest unclaimed value)

**2.1 ⭐ "Propose 3 times, they pick one."**

Research is unambiguous: this is the **highest-leverage single feature in the funnel**, because scheduling is the hardest part of a first meeting and it kills the 3–5 → 1–3 conversion step. CMB ships it; Bumble and Tinder are building small-group versions.

**MatchMe can ship a version nobody else can.** You already have **calendar sync** (Google, Outlook, Apple, device). So:

> **You're both free — Thursday 7pm, Friday 8pm, Saturday 2pm. [Pick one]**

The other person picks. No phone number exchanged, no scheduling thread, no ghosting risk. This single feature addresses the largest leak in the entire category funnel and it uses infrastructure you have already built.

**2.2 ⭐ "Walk to them" as the primary action.**

Given a match 30 m away, the primary action should be a **full-screen navigation surface**, not a chat:

- Big live **direction arrow** + compass ring
- Live **distance and walk ETA**, updating
- **Tap to open maps** for turn-by-turn
- A quiet **"They can see you're 30 m away"** indicator if sharing is on
- The match window countdown, in plain language

This is the thing no dating app can build, because no dating app is about *meeting right now*. Your whole thesis — "they may have just passed each other on the street" — has no surface in the UI today.

**2.3 Give every match an explicit verdict.**

A match currently sits inert until expiry. Give it a state machine the user can act on:

```
New → Seen → Said hi → They replied → Met → Done
                                       └→ Expired
```

Add a **"We met"** button on the match and in the chat. It closes the loop, replaces the awkward rating prompt, gives you real outcome data, and — critically — feeds graduated offboarding (see 3.3).

---

### TIER 3 — Identity, inclusion, culture, and safety

**3.1 Rebuild the identity fields. Ask intent before gender.**

- **Intent first, gender second.** Parry/Filice/Johnson (2024) call forcing gender as the primary sort axis at signup *"a willful choice."* Your wizard already asks intents first — **keep that order and make it explicit.**
- **Multi-select gender with a free-text "add your own"** and **"Prefer not to say" as a first-class, non-degrading option.** Fadrigon et al. (151 participants, 81 LGBTQ+) found **forced misrepresentation is the core failure**. Today `match_preferences_screen.dart:612-647` uses `FilterChip`s that **cannot deselect the last option** — i.e. it structurally forces misrepresentation.
- **Pronouns**, and **per-field "Visible on Profile"** toggles (Hinge's model).
- **Deets disclosure** (Dateability's model): a neutral, natural list — neurodivergence, chronic illness, disability — surfaced on the profile so it isn't a later awkward conversation. Free tier keeps this available to everyone.
- **Photo description / alt text** for blind and low-vision users; it also serves the safety function (a described profile is a more accountable profile).

**3.2 Make culturally-specific practice a first-class, visible UI.**

Muzz proved that when a community's dating practice is **triadic** (two daters + a family member) rather than dyadic, the third party must be a **visible, transparent, revocable participant in the conversation UI** — not a hidden feature. Match Group cloned it for Salams; that is the validation.

You already have **religion** and **family** fields. Add:
- **A visible, opt-in, revocable chaperone/trusted-third-party role** in the chat, shown to both parties at all times.
- **Den-level / observance / sect filters** as *preferences*, with an explicit "dealbreaker vs. nice-to-have" distinction (see 3.3).
- **Alias / nickname mode and photo blur** — Soul's insight is that abstracted identity removes photo pressure, lowers disclosure cost for niche and closeted users, and makes doxxing harder.
- **Per-venue cultural context on events** (prayer times, sabbath observance, family-event norms) — the accessibility-in-venue version of the same idea.

> **Why:** Your brief explicitly names "different personalities, age ranges, cultures and traditions." This is where a real, defensible moat lives — not in swiping, but in being the only app that takes a user's actual context seriously.

**3.3 A "dealbreaker vs. preference" model — everywhere.**

CMB's #1 monetization complaint is that filter changes only apply to the *next* batch, wasting a paid day. Their other complaint: people outside stated age ranges appear anyway, which collapses the curation promise.

Adopt a **two-tier model, visible in the UI**:
- **Dealbreakers** — absolute, enforced, re-rank immediately on change, never violated.
- **Preferences** — soft, ranked.

Label them as such. This is a small UI change that removes an entire class of betrayal.

**3.4 ⭐ Ship the three most under-built safety surfaces in the category.**

MatchMe asks people to meet strangers in physical space. USENIX Security 2024 found **six location-based dating apps allowed pinpointing a victim's exact location**. Concordia DIGS Lab (624 LGBTQ+ respondents) documented drugging, assault, and fetishization. Users' own mitigations — video verification, public venues, sharing location with family — are the most-trusted measures in the research and are almost never shipped as product.

Ship, in this order:
1. **"I feel unsafe"** — not a panic button; the user *proactively* signals the app to alert their trusted contacts. Broader, calmer, and more useful than an SOS.
2. **Trusted-contact live location** during a meet, with automatic alerts on suspicious location patterns.
3. **Discreet / covert check-ins** — a check-in that *looks like an ordinary message* to a decoy contact, for users who don't want a visible distress signal.
4. **Safety prompts at the moment of the meet** — not buried in a help page: "Meeting someone new? Meet in public. Share your location with a friend." (Meetup's "context before commitment," applied to MatchMe's moment.)
5. **Location fuzzing** — show distance *bands*, not precise coordinates, and never persist precise share history longer than needed.

> **Why:** This is the single most defensible thing you can build, and it is the one thing competitors with 200-person teams haven't shipped. It is also the honest answer to "why should I meet a stranger I matched with?"

**3.5 Make verification an unlock, not a gate — and say what you do with the data.**

Tinder Face Check (mandatory video selfie) produced a **60% drop in exposure to bad actors** and a **40% decline in suspicious-behavior reports**. The privacy design is the lesson: **video selfies are deleted shortly after verification**; only an encrypted, non-reversible map is retained — *and that fact is stated in the UI.*

So: keep verification optional-but-rewarded, surface the badge as social currency, add periodic re-verification (Dating.com uses 6 months) to catch recycled identities, and **state plainly what happens to the biometric data.** Grindr's explicit "sensitive health data is categorically excluded" is a model of how to build trust with an AI-adjacent product.

---

### TIER 4 — Delight, motion and platform polish

**4.1 Ambient presence.** Snapchat's Bitmoji is the reference: presence communicated *ambiently* without a message. Your matches' avatars appear softly on the Now tab and in the composer when they're nearby and live-sharing. Ten animation primitives is not a motion system — but you already honor `disableAnimations` in the countdown; extend that everywhere and consider spring physics (Flutter has no official M3 Expressive; `material_3_expressive` / `material_expressive` are community packages requiring Flutter ≥3.44 / Dart ^3.12 — **pin and re-audit before adopting**).

**4.2 Replace the 600 ms blink with a dignified urgency language.** The flashing countdown is the oldest trick in the app and it reads as a stress tactic. Prefer: a color ramp, a "going quiet in 8 min" plain-language label, and a one-tap **"Ask them to extend"** — which reframes the deadline as a *shared* problem instead of a countdown you're losing.

**4.3 78 `AlertDialog`s → bottom sheets for user-initiated flows.** 101 `showDialog` vs 12 `showModalBottomSheet`. Sheets keep context, are thumb-reachable, and feel current. Reserve dialogs for genuinely destructive confirmation. Also fix `PopupMenuItem` wrapping a full `ListTile` (`chat_screen.dart:1714-1732`) and `IntrinsicWidth` per message bubble inside a `ListView.builder` (`:2649`).

**4.4 Bottom sheets for 79 more flows, plus contextual, in-context controls.** Radius should be adjustable **from the map and the match card**; verification state from the profile; notification permissions at the moment of need. **Never ask for all permissions up front** — a rapid permission sequence on arrival is a documented conversion leak, and *"a silently failing camera permission can block verification for otherwise-eager users."*

**4.5 Adaptive layout beyond one breakpoint.** 12 `LayoutBuilder`s, 13 `MediaQuery.size`, and a single 900px rail threshold in a codebase that ships Android, iOS, **web, Windows, macOS, Linux**. Foldables, tablets and desktop are all supported targets and none are designed for.

**4.6 Promote Events to a co-primary tab and reframe it as "Plans."**

Tinder Events: **71% of eligible 18–24s engaged; more than half returned the following week.** That is the best retention number any major app disclosed in 2026, and it is a *dated, local, low-pressure* activity.

**You already have this** — events, attendance, shared-event matching, calendar sync, and a retroactive matching trail. It is currently tab 4 of 5 and framed as a calendar. Reframe Events as **"Plans"**: things happening near you, who you know is going, and who else from your matches is going. Add **location-gated** events (joinable only when physically present) — Vicinity's pattern, and the cleanest "in-person by construction" mechanic in the report.

**4.7 Consider an abstract-identity profile mode.** Soul's insight: avatars instead of faces removes photo pressure, lowers disclosure cost, and hardens against doxxing. As an *optional* mode — not a replacement — it meaningfully widens who can onboard, which matters for closeted users, people facing photo pressure, and anyone who simply doesn't want to upload a face to be matched.

---

### TIER 5 — Monetization, done honestly

**5.1 The paywall is currently a trust liability.** It hard-codes a white scaffold (ignores dark mode), leads with the generic **"Unlock Premium Features,"** preselects Gold, shows a **badge at `fontSize: 8`**, and has dead Terms/Privacy links. Fix all of it, then change the *message*.

**5.2 Sell the outcome, not the feature list.** Dating apps' biggest lever is "see who liked you." **You have no like.** The equivalent levers, in order of honesty:

| Sell this | Because |
|---|---|
| **"You'll be found by more people"** | Widen your effective reach — honest, directly tied to value |
| **"Higher-quality matches"** | Matches your actual differentiation |
| **"More time to say hi"** | Longer match windows + the extend mechanic nobody else has |
| **"Meet faster"** | Live Activity, Walk-to-them, propose-3-times |
| **"See why you're not matching more"** | The diagnostic as a premium feature — extremely compelling |

**Never** manufacture artificial scarcity of attention. That is the exact manipulation users are fleeing, and it is the reason the category is shrinking.

**5.3 Keep the free tier genuinely functional.** Dateability's principle: *"There will always be a fully functional free version. We wanted to truly make it accessible."* Their free tier keeps unlimited swipes, likes, matches and messages; premium only adds **granular filtering and efficiency**. Same structure fits you: premium = *reach and quality*, free = *the whole core loop*.

**5.4 Move the ads out of Matches and Chats.**
`AdSlot` currently appears in `home`, `matches`, `chats`, `events` (×2), and `profile`. An ad inside the match list sits directly beside "this person is 40 m away." This is not a dark-pattern argument — it is a **credibility** argument for an app that asks people to meet strangers. Keep placements where the user is not deciding something life-relevant.

---

## 5. What the experience will actually feel like

### 5.1 First 30 seconds after profile completion

> **Now:** a 32-beat narrated tour auto-plays, 13 of whose 32 beats are *Settings*. The single value statement arrives at the very end: *"MatchMe works quietly in the background."* Then you're dropped into a dashboard that shows a stats row, an ad, and a duplicate of your match list.
>
> **After:** a **"You're live"** moment. One line: *"You're visible. We're looking for people near you who chose Climbing and Live music."* Then a quiet map with three faint pins. Nothing to do. Close the app.

*(The tour itself is a genuine strength — narrated, captioned, localized, voice-guided. Keep it. But move Settings out of the tour: 13 of 32 beats is 40% of a first-run experience spent on a settings list, and it teaches the user that Settings is the most important surface in the app. It isn't.)*

### 5.2 The moment it matters

> **Now:** a gradient bar slides in for **five seconds**, says 🎉 *New Match!* and *Maya L.*, and offers two unlabeled icon buttons. If you're walking, you may genuinely miss it. The real push notification is a plain title + body.

> **After:** a deliberate interruption. Haptic pulse scaled to proximity. Her face, large. **`30 m · 2 min walk`** as the biggest text on screen. **"Climbing · Live music"** in plain words. One thumb-height **Say hi**. It stays 6 seconds for a weak match and **20 for this one** — and says so: *"staying longer: you're 30 m away."* Tap away and it becomes a dot. It never disappears.

### 5.3 The first 90 seconds

> **Now:** tap through a 4,757-line profile screen, find a Share Location button, start a session, pick a duration from a dialog, and hope the other person does the same.
>
> **After:** from the card, one button: **Walk to them.** A full-screen compass with a live arrow, distance counting down, your match window timer, and *"She's sharing her location too."* Or: **Propose a time** — *Thursday 7pm, Friday 8pm, Saturday 2pm* — pulled from both your calendars. She picks one. Nobody's number is exchanged.

### 5.4 "Why am I not matching?"

> **Now:** nothing. Three settings misconfigured and the app is silent, which looks identical to a crash. The only diagnostic in the entire codebase explains *background GPS*, not *matching*.
>
> **After:** a card on Now: *"You're visible, but your radius is 500 m and you have 1 interest category. At 2 km you'd be visible to about 3× more people — roughly 4 more matches a day."* One tap. Self-serve. No ticket.

### 5.5 The settings

> **Now:** 11 gradient cards, nine of them ending in the same grey `arrow_forward_ios` arrow, requiring 4 taps to reach the one setting that determines whether you get anything at all.
>
> **After:** three questions — *"Getting found" / "Who finds you" / "The app"* — with a **"Your matching setup"** summary pinned permanently at the top of Now, in green, amber or red.

### 5.6 Two weeks later

> **Now:** a growing list of stale matches, some expiring, one chat half-finished, an app you feel vaguely guilty about not opening.
>
> **After:** you met Maya on Thursday. Your profile says **"Met."** The app quietly tells you *"You're connected — we'll keep matching quietly."* You don't open it for three weeks, then get a notification: *"Someone who chose Climbing is 40 m away."* **This is the product working.**

### 5.7 The one-sentence version

> **MatchMe today looks like a well-engineered database with a Material skin.**
> **After this work it feels like a quiet, competent presence in your life that occasionally says: "There's someone you'd actually like, 30 metres that way."**

---

## 6. What I would tear out entirely

Since nothing is sacred, here is the demolition list:

1. **The Home dashboard** — duplicate stats, duplicate match list, duplicate chat list, a map shortcut masquerading as a status card.
2. **The app-bar status strip** (400 lines, `main_navigation_screen.dart:112-520`) — 11px truncated connectivity + a scaled `Switch`, on every tab, forever.
3. **The gear icon** — Settings is a first-class thing; it should be a tab, not an icon that also hides the matching algorithm.
4. **The 11 gradient cards in Settings** — one `_SettingsCard` widget, three groups.
5. **`Icons.arrow_forward_ios` as the universal affordance** (9 uses) — a dated iOS-ism.
6. **AlertDialog as the default for everything** (79 uses) — including a `TextField` plus 5 `RadioListTile`s inside a dialog.
7. **The 8px paywall badge** and the `fontSize: 8/10/11/11.5` tier of helper text throughout.
8. **The blinking countdown** — replaced with plain language and a shared "ask to extend."
9. **The `Intent: rock_climbing` metadata string** — replaced with a human sentence.
10. **The `ScrollController` in `matches_screen.dart:286`** and the debug beacon in `chat_screen.dart:2541` — those aren't UI at all, they're accidents.

---

## 7. Sequencing

| Phase | Items | Why in this order |
|---|---|---|
| **0 — Credibility (week 1)** | 0.1 trust defects, 0.3 text scaling + tap targets | Days, not weeks. Legal exposure + WCAG deadline. |
| **1 — Foundation** | 0.2 token layer + lint rules | Unblocks everything; retrofit is always more expensive |
| **2 — Activation** | 1.6 wizard, 1.4 notification, 4.4 progressive permissions | Fix the funnel before polishing it |
| **3 — Structure** | 1.1 Now tab, 1.2 spatial cards, 1.3 delete strip, 1.5 settings + diagnostic | The core redesign |
| **4 — Facilitation** | 2.1 propose-3-times, 2.2 Walk to them, 2.3 verdicts | Biggest funnel leverage |
| **5 — Trust & inclusion** | 3.1 identity, 3.2 culture, 3.4 safety, 3.5 verification | The differentiator |
| **6 — Delight & platform** | 4.1–4.7, 5.x monetization | Cumulative, low risk |

**Two sequencing rules:**
1. **Never remove before the replacement is live.** Bumble is the cautionary tale: they killed the swipe in May 2026, the replacement slipped to 2027 on a data migration, and revenue fell 15%+ every quarter. Additive first.
2. **Ship the diagnostic in the same release as the Settings restructure.** Otherwise, making Settings less prominent will quietly suppress matches for users who were quietly misconfigured.

---

## 8. Risks & where I'd push back

### On "redesign from scratch"
**Don't rewrite.** The logic layer is genuinely substantial and well-built: offline-first Hive sync, encrypted chat with peer keys, live location sharing, calendar sync across four providers, invisibility rules, a photo moderation pipeline, passkeys, a translation system that localizes into ~15 languages including RTL. A rewrite risks all of that for a visual gain.

**Do:** the token layer, the Now tab, the spatial match card, the redesigned notification, the diagnostic, the wizard rebuild, propose-3-times, and the safety trio. **Those eight carry most of the value and none of them requires touching the matching engine or the encryption stack.**

### Honest risks

| Risk | Mitigation |
|---|---|
| **Adaptive notification duration reads as manipulative** | Show the reason ("staying longer: you're 30 m away"). Legibility defeats the accusation. |
| **The Now tab is a bigger bet than a conventional app** | Validate with 5–8 user tests *before* shipping. Highest-uncertainty item. |
| **Cutting wizard fields could reduce match quality** | Keep the highest-signal fields: intents, interests, photos, lifestyle. Ship the strength meter so quality is recoverable, not lost. |
| **The diagnostic must not invent numbers** | Compute every claim from real live counts. A wrong "3× more people" destroys more trust than silence did. |
| **"How often should the system explain itself" risks nagging** | Diagnostics appear on a surface, not as interruptions. The app is ambient; it must not become chatty. |
| **Removing ads from Matches/Chats costs revenue** | Offset with the repositioned paywall (5.2) and Events placements. This app's trust premium is worth more than the impressions. |
| **The chaperone/third-party feature adds real complexity** | Sequence it *after* the safety trio; it is a differentiator, not a foundation. |
| **Bumble's lesson applies to you too** | If you replace the 5-tab shell with a Now tab, ship it *alongside* a switchback. Never leave users with no way to do what they could do before. |

### What is genuinely good and must not be lost

- **The narrated onboarding tour** is better than most commercial apps. Keep the voice guidance, the caption synchronization, the chapter dots, the RTL support. Just take Settings out of it.
- **Dark mode** is properly implemented and synced across devices. Do not regress it — and fix the paywall, which currently ignores it.
- **The offline-first architecture** is real and substantial. A redesign that assumed connectivity would be a downgrade, not an upgrade.
- **Encrypted chat with peer key management** is a genuine trust asset that is currently invisible. **Surface it in the UI** — an "End-to-end encrypted" indicator is worth more to a user meeting a stranger than a verification badge.
- **Verification badges** should become more prominent, not less.
- **The per-match expiry + extend mechanic** is genuinely unique in the category. Nobody else lets you extend a match window. Market it.

---

## Appendix A — Sources

**Competitors:** Fortune (Gen Z swiping left, Aug 2026) · TechCrunch (Bumble drops the swipe, May 2026; Liquid Glass tweaks, Jun 2026) · Times of India (Bumble Q2 2026) · TechCrunch (Tinder modes, Sept 2025) · Appthetics (Hinge UI patterns) · Coffee Meets Bagel · Grindr 2025 & 2026 product roadmaps · Grindr gAI privacy · LA Times (Grindr AI premium, Mar 2026) · Soul · Badoo safety docs · USC CCMP Badoo teardown 2026 · Identity Week (Tinder Face Check) · Meetup redesign (Dec 2025) · New Nextdoor (Jul 2025) · Vicinity · ProxiMeet · Radius · Dating.com / Incode / Veriff safety reports · Muzz · Muzz vs. Salams

**Design language:** Material 3 Expressive (m3.material.io) · Google Expressive research · Apple iOS 26 Liquid Glass + design gallery · Apple Live Activities HIG · Android live updates · material_3_expressive · material_expressive · m3_expressive · expressive_m3

**Notifications:** Eleken 8 guidelines · Smashing Magazine · Windows notification UX · Computers in Human Behavior 2026 (cognitive cost) · ACM MobileHCI in-situ

**Funnel & burnout:** DatingPro benchmarks · Forbes Health/OnePoll (78% burnout) · BBC Future (Sharabi meta-analysis) · SSRS 2026 · NPR (Coduto) · WJCL (swiping fatigue)

**Onboarding:** DeepSync dating analytics · YouGov conversion funnel · AppMakers USA

**Accessibility:** W3C WCAG 2.2 · HHS Section 504 guidance · Discord patch notes 2026 · Dateability (BusinessWire, NYT, Forbes) · Hiki

**Inclusion & safety:** Boston Review "Queering the Dating App" · ACM (RSM safety/inclusion) · ACM (Fadrigon LGBTQ+ account design) · Berkeley LGBTQ+ design playbook · Parry/Filice/Johnson (algorithmic heteronormativity) · The Conversation / Concordia DIGS (624 respondents) · arXiv 2606.27284 (Chinese gay dating deception) · USENIX Security 2024 (location-based dating privacy) · Hinge gender/sexuality docs · Taimi

## Appendix B — Audit methodology

All Part 2 figures derived by static analysis at `fa9af8d`. Representative commands:

```powershell
$all = Get-ChildItem -Recurse -File -Filter *.dart lib
$all.Count                                                          # 324
$all | Select-String 'Colors\.\w+'          -AllMatches | Measure-Object   # 1216
$all | Select-String 'fontSize:\s*[0-9]'    -AllMatches | Measure-Object   # 407
$all | Select-String 'textScaler'           -AllMatches | Measure-Object   # 0
$all | Select-String 'showDialog'           -AllMatches | Measure-Object   # 101
$all | Select-String 'AlertDialog'          -AllMatches | Measure-Object   # 79
$all | Select-String 'showModalBottomSheet' -AllMatches | Measure-Object   # 12
$all | Select-String 'MaterialTapTargetSize\.shrinkWrap' -AllMatches | Measure-Object  # 13
```

**Read in full or substantial part:** `main_navigation_screen.dart`, `home_screen.dart`, `match_box.dart`, `match_notification_overlay.dart`, `settings_screen.dart`, `match_profile_screen.dart` (structure + quick actions + basis card), `profile_wizard_page_map.dart`; plus structural analysis of `profile_wizard_screen.dart`, `chat_screen.dart`, `matching_settings_screen.dart`, `match_preferences_screen.dart`, `app_display_settings_screen.dart`, `paywall_screen.dart`, `profile_screen.dart`, `matches_screen.dart`, `onboarding_content.dart`, `onboarding_intro_screen.dart`, `custom_app_bar.dart`, `app_theme_tokens.dart`, and the theme construction in `main.dart`.

**Limitation:** static code and web research. No device was run, no screenshots taken, no usability testing performed. Statements about visual polish and perceived modernity are inferences from code structure and published competitor analysis, not observations. A visual audit on real devices — particularly the app-bar strip, the match card, and the wizard — is the natural next step.
