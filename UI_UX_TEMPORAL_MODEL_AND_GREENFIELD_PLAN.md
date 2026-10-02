# MatchMe — The Two-Lane Match Model

**Date:** 28 September 2026
**Status:** Authoritative. Supersedes the three-class (LIVE/WARM/PLANNED) model in the previous revision of this document.
**Owner directive:** *"The system doesn't right now attempt to calculate users' future locations. It works by seeing who is near each other in the present. And, if they are attending the same event in the future, that is an alternative to current proximity."*

---

## 1. Correction, and what it means

I twice built speculative machinery that the product does not have — first a "full location history waiting to be aggregated," then a place-graph / periodicity / co-occurrence forecast. Both were wrong. **There is no location history and no forecast.** MatchMe has exactly **two** match bases:

| | **Proximity match** | **Event match** |
|---|---|---|
| What it means | You are near each other **right now** | You will **both be at the same place, at a future time** |
| How it is produced | Present co-location | Both registered for the same event |
| Character | **Improvised** | **Scheduled** |
| Urgency over time | **Decays** from creation | **Intensifies** toward the event |
| Is the meet already arranged? | No — it has to happen in the next few minutes | Yes — only the *when and where within the event* is open |
| Right response | Act immediately | Don't act yet; coordinate |

Everything in the UI follows from that single distinction. My earlier "LIVE / WARM / PLANNED" framing was a workaround for not having understood it.

**The critical consequence: the two lanes have opposite urgency curves, and the current UI gives them the same treatment.** A proximity match from four hours ago is worthless. An event match from four hours ago, for tomorrow night, is *urgent*. The app treats both as "24 hours, then gone."

---

## 2. The 24-hour window is a commitment filter, not a bug

> **Corrected 2026-09-28.** This section previously claimed the flat 24h window was a "confirmed bug" and recommended anchoring event matches to `events.start_time`. **That was wrong, and the recommendation is withdrawn.** See the correction note below.

An earlier draft of this document argued that because `matches.chat_start_window_seconds` is set by a `BEFORE INSERT` trigger from a single global config key (`matches.chat_start_window_seconds`, default `86400`) with **no branch on `match_type`** — and because `cleanup_expired_matches` applies that same window to `match_type IN ('proximity','event','co_motion')` — an event match on a concert three weeks away would be deleted ~24h after creation, two weeks before the event.

**The product owner's position, which is the correct one:** the window is a deliberate engagement filter. *"I want users to be engaged… If both users don't initiate the chat within those constraints, then I guess it simply wasn't meant to be."* One message creates the chat and stops expiry; each participant also has an extend option, so there are ~72h in practice. This matches where the category went — Bumble moved its reply window 24h → 72h in August 2026 precisely because users were missing matches.

**Do not lengthen the window, branch it on `match_type`, or remove the countdown on these grounds.**

### The mechanism is stronger than I first credited

24h + extend is a **three-rung escalation ladder**, and the first rung is unusually good:

```
notice (free)  →  extend (soft bid, zero words, no rejection risk)  →  message (real bid)
```

Almost every dating app goes notice → message, which is a cliff. This has a rung in between that costs nothing and cannot be refused. I originally called it "a chore behind an AlertDialog"; it is the product's lowest-pressure way to express interest, and `chat_start_extension_count` plus the "Extended by <name>" badge show the model already anticipates it.

### What remains genuinely open

Neither of these changes the 24h number. Both are about being able to *see* what it does.

**1. The window measures app-open latency, not interest.** A 24h window running from match *creation* filters for "does this person open the app within 24 hours." For a product whose premise is that the user closes the app and lives their life, that diverges sharply from intent. These two outcomes are currently indistinguishable:

- *"Maya got the notification on the street, didn't look at it for 6 hours, found it in the morning — gone."* → a delivery-timing artifact
- *"Maya saw it and didn't care."* → an intent signal

`match_box.dart:488-490` returns `SizedBox.shrink()` for both. **The app cannot currently tell you whether 24h is filtering for interest or for app-open frequency** — so you cannot know which policy the number should be tuned against.

