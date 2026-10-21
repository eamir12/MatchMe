# Cross-device settings sync

How a setting changed on one device reaches the user's other devices, and
what keeps that path from breaking.

## The model

There is no `user_settings` table. Every per-user setting is a **column on
`public.users`** (plus `user_profiles.intent_preferences`,
`user_invisibility_rules` and `ad_consent` for the settings that need their
own row).

Each device therefore does two things for every setting:

1. **Write** - locally (SharedPreferences / Hive / SecureStorage) *and* to
   the server. If the server write fails the change is queued in the
   profile outbox (`LocalDbService.saveProfileUpdateToOutbox`) and replayed
   by `OutboxSyncService` when the connection is back. **A setting that is
   not written to the outbox is lost for good** - that is how two devices
   end up disagreeing permanently.
2. **Read** - the local snapshot on cold start, then the server value, then
   realtime updates for everything after that.

## When a change is committed

**One rule, applied everywhere:**

| Kind of control | When it is committed |
|---|---|
| Toggle, switch, chip, dropdown, slider, single-value picker | **Immediately**, the moment you touch it |
| A form with several interdependent fields | **Explicit Save** (the profile wizard, the change-password dialog, the add-rule dialogs) |
| A submission or a destructive action | **Explicit Submit / confirm** (verification submit, delete account, opt out of ads) |

This is what the leading social apps do: Bumble, Hinge, Tinder, Instagram and
LinkedIn all commit a settings toggle the moment it is flipped, and reserve
the Save button for forms where the fields belong together.

In this app that means:

| Screen | Behaviour |
|---|---|
| Matching settings, display settings, notification settings, visibility, voice guidance | Immediate |
| Match preferences (gender, age range, lifestyle/family/religion/height filters) | Immediate - the Save/Cancel buttons and the "unsaved changes" prompt are gone |
| Ad consent | Immediate |
| Profile wizard | Save (every page, including lifestyle/family/religion, is a draft until then) |
| Invisibility rules | The add/edit dialogs are forms (Save); enabling and deleting a rule is immediate |
| Change password | Save (a form) |
| Verification, account deletion, opt out of ads | Explicit submit/confirm |

A slider follows the finger but is only written when it is **released** -
otherwise a drag would produce one write per frame.

## The realtime path

```
device A: local write ──► users / user_profiles UPDATE ──► WAL ──► Realtime
                                                                            │
device B: Realtime ──► MyUserRealtimeService ──► consumers ──► local write
```

### One channel for the signed-in user's own rows

`lib/services/my_user_realtime_service.dart` owns the **single**
`postgres_changes` subscription to the signed-in user's own rows: `public.users`
(`me_<uid>`) and `public.user_profiles`. Everything that lives on them -
theme, language, visibility, unit system, time format, currency, notification
preferences, matching settings, voice guidance, and the match preferences
(gender, age range and the filters) - arrives through it.

Consumers listen to `MyUserRealtimeService.instance.updates` (the `users` row)
or `.profileUpdates` (the `user_profiles` row):

| Consumer | Table | Columns it reacts to |
|---|---|---|
| `theme_provider.dart` | `users` | `theme_mode` |
| `locale_provider.dart` | `users` | `preferred_language`, `preferred_language_explicit` |
| `visibility_provider.dart` | `users` | `user_visibility_setting`, `system_visibility_status` |
| `user_preferences_provider.dart` | `users` | `unit_system`, `time_format`, `background_matching_mode`, `notification_preferences`, `preferred_currency`, `recent_currencies` |
| `profile_provider.dart` | `users` | `match_radius_default`, `gps_interval_default`, `smart_gps_throttling_enabled`, `shared_event_matching_enabled`, `shared_movement_matching_enabled`, `retro_matching_enabled`, `retro_retention_hours` |
| `profile_provider.dart` | `user_profiles` | `intent_preferences` |
| `voice_guidance_service.dart` | `users` | `voice_guidance_enabled` |

`MyUserUpdate.changedKeys` says which columns actually changed, so a
consumer never reacts to a column it does not own. Without that, every
profile edit would re-apply every setting.

### Why the channel has to be re-joined

Phoenix channels are scoped to a socket: when the socket goes away the
server drops every channel it carried, and the client has to send a new
`phx_join` for each topic.

`third_party/realtime_client` reconnected the socket but never re-joined the
channels, so after any socket drop - or an explicit `disconnect()` followed
by a `connect()`, which is what the web tab hide/show path does - every
subscription stayed dead for the rest of the process lifetime while the
client still reported "subscribed".

`RealtimeClient._onConnOpen()` now calls `_rejoinLostChannels()`, which
re-joins the topics recorded by `_markChannelsLost()` when the socket went
away. `test/services/realtime_client_rejoin_test.dart` locks this in.

**Any new code that disconnects the realtime socket must go through
`SupabaseRealtimeManager.pauseAll()` / `resumeAll()`** - a raw
`realtime.disconnect()` / `connect()` pair silently kills every
subscription.

### The watchdog

`SupabaseRealtimeManager` runs a health check every 45s: the socket has to
be connected and every registered channel has to be joined. Anything dead
for more than 20s is re-subscribed. This catches the cases the client-level
re-join does not (a channel the server never joined, a subscription that
was dropped server-side).

### The slow reconciliation

Realtime is the fast path, not the only one. `GlobalHomeSyncManager` pulls
the user's settings every 60s, so a change made on another device is picked
up within a minute even if its realtime event was missed (the app was
suspended, the socket was down, the event was lost). The pull never applies
the local snapshot first, so a stale value is never shown while it is in
flight.

## Rules for adding a setting

1. Put the value in a column on `public.users` (or on `user_profiles` for the
   match preferences).
2. Write it locally **and** to the server, with an outbox fallback.
3. Add the column to the consumer table above and react to it in
   `changedKeys`.
4. Make the local state comparable by value - `UserPreferencesState` and
   `NotificationPreferencesState` implement `==` so an unrelated update does
   not rebuild the UI or rewrite the local snapshot.
5. Persist the merged value locally. The local snapshot is what the app
   paints on the next cold start; if it is not written through, the change
   looks like it was lost.
6. Commit it immediately, unless it is part of a form. See "When a change is
   committed" above.

## Tables that must be in the `supabase_realtime` publication

A `postgres_changes` subscription only delivers for tables that are members
of the publication. Both of the user's own tables have to be there:

- `public.users` (added in `20260627000002`)
- `public.user_profiles` (added in `20262145000000`)

If a table is missing, the client still reports "subscribed" and then never
receives an event - the failure is completely silent.

## Deliberately device-local

| Setting | Why |
|---|---|
| `amoled_black_enabled` | A screen capability: an OLED phone and an LCD laptop should not be forced into the same mode. |
| `flutter.location_share_interval`, `flutter.viewing_chat_id` | State of this device's location session, not an account preference. |

Everything else on the account is shared.

## Known limitation: `notification_preferences` is one JSONB blob

`users.notification_preferences` holds the whole notification matrix in a
single JSONB column, and the client rewrites the whole blob on every
toggle. Two devices that change *different* notification toggles at the
same time therefore clobber each other: the later write wins for the whole
blob, not just for the toggle it changed.

The fix is a server-side deep merge - an RPC that merges a patch into the
existing JSONB instead of replacing it, plus a client that sends only the
toggle it changed. It was deliberately not done here: the merge has to run
inside Postgres, where it cannot be unit tested from this repository, and a
broken merge would corrupt every notification setting on the account. Until
that exists, treat the notification matrix as "last writer wins" and avoid
changing notification settings on two devices at the same time.
