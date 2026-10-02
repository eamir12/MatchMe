# MatchMe — Privacy-Preserving Design Constraints

**Date:** 28 September 2026
**Status:** Binding constraints on `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` §3 and §6 (the place graph / periodicity / co-occurrence forecast).
**Owner directive:** *"The app is privacy focused and security is paramount. The system doesn't keep users' locations."*

---

## 1. Correction to my own prior report

In `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` I wrote:

> *"you don't need ML… the change is aggregation and purpose limitation, not new collection"*
> *"The infrastructure you'd need for the real product is 80% built and 0% used."*

**That second statement was wrong, and the first understated the problem.** I described the forecast as if a location history were sitting there waiting to be aggregated. It isn't, and shouldn't be. I verified the schema; your posture is not merely correct, it is *deliberate and well-executed*:

| Control | Verification |
|---|---|
| Live locations deleted after 15 minutes | `20260505010000_add_cleanup_old_user_locations.sql` — `cleanup_old_user_locations(p_minutes_old int DEFAULT 15)` |
| Retroactive/offline trail is **opt-in, default off** | `20261903000000_retroactive_matching.sql` — `retro_matching_enabled boolean NOT NULL DEFAULT false` |
| Offline retention is **user-chosen, 2–72h** (default 24) | Same migration — `CHECK (retro_retention_hours BETWEEN 2 AND 72)`; client prune in `offline_trail_service.dart` |
| Offline trail table has **no RLS policies** → denied by default; access only via `SECURITY DEFINER` RPCs | Same migration |
| Exact coordinates on `matches` were **actively dropped** | `20261001000000` — `ALTER TABLE matches DROP COLUMN IF EXISTS user1_latitude` … *"Ensure any legacy location columns … are removed (privacy)"* |
| Match reads expose **occurrence only, no coords** | `20261001000000:327` — *"Update get_user_recent_matches: expose occurrence only, no coords (privacy)"* |
| Rematch maps were built deliberately **coordinate-free** | `20261001000000:4` — *"Option 4: Do NOT store exact coordinates. Show small zoomed map without pins."* |

That's a coherent privacy architecture with the reasoning written into the migrations. Two engineers reading this cold would understand it. Well done.

**So: there is no location history to aggregate, and the forecast must be designed as if none will ever exist.** That is the correct constraint, and it makes the problem harder and more interesting.

---

## 2. One exception that needs a decision before launch

Not the live path — that is clean. One narrow archive is not.

`20261009000000_add_match_location_history.sql` re-added coordinates nine days *after* the privacy migration above, to support showing "both towns" on a rematch card. It added `unmatched_pairs.locations_history jsonb`, which stores **per pair, up to 3 entries**:

```
occurrence, map_center_lat, map_center_lng, map_zoom, matched_intent, created_at, match_id
```

Three facts that make this worth a decision now rather than after launch:

1. **No TTL and no cleanup.** The only `DELETE FROM public.unmatched_pairs` statements in the repo are in two **admin** migrations (`20261017000000_admin_delete_match_rematch_choice.sql:181`, `20262007000000_fix_admin_delete_user_and_match_type_cast.sql:558`). `cleanup_expired_matches` writes and appends but never deletes. `is_permanent = true` halts *accumulation*; it does not delete anything.
2. **It accumulates for the exact case that involves no relationship.** `cleanup_expired_matches` archives the location of a match that **expired without a single chat message** (`IF EXISTS (SELECT 1 FROM chat_messages …) THEN CONTINUE`). So the retained coordinates correlate with *unrequited / ignored* matches — the most sensitive category, and the one a user is most likely to want erased.
3. **`map_center_lat/lng` is the centroid of two people's positions.** It is therefore derived from *both* of you — arguably the most sensitive value in the system, because it locates neither person exactly but does locate their midpoint, permanently.

It surfaces to the client (`get_user_recent_matches` → `previous_locations` → `MatchModel.previousLocations` → map thumbnails in `match_profile_screen.dart`), so it is at least visible to the user, which is better than not. I do not see a user-facing control to delete it.