**2. There is no measurement to tune the number with.** You have made a policy decision that determines whether the core loop fires at all, and the one question that would validate it — *of matches that received a message, what fraction met in person?* — is unmeasurable today. Nothing records outcome; the rating prompt fires on chat, not on a meeting happening. A single **We met / We didn't** verdict makes the 24h number a dial you can turn with evidence instead of a guess. It is worth more than any visual work in this document.

### Extend was invisible to the peer — now fixed

Extending did not notify the other person: `extend_match_chat_window` only wrote per-user columns, and the "Extended by Maya" badge renders only if the peer opens the app and scrolls to that row before the window runs out. It was functioning as a private timer rescue rather than a signal.

**Implemented 2026-09-28**, pending migration — see §10.

---

## 3. Two notification channels, not one adaptive duration

My earlier proposal was a single notification with an adaptive 6s→20s duration. That was modelling *amount* of urgency. The two lanes have different *kinds*, and that matters more.

**Channel A — Now (proximity).** Time-critical. Fires immediately, haptic scaled to distance, act-now affordances, adaptive dwell time. This is a genuine interruption and should be allowed to be one.

**Channel B — Plan (event).** Should **not** interrupt on match creation. It's a scheduled thing, and the user already knows when it is. Instead:
- A quiet entry on Matches/Events: *"Philz Jazz Night — Friday, with Maya."*
- **Add to calendar** (one tap; you already sync four providers).
- **Propose a spot & time inside the event** — *"Box office at 7?"* This is the named-rendezvous primitive, and an event is exactly the case where it beats a pin: a lat/lng inside a concert hall is meaningless, "by the box office" is not.
- **A reminder near the event** — 1 hour out, and again on arrival.
- **"I'm not going"** — sets the other person's expectation.

**And urgency that builds.** A plan-channel match should get *more* prominent as the event approaches, not less. That is the opposite of the proximity lane, and the current shared countdown can't express it.

---

## 4. The two failure modes, which are completely different

**Proximity: the moment passes and it is gone.**
Today: `match_box.dart:488-490` returns `SizedBox.shrink()`. The row silently disappears. For the app's headline scenario — two people who just walked past each other in a grocery aisle — this is the *most likely* outcome, and it is handled by deleting it.

Needs a **`missed` state**: kept visible, non-blaming, precise (*"You were both here Tuesday, 4:40 PM"*), with one tap to reconnect later. The current blinking countdown tells the user the opposite — that the connection was worthless.

**Event: nobody shows, or nobody says anything, and there is no record.**
Two people matched on an event. The event passes. Was it a great match that never got spoken to, or did one not attend? **The app cannot tell you**, and neither can the user. Nobody handles this. It needs:
- An explicit **"I'm going" / "I'm not going"**, visible to both.
- A post-event prompt: *"You were both at Philz on Friday. Did you connect?"* → **We met / We didn't.**
- That resolution feeds the rating and the occurrence counter, and it closes the loop that currently just goes silent.

This is also the cheapest honest signal you can collect: it tells you whether event matching is working *as a meeting mechanism* or merely as a matching mechanism.

---

## 5. Adding events is a first-class matching lever

Because event attendance is a match basis, **the user's event list is a matching parameter** — exactly like radius, intents and interests. It is currently invisible as such: nothing tells a user that adding events increases their chances.

This gives the *"why you're not matching more"* diagnostic I recommended a **second, very concrete action line**, and one that requires no new data:

> **You're set to visible, and 2 people are within 500 m right now.**
> **But your radius is 500 m and you have 1 shared interest category.**
> → Widen to 2 km (≈3× more people)
> → Add 2 more events to your calendar (≈2× more shared-venue matches)
> → Choose more interests

Every claim computed from real counts, never invented. It also makes **Events a first-class tab rather than a calendar utility** — because the user has a direct, visible, quantified reason to maintain it. This is the same mechanism that made Tinder Events work (LA pilot: 71% engagement, >50% returned the following week): the surface became the reason to come back.

---

## 6. Revised information architecture

**Drop the "Plans" tab I proposed.** It existed to hold predicted co-presence. There is no prediction, so it would be a thin tab. Don't invent structure for a feature that doesn't exist.

Keep five tabs, but make the first one mean what it says:

