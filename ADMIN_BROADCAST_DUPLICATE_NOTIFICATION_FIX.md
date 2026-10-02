# Admin broadcast shown twice for a single "Resend" click — root cause & fix

## Symptom

Admin clicks **Resend** once in `matchme_admin`. The target user's Android device
shows the **same** notification twice at the same time (same title, same body,
both "now"), e.g. `Test title for Eran` / `test message for Eran`.

The two tray entries are **not** identical in rendering (different small-icon
accent colour, only one carries the alert bell), which is the fingerprint of two
different writers creating one logical notification.

## Where the push comes from (server side — sanity-checked, behaves correctly)

1. `admin_resend_broadcast_now(p_broadcast_id, p_request_id)` —
   `supabase/migrations/20260924000000_admin_broadcast_resend_idempotency.sql`.
   One click → one nonce → exactly one `admin_broadcasts` copy
   (partial unique index `idx_admin_broadcasts_resend_request_unique`), then
   `send_admin_broadcast(new_id, 20000, 0)`.
   The admin app (`matchme_admin/lib/main.dart` `_resendNow`) guards the button
   with `_resendInFlight` and a per-click nonce, so a double-tap cannot create a
   second copy. **No server-side duplicate found.**
2. `send_admin_broadcast()` (`20260923000000_*`) fans out one
   `notification_queue` row per eligible (user, session) via
   `queue_fcm_notification(...)`.
3. `supabase/functions/cron-jobs` → `handleNotificationQueueProcessing()`
   claims each row race-safely (`update ... .eq('status','pending')`) and calls
   `sendFcmV1()` **once** per row. There is no DB trigger / pg_net webhook that
   also posts queue rows (`process_notification_queue()` is dead code).
4. `sendFcmV1()` always sends **`notification` (title+body) + `data`** with
   `android.notification.tag = admin_<broadcast_id>`,
   `channelId = admin_broadcasts`, `defaultSound: true`, `priority: HIGH`.
   ▼ This is the trigger for the duplicate on the client.

## Root cause (client side, Android — `lib/main.dart` + `lib/services/admin_broadcast_service.dart`)

Because the FCM message contains a **`notification` block**, the Android/FCM SDK
draws the tray entry itself whenever the app is **not in the foreground**
(minimised / killed / device just rebooted):

* Firebase only delivers to `FirebaseMessaging.onMessage` when the app is in the
  foreground; otherwise `FlutterFirebaseMessagingReceiver` enqueues the message
  to the background isolate
  (`firebase_messaging-16.7.0/.../FlutterFirebaseMessagingReceiver.java`,
  lines 66-92) → `FirebaseMessaging.onBackgroundMessage`.

At the same time `_firebaseMessagingBackgroundHandler` (lib/main.dart:681) called

```dart
AdminBroadcastService.handleBroadcastMessage(message);
```

which ends in `_shouldShowOsNotification(message)` — and that helper returned
`true` unconditionally on mobile ("Always show the OS notification on mobile,
foreground AND background/killed") → `MobileLocalNotificationService.showAdminBroadcastNotification(...)`
posted a **second** tray entry for the same push.

Why Android does not collapse the two:

| Writer | Notification identity |
| --- | --- |
| Android/FCM SDK (from the payload) | `tag = admin_<broadcast_id>` (from `android.notification.tag`) |
| `MobileLocalNotificationService` | `id = broadcastId.hashCode()`, **no tag** |

Two different identities ⇒ two visible notifications. (If the server had really
sent twice to the same token, both FCM entries would share the tag and Android
would replace instead of stacking — so the visible pair proves a system-entry +
app-entry pair.)

Secondary writer removed as well: for admin pushes the background handler also
called `BackgroundService.triggerNotificationCheck(...)` (native
`checkNotifications` → `MatchMeBackgroundService.showTranslatedNotification`),
which renders the passed `senderName`/`translatedContent` as a chat-style
notification. For a broadcast those values are the *broadcast title/body* (data
has no `title`/`body`, so the code fell back to `message.notification.title/body`)
— i.e. an extra copy of the same text.

### Regression origin

`git show HEAD:lib/services/admin_broadcast_service.dart` shows the last
committed version was duplicate-safe:

```dart
if (_appInForeground) return true;
return message.notification == null;
```

An **uncommitted** working-tree change replaced that with an unconditional
`return true` (comment: *"Always show the OS notification on mobile, foreground
AND background/killed"*) while fixing "background admin pushes never showed".
That change is exactly what introduced the double tray entry. The fix below keeps
the intended behaviour (foreground always posts its own entry) while skipping the
Dart post in the background isolate when the OS already drew it, and no longer
depends on `_appInForeground` (which stays `false` in the background isolate and
is only set after the first lifecycle callback in the UI isolate).


## Fix

1. `lib/services/admin_broadcast_service.dart`
   * `handleBroadcastMessage(..., {bool fromBackground = false})` and
     `_handleBroadcastMessage(..., {bool fromBackground = false})` now carry the
     origin of the call.
   * `_shouldShowOsNotification(message, {fromBackground})` returns `false` when
     `fromBackground && message.notification != null` — in that state the OS has
     already drawn the entry, so Dart must not post it again. Data-only pushes
     (`notification == null`) and the foreground isolate keep posting locally.
2. `lib/main.dart`
   * `_firebaseMessagingBackgroundHandler` now calls
     `AdminBroadcastService.handleBroadcastMessage(message, fromBackground: true)`.
   * Admin broadcasts are no longer routed through the native
     `BackgroundService.triggerNotificationCheck` chat path (`isAdmin` removed
     from that condition; the native path is for chat/match/expiry only).

Behaviour after the fix:

| App state | Payload | Tray entries |
| --- | --- | --- |
| Foreground | notification + data | 1 (Dart / flutter_local_notifications, as before) |
| Background / killed | notification + data | **1** (Android/FCM SDK) — was 2 |
| Background / killed | data only | 1 (Dart) |

## Verification

1. `dart analyze lib/main.dart lib/services/admin_broadcast_service.dart` →
   no issues.
2. `flutter test test/services/admin_broadcast_service_test.dart` → 5/5 pass
   (foreground posts, background+notification skips, background data-only posts,
   iOS same as Android, desktop never posts).
3. Manual: with the device backgrounded (and separately with the app killed),
   click **Resend** once in the admin app → exactly one tray entry per push.
   In foreground → still exactly one entry (FCM never auto-displays in the
   foreground).
4. Optional DB check for the same broadcast (should be one row per token):

```sql
select status, count(*) from public.notification_queue
where (data->>'broadcast_id') = '<broadcast_id>'
group by status;
```

## Related observations (not changed)

* `get_users_for_broadcast()` returns one row per **non-revoked session** holding
  an `fcm_token`, so a user with several live sessions gets several queue rows /
  `admin_broadcast_deliveries` rows. Those extra rows are also what the per-24h
  frequency guard counts and what `actual_sent_count` accumulates, so the
  counters can exceed the "one push per user" intuition. Multi-device delivery is
  intended; only a duplicated *session row for the same device* would be a bug.
* The FCM/OS entry plays sound according to the channel / `defaultSound`, so it
  ignores the user's in-app "admin announcements" sound preference that
  `MobileLocalNotificationService` honours — which is why the two (formerly)
  duplicate entries rendered differently.

