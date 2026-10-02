# MatchMe — UI/UX & Product Recommendations: Index and Current State

**Last updated:** 28 September 2026
**Purpose:** one page that says which document is current, what has been decided, what is built, and what is still only a recommendation. Read this first.

---

## The four documents

| Document | Status | Read it for |
|---|---|---|
| **`UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md`** | **Authoritative** | The two-lane match model, the pre-launch rebuild plan, the priority list, build status |
| `UI_UX_DEEP_DIVE_AND_REDESIGN.md` | Partly superseded | The 324-file code audit, design-debt measurements, the bulk of the visual recommendations |
| `PRIVACY_PRESERVING_DESIGN_CONSTRAINTS.md` | Current | The verified privacy architecture, the one open storage issue, the three-language enforcement |
| `UI_UX_REDESIGN_PROPOSAL.md` (25 Sep) | **Archived** | Superseded — now at `docs/archive/superseded-uiux/UI_UX_REDESIGN_PROPOSAL.md` |

**165 older point-in-time documents** (fix summaries, test guides, setup notes from Dec 2025 – Sep 2026) were moved to `docs/archive/` on 28 September 2026. See `docs/archive/README.md` — they are historical, not current, and should be verified against source before use.

---

## What is settled

**The product.** MatchMe matches people on shared intents + shared interests + either **present proximity** or **shared future event attendance**. No swiping, no browsing, no like. It runs in the background; the user's only job is to complete a profile. The goal is people meeting in person.

**Two match bases, with opposite urgency curves.** This is the single most important structural fact, and it is not expressed anywhere in the current UI:

| | **Proximity match** | **Event match** |
|---|---|---|
| Character | Improvised | Scheduled |
| Urgency over time | **Decays** from creation | **Intensifies** toward the event |
| Meet already arranged? | No — must happen in minutes | Yes — only the where/when inside is open |
| Failure mode | The moment passes (currently a *silent deletion*) | Nobody shows (currently unrecorded) |

**The 24-hour window is an intentional commitment filter, not a defect.** One message creates the chat and stops expiry; each participant can also extend, so ~72h in practice. 24h + extend is a deliberate three-rung ladder: *notice → extend (zero-word soft bid) → message*. Do not lengthen it, branch it on `match_type`, or remove the countdown. Bumble moved 24h → 72h in Aug 2026 for the same reason.

**The product is pre-launch.** No users, no compatibility constraints, no deprecation. The correct plan is a token-first **rebuild of the entire presentation layer** with a zero legacy budget — not an incremental, lint-gated migration.

**No location is kept.** Live locations are deleted at 15 minutes; the retroactive trail is opt-in with 2–72h retention and no RLS policies; exact coordinate columns were actively dropped from `matches`. This is a **verifiable capability, not a promise** — and it is the strongest differentiator the app has.

**Three languages: en, es, he.** Enforced by database `CHECK` constraints, not convention.

---

## What is built

| Item | State |
|---|---|
| Peer notification when someone extends a match | Done. `flutter analyze` clean. |
| Three-language enforcement (DB constraints + six edge functions) | Done. `flutter analyze` clean. |

## What awaits you

| File | Action |
|---|---|
| `supabase/migrations/20262073000000_match_extended_notification.sql` | Apply |
| `supabase/migrations/20262074000000_constrain_locales_to_supported_languages.sql` | Apply after the above |

## What is still only a recommendation

Everything visual. The full list, in priority order, is §9 of the temporal model document. The top of it:

1. Trust defects (dead Terms links, hardcoded-white paywall, debug beacon, raw exception text)
2. **A `We met / We didn't` verdict** — see below
3. Token layer + shared components
4. A `missed` state, replacing the silent deletion of expired proximity matches
5. Occurrence as the headline trust signal; raise the cap above 3
6. Now tab, spatial match cards, delete the app-bar status strip
7. Two notification channels; going / not-going and post-event resolution
8. The "why you're not matching more" diagnostic, with the events lever
9. Wizard 11 pages → 4, with intent-specific prompts
10. Named rendezvous, propose a spot, safety trio, identity fields, settings restructure

---

## The one open question that blocks the rest

**The 24-hour policy determines whether the core loop fires, and there is no measurement to tune it with.**

A 24h window running from match *creation* measures **app-open latency**, not interest. For a product whose premise is that users close the app and live their lives, those diverge sharply. Today two very different outcomes are indistinguishable:

- *"Maya got the notification on the street, didn't look at it for 6 hours, found it in the morning — gone."* → a delivery-timing artifact
- *"Maya saw it and didn't care."* → an intent signal

`match_box.dart:488` returns `SizedBox.shrink()` for both.

So the one question that would make the number a dial rather than a guess — **of matches that received a message, what fraction met in person?** — is unmeasurable. A single `We met / We didn't` verdict answers it, and nothing else in this plan can be validated without it. It is worth more than any visual work on this list.

---

## Corrections made during this work

Recorded so nobody re-litigates them:

| Claim I made | Corrected to |
|---|---|
| A place graph, periodicity histograms and co-occurrence forecasting are needed | **Withdrawn.** The system does not and will not predict future locations. |
| A "full location history waiting to be aggregated" already exists | **Withdrawn.** Nothing is stored. |
| The 24h window on event matches is a confirmed bug | **Withdrawn.** It is an intentional commitment filter. |
| Extend is "a chore behind an AlertDialog" | **Under-rated.** It is the product's cheapest, lowest-pressure signal of interest. |
| A "Plans" tab is needed | **Withdrawn.** Predicated on prediction that does not exist; would have been an empty tab. |
| ar / ru push strings should stay | **Removed.** Only en, es, he ship. |