| Tab | Contents |
|---|---|
| **Now** | Live proximity matches only. Live map, ambient presence, act-now cards. Empty most of the time — *that is correct and honest*, and the empty state should say so rather than apologising. |
| **Matches** | Everything you've matched, with a **basis filter** (`Near me` / `Shared event`) and a **liveness indicator** per row (`Live now` · `Fri 7:30 PM` · `Missed`). |
| **Chats** | Unchanged in position; gains propose-a-spot and going/not-going. |
| **Events** | Your events, plus *who from your matches is going* and *who else is going*. A reason to maintain it (§5). |
| **You** | Profile, matching setup, settings. |

The match card now leads with **one of three things**, decided by basis — no more uniform countdown:

```
┌────────────────────────────────────────┐
│  ◉ LIVE          Maya · 30 m · 2 min  │   proximity, now
│    Both into climbing & live music     │
│    [ Walk over ]   [ Wave ]            │
└────────────────────────────────────────┘

┌────────────────────────────────────────┐
│  ▣ FRIDAY 19:30   Philz Jazz Night     │   event, scheduled
│    With Maya · in 3 days              │
│    [ Add to calendar ]  [ Propose spot]│
└────────────────────────────────────────┘

┌────────────────────────────────────────┘
│  · MISSED          Tuesday, 16:40      │   proximity, gone
│    You were both here                  │
│    [ Catch them next time? ]           │
└────────────────────────────────────────┘
```

**Occurrence still leads the trust signal** — and it needs *no* place graph, no periodicity, nothing predictive. `matches.match_occurrence` already counts repeated encounters, and "You've been near each other 4 times" is the strongest, unfakeable proof of a connection in the app. Raise the cap well above the current default of 3.

---

## 7. What this correction removes

Dropped entirely from my previous recommendations, as unsupported by the product:

- Place graph from GPS clustering
- Per person×place periodicity histograms
- Co-occurrence forecasting / "when will we be next near each other"
- k-anonymity gates and the on-device aggregate sync design
- The "Next time you'll both be around" surface
- The "Plans" tab

## 8. What survives, unchanged

From `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` and `UI_UX_DEEP_DIVE_AND_REDESIGN.md`:

- **Now tab** replacing the Home dashboard (the duplicate stat tiles, duplicate match list, duplicate chat list, map-shortcut status card)
- **Delete the app-bar status strip** — 400 lines, 11px truncated connectivity + a scaled `Switch`, on every tab
- **Spatial match cards** — distance and bearing as the hero; *"You both chose Climbing"* instead of `Intent: rock_climbing`
- **Ocurrence as the headline trust signal**
- **Ways to close the gap that don't require talking** — visual ring, named rendezvous, walk-over-as-equals
- **Propose three times / propose a spot** — now clearly an *event-lane* feature
- **The `missed` state** — now clearly a *proximity-lane* concept
- **The "why you're not matching more" diagnostic**, now with the events lever added
- **Wizard: 11 pages → 4**, plus Hinge-style intent-specific prompts and a profile-strength meter
- **Settings: 11 gradient cards → 3 questions** + a permanent setup-health summary
- **Token layer + shared components + zero legacy budget** (pre-launch)
- **Text scaling (0 `textScaler` today), touch targets (13 `shrinkWrap`), WCAG 1.4.4 / 2.5.8**
- **The trust defects** — dead Terms/Privacy links, hardcoded-white paywall, the debug `http.post` in `chat_screen.dart` build, raw exception text, `_supportsNativePurchases => false`
- **`unmatched_pairs.locations_history`** — coarse geohash + TTL + "forget" control
- **Identity fields, safety trio, chaperone/culture, verification messaging, paywall repositioning, moving ads out of Matches/Chats**

---

## 9. Revised priority