**This is not a bug — it's a scope trade** ("show both towns on a rematch"), and the trade was reasonable. But it was made before the privacy posture was stated as a product-level principle, and it is exactly the kind of thing that becomes a problem on the first security review, the first journalist question, or the first request from someone whose match expired.

**Recommended resolution — keep the feature, drop the coordinates:**

| Field | Replace with |
|---|---|
| `map_center_lat`, `map_center_lng` | a **truncated geohash at ~1.5 km precision**, or better, a resolved **place-class label** (`city_centre`, `suburb_west`, `transit`, …) |
| `map_zoom` | keep (it's already a privacy-positive "coarse viewport, no pin" device) |
| `created_at` | keep — the *when* is the useful part and is far less sensitive than the *where* |
| retention | **add a TTL** (30 days is plenty) and delete on expiry |
| user control | **"Forget this match"** — deletes the pair's archive row |
| `is_permanent` | keep as an accumulation guard; add a separate retention path so permanent pairs still age out |

A 1.5 km cell still renders "you met in the city centre" on a rematch card, which is all the feature needed. It is not a coordinate, it is not re-identifying, and it makes the privacy claim defensible rather than aspirational.

---

## 3. ~~The forecast, redesigned so it needs no location history~~ — REMOVED

> **Superseded 28 Sep 2026.** The product owner has confirmed the system **does not and will not attempt to predict future locations**. There are exactly two match bases: **present proximity** and **shared future event attendance**. Neither requires a place graph, a periodicity histogram, a co-occurrence forecast, or any of the aggregate/digest machinery below.
>
> **Consequently the seven rules in this section are withdrawn.** The system stores *no* location history of any kind — not raw, not hashed, not bucketed, not aggregated. That is the strongest possible position and it should be preserved exactly as it is, not complicated.
>
> **What survives from this document:** §1 (the verified privacy architecture), §2 (`unmatched_pairs.locations_history` — still an open issue, still needs a decision), and §4 (privacy as a product differentiator, which is now a simpler and more accurate argument than it was).
>
> The forecast-dependent material is retained below for history only.

<details>
<summary>Withdrawn material — retained for history, not to be built</summary>

*(The seven rules — on-device aggregation, persist-counts-never-trajectories, quantize-and-HMAC, k-anonymity ≥ 5, return-category-not-venue, explain-without-leaking, bounded retention + forget controls — and the "Likely to overlap" surface, all describe a system that does not exist and should not be built.)*

</details>

**The insight: a periodicity histogram is not a location.** `(this person, this cell, Sunday morning) → 6 times` is a behavioural aggregate with no ordering, no timestamps, and no sequence. A *trajectory* (the order and timing of visits) is what makes location tracking. A *count* is not. That distinction is the whole design.

### The seven rules

**(a) On-device aggregation. This is the target architecture.**
Compute the histogram on the device, from the trail you already hold encrypted in Hive. Sync **only the count vector**. The server never receives a coordinate at any point — not transiently, not in a log, not in an error payload. You already have an encrypted local DB and a working offline-trail service; this is a natural fit.
The server-side variant below is the fallback for clients that can't, and is a meaningful step up from "everyone's competitors," but it is not equivalent. **Design the schema so the on-device path is possible later without a migration.**

**(b) Persist counts, never trajectories.**

```sql
-- what you keep
place_pattern(user_id, cell_hash, dow_bucket, hour_bucket, occurrences, last_seen)
-- what you must never keep
point(user_id, recorded_at, lat, lng)     -- no table, ever
route(user_id, a, b, a_time, b_time)      -- no table, ever
```

No ordering column. No timestamp per visit. A sequence is the thing that turns an aggregate into surveillance.

**(c) Quantize hard, then hash.**
~300 m cells (large enough that "grocery store," not one shop), 3-hour time buckets, 5 day buckets. Then `cell_hash = HMAC-SHA256(server_pepper, quantized_cell)`, with a **rotatable pepper**. A dump of counts then does not yield coordinates, and rotating the pepper revokes the derived data without a migration.

**(d) k-anonymity gate: k ≥ 5.**
Suppress any insight backed by fewer than k contributors. This kills the "you are the only person at this location at 3:14 AM" inference — which is simultaneously the worst privacy leak in the whole system *and* a genuinely unsettling thing for a user to be shown. Make the gate explicit in the config, the same way you already do for `retro.*` settings.

**(e) Return category, not venue.**
The surface reads:

> **Sunday mornings · a grocery store · 6 shared visits**

not *"Rittenhouse Market."* Nobody wants a stranger to learn their shopping habits; the category is enough to convey the pattern, and it survives re-identification because there is no venue to re-identify. This is better UX *and* better privacy — the two don't have to trade here.

**(f) Explain without leaking.**
If the app cannot justify a prediction without naming a place, the justification is a side channel that defeats the hashing. Enforce this in review: *"why this?" must be answerable as a time window and a place class.*

**(g) Bounded retention + real user control.**
Rolling 90 days on aggregates. A **"Forget everything about this person"** action on every match. A **"Delete all my patterns"** control. Both must actually delete the derived rows — the same lesson as §2, applied preemptively.

### What the UI becomes

The forecast loses its map pin and gains honesty:

> **Likely to overlap**
> Sunday, late morning · a grocery store · 6 shared visits
> Wednesday evening · transit · 3 shared

Probability and time window instead of a location. It's softer, less creepy, and — I'd argue — more useful, because what people actually want to know is *"are we going to keep running into each other?"* not *"where exactly."*

And a **first-class, visible trust surface** in the product, not a settings page:

> 🛡 **We don't keep your location.**
> Not your history, not your routes, not your coordinates. [How this works] [Delete my patterns]

Every competitor retains location; USENIX (2024) found six location-based dating apps allowed pinpointing a victim's exact location. **MatchMe would be the only app that can tell you when you'll next be near each other without ever storing where you were.** That converts privacy from a legal page into a verifiable, differentiating capability — and it is the strongest thing in this entire product.

---

## 4. What this constraint *improves* rather than limits

Worth stating plainly, because it's easy to read a hard constraint as a cost:

- **The forecast becomes honest.** "You're both probably at a grocery store on Sunday morning" is a more truthful statement than "you're both at this pin." Hedges are correct when the underlying claim is probabilistic.
- **Missed-match recovery gets better.** Rather than replaying coordinates — which would be creepy and is exactly what you refuse to store — recovery runs on *shared context*: event attendance, occurrence count, the place class, the time window. That's how a real friend tells you "we're both always at the Saturday market."
- **It differentiates on the axis competitors are weakest on.** Transparency is now a regulatory expectation, not a nicety. A verifiable "we keep nothing" is a moat.
- **It simplifies retention, deletion, and breach scope.** No location history means no location exfiltration. Your blast radius is materially smaller than every competitor's.

---

## 5. Revised requirement list

| Original | Revised under this constraint |
|---|---|
| Place graph from GPS clustering | On-device cell clustering; only counts leave the device |
| Per person×place periodicity from stored visits | On-device histogram; only `(cell_hash, bucket, count)` synced |
| Co-occurrence forecast by set intersection | Intersect **counts**; gate on k ≥ 5; return class + window, never a pin |
| "Rittenhouse Market, 6 shared Sundays" | "Sunday mornings · a grocery store · 6 shared visits" |
| `unmatched_pairs.locations_history` coordinates | Coarse geohash / place class + **TTL** + user "forget" control |
| Plans tab showing predicted venues | Plans tab showing **likelihood + time window + class** |

Everything else in `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` — the three-class lifecycle, the `missed` state, occurrence-as-headline, multiple ways to close the gap, the named rendezvous, the tab restructure, the greenfield plan — is unaffected.

---

## 6. Status — 28 September 2026

| Section | State |
|---|---|
| §1 Verified privacy architecture | **Confirmed accurate.** Read the schema directly. Live locations deleted at 15 min; retroactive trail opt-in, 2–72h, no RLS policies; exact coordinate columns actively dropped from `matches` in `20261001000000`. |
| §2 `unmatched_pairs.locations_history` | **Open. Not fixed.** Still stores `map_center_lat`/`map_center_lng` permanently with no TTL, and only for matches that expired *without a chat message*. Recommended fix: ~1.5 km truncated geohash or a place-class label, keep `map_zoom` + `created_at`, add a 30-day TTL and a "Forget this match" control. |
| §3 The forecast | **Removed.** The system does not and will not predict future locations. Retained for history only. |
| §4 Privacy as differentiation | **Strengthened.** §5 below makes it a verifiable capability rather than a claim. |
| §5 Three-language enforcement | **New. Implemented.** See below. |

### §5 — Three languages, enforced at the database

MatchMe ships **en / es / he only**. Until another language is officially added, that is enforced in four places rather than left to each reader remembering:

1. **Database constraints** — `20262074000000_constrain_locales_to_supported_languages.sql` normalises out-of-range `users.preferred_language` to `'en'`, deletes out-of-range `translations` rows, then adds `CHECK (… IN ('en','es','he'))` on both columns. Previously neither column had any constraint, so a client could write any locale and readers fell through to English inconsistently — some normalised, some queried an empty locale and returned a raw key name.
2. **Edge functions** — `normalizeSupportedLocale` / `normalizeLocale` map anything else to `'en'` in `cron-jobs` (inside `getTranslation`, the choke point for all three `preferred_language` readers), `public-reference-data`, `get-event-metadata`, `process-event-file`, and `sensitive-action-email-code` (which additionally validates the **untrusted `body.language` request field** before it can select a translation table or compute `isRTL`).
3. **Push copy** — `ar` and `ru` removed from `push-message/_pushStrings` and from `normalizeLocale`.
4. **Client** — the `AppLanguage` list in `lib/providers/locale_provider.dart` is the source of truth; each server normaliser names it in a comment.

**Why this is a privacy control and not just a tidy-up:** an untranslated locale in the `translations` table is a string that looks authoritative to a user and is not translated — including in security-relevant copy like the verification and sensitive-action flows. Constraining the table means no reader can ever surface a half-translated notice.

### Also shipped from this document's concerns

**`notify_match_extended`** (migration `20262073000000`) is written privacy-first, since it is the newest thing that touches user data:

- enqueues for the **peer only**; the actor never notifies themselves
- gates on the **peer's own** `notification_preferences` (pause → `global_methods.push` → `matrix.match_extended.push` → legacy flag)
- masks the actor's name with `public.mask_full_name`, consistent with `get_user_recent_matches` — **no full names in push payloads**
- stores **no coordinates**; the payload is `{type, matchId, otherUserId, extension_seconds, expires_at}`
- resolves copy from `translations` for the recipient's `preferred_language`, English before any hardcoded literal
- wrapped so a notification failure can never roll back a legitimate extension
- respects a `match_extended.notify_peer` kill switch

---

## Appendix — Every fact above, sourced

| Claim | Source |
|---|---|
| Live location TTL 15 min | `supabase/migrations/20260505010000_add_cleanup_old_user_locations.sql` |
| Retroactive matching opt-in, default false | `20261903000000_retroactive_matching.sql` |
| Retention 2–72h, default 24, CHECK constraint | same |
| Offline trail: no RLS policies, SECURITY DEFINER RPC only | same |
| Coordinate columns dropped from `matches` | `20261001000000_add_proximity_match_location_and_rematch.sql:9-13` |
| "expose occurrence only, no coords (privacy)" | `20261001000000:327` |
| "Do NOT store exact coordinates… no pins" | `20261001000000:4` |
| `locations_history` re-added with lat/lng | `20261009000000_add_match_location_history.sql:6` |
| Max 3 entries, keyed by occurrence | `_append_location_history`, same file |
| Archived only when the match expired **without chat** | `cleanup_expired_matches`, same file |
| `unmatched_pairs` deleted only by admin paths | `20261017000000:181`, `20262007000000:558` |
| `is_permanent` only guards accumulation | `cleanup_expired_matches` body, `20261009000000` |
| `previous_locations` reaches the client | `20261009000000:124,145`; `20261010000000:28,49`; `MatchModel.previousLocations` (`match_model.dart:126`) |
| Client-side trail pruning | `lib/services/offline_trail_service.dart` → `pruneOfflineTrail` |
| Six dating apps allowed exact-location pinpointing | USENIX Security 2024, Dhondt et al. |