| # | Item | Lane | Why |
|---|---|---|---|
| 1 | Trust defects (§8) | Both | Legal exposure; free while unlaunched. |
| 2 | **We met / We didn't verdict + the funnel it unlocks** | Both | The only way to learn whether the 24h commitment filter is filtering for interest or for app-open latency. Everything below is guesswork until this exists. |
| 3 | Token layer + shared components, zero legacy budget | Both | Unblocks every rebuild. |
| 4 | `missed` state; stop the silent deletion of proximity matches | Proximity | The most likely outcome of the headline scenario is currently a deleted row. |
| 5 | Occurrence as headline; raise the cap above 3 | Proximity | Data already exists. Presentation only. |
| 6 | Now tab + spatial cards + delete the status strip | Proximity | Structure. |
| 7 | Two notification channels | Both | Replaces the single adaptive-duration idea. |
| 8 | `going` / `not_going` + post-event *"did you connect?"* | Event | Closes the second failure mode. |
| 9 | "Why you're not matching more" + events lever | Both | Turns silence into a one-tap fix. |
| 10 | Wizard 11 → 4 | Both | 20–40% never complete. |
| 11 | Propose a spot / add to calendar / named rendezvous | Event | Biggest funnel leverage, and you already have four calendar providers. |
| 12 | Settings restructure | Both | Ship **with** #9. |
| 13 | Safety trio, identity fields, culture, verification | Both | Trust. |
| — | ~~Event-match window anchored to `events.start_time`~~ | — | **Withdrawn** — the 24h window is an intentional commitment filter, not a defect. See §2. |

**Rule that survives everything:** never remove a working interaction before its replacement is live. Bumble killed the swipe in May 2026, the replacement slipped to 2027, and revenue fell 15%+ per quarter.

---

## 10. Build status — 28 September 2026

What is actually in the tree versus what is still only a recommendation.

### Shipped (code written, `flutter analyze` clean)

| Item | State |
|---|---|
| **Peer notification on match extension** | Implemented. New `NotificationType.matchExtended` with its own settings row, icon and preference key; `MatchNotification.isExtension` drives a second in-app banner in the existing overlay (`⏱️` + "Say hi before this match runs out"); distinct notification id/tag so an extension never overwrites the new-match card; foreground + tap routing in `main.dart`; Realtime detection is a before/after diff on the peer's `chat_start_user{N}_extension_seconds`, which is idempotent by construction. |
| **Three-language enforcement** | Implemented. DB `CHECK` constraints on `users.preferred_language` and `translations.locale`; `normalizeSupportedLocale` / `normalizeLocale` in six edge functions; `ar`/`ru` removed from `push-message`. |

### Written but not applied — awaiting you

| File | Action |
|---|---|
| `supabase/migrations/20262073000000_match_extended_notification.sql` | Apply. Re-creates `extend_match_chat_window` (body otherwise byte-identical to `20261003000000`) and adds `notify_match_extended`. |
| `supabase/migrations/20262074000000_constrain_locales_to_supported_languages.sql` | Apply after the one above. |

### Unverified

The in-app banner depends on Realtime `oldRecord`, which is governed by the table's replica identity. If a test extension delivers the push but shows no banner, that comparison is the first place to look. The push path is independent of it.

### Still only a recommendation

Everything in §3 (two notification channels beyond the extension one), §4 (going / not-going, post-event resolution), §5 (events as a quantified matching lever), §6 (Now tab, basis filter, card variants), §8 (the rest of the list), and all of `UI_UX_DEEP_DIVE_AND_REDESIGN.md`.

**Unbuilt and still open from §2:** the We met / We didn't verdict is now priority #2, and nothing else in this document can be validated without it.

---

## Appendix — Verified

| Claim | Source |
|---|---|
| Window set by a single global config, no `match_type` branch | `supabase/migrations/20260831000000_add_match_chat_extension.sql:99-102` |
| Default window 86400s (24h) | same, `:118` |
| Cleanup applies the same window to proximity/event/co_motion | `20261009000000_add_match_location_history.sql` |
| Match is archived + deleted on window expiry, no chat required | same, `cleanup_expired_matches` |
| Silent removal of expired proximity matches in the UI | `lib/widgets/match_box.dart:488-490` |
| 600 ms blink under 15 min (gated by `disableAnimations`) | `match_box.dart:131`, `:202-205` |
| 24h client default for extension duration | `match_box.dart:301-303` |
| `EventModel.startTime` / `endTime` exist | `lib/models/event_model.dart:6-7` |
| `matches.event_id` links match to event | `MatchModel.eventId` (`match_model.dart:109`) |
| `match_occurrence` counter exists, cap default 3 | `20261001000000`, `20261007000000` |
| Event matching runs via DB trigger on event join | `lib/providers/event_provider.dart:516-523` |
