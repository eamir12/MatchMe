# Supabase Realtime Concurrent Peak Connections – Analysis & Mitigation

## What the graph shows

- **Free plan limit:** 200 concurrent peak connections  
- **Peak in period:** 541 connections  
- **Overage:** 341 connections  
- Usage was low until **February 9th**, when it spiked to 541.

Supabase bills on **concurrent WebSocket connections**, not per channel. One app instance (browser tab or mobile app) = one connection; all Realtime channels (chat, presence, typing, etc.) share that single connection.

So **541 connections = 541 concurrent clients** (tabs + devices), not 541 channels.

---

## What Realtime is used for in this app

Realtime is used in these places (all over the **same** Supabase client, so same connection):

| Location | Channel(s) | Purpose |
|----------|------------|--------|
| **home_providers.dart** | `public:chat_messages:for_user_$userId` | New messages, chat list updates, notifications |
| | `public:matches:for_user_$userId` | Match list changes (e.g. deletions) |
| | `public:chats:for_user_$userId` | Chat list changes |
| **home_providers.dart** (dashboard) | `dashboard_stats_activity_$userId` | Activity stats |
| | `presence:online` | Online presence |
| | `dashboard_stats_visibility_$userId` | Visibility setting changes |
| **match_notification_provider.dart** | `match_notifications_$userId` | New match notifications |
| | `match_profile_updates_$currentUserId` | Matched users’ profile (e.g. photo) updates |
| **chat_provider.dart** | `public:chat_messages:match_id=eq.$matchId` | Live messages for the **open** chat (per screen) |
| **typing_provider.dart** | `typing:$matchId` | “Other user is typing” (per open chat) |

So: chat list + matches + chats + dashboard + presence + match notifications + **one** open chat’s messages and typing. Channel count is not the driver of the 541; **number of connected clients** is.

---

## Why the app went over the limit

1. **Multiple tabs (web)**  
   Each browser tab runs a full Flutter app and opens its own Supabase Realtime connection.  
   Example: 120 users × 4 tabs ≈ 480 connections from tabs alone.

2. **Web + mobile**  
   Same user on phone + laptop + 2 tabs = 4 connections. All count toward the peak.

3. **No disconnect when tab is hidden (web)**  
   Realtime is only disconnected on **mobile** when the app goes to background (`AppLifecycleState.paused`). On web, switching to another tab does not trigger that, so **every open tab keeps a live connection** even when not visible.

4. **No explicit disconnect on tab close (web)**  
   On `beforeunload`/`unload` the app does not disconnect Realtime. The server may keep the connection until timeout, so closed tabs can still contribute to the peak for a while.

5. **Possible traffic spike on Feb 9**  
   A real increase in users or in tabs per user (e.g. shared link, marketing, or users leaving many tabs open) would directly increase the peak.

6. **Reconnection behavior**  
   When a channel closes, providers call `ref.invalidateSelf()` after 2 seconds. That recreates subscriptions on the **same** connection, so it doesn’t create extra connections, but it’s worth keeping reconnects bounded (e.g. backoff) to avoid storms.

---

## What was changed in code (to prevent recurrence)

1. **Web: disconnect Realtime when tab is hidden**  
   On `document.visibilitychange`, when the page becomes hidden we call `Supabase.instance.client.realtime.disconnect()`. When it becomes visible again we call `realtime.connect()`.  
   Effect: Only the **visible** tab(s) hold a connection; background tabs release theirs and no longer count toward the peak.

2. **Web: disconnect Realtime on tab close**  
   On `beforeunload` and `pagehide` we disconnect Realtime so the server gets a clean close and doesn’t hold the connection until timeout.  
   Effect: Fewer “zombie” connections and a lower peak.

3. **Typing provider cleanup**  
   In `typing_provider.dart` `dispose()`, we now call `supabase.removeChannel(_ch)` in addition to `_ch.unsubscribe()`.  
   Effect: Consistent channel cleanup and no leftover channel references.

---

## Recommendations

1. **Monitor usage**  
   In Supabase Dashboard, set an alert when you approach 150–180 concurrent connections so you can act before hitting 200.

2. **Optional: single-tab UX on web**  
   Use `BroadcastChannel` or `localStorage` to detect another tab and show: “MatchMe is open in another tab. Use that tab to avoid multiple connections,” and optionally disconnect Realtime in the duplicate tab.

3. **Plan for growth**  
   If traffic is real and growing, consider the Pro plan (500 included connections) or optimize further (e.g. stricter “one active tab” behavior, or server-side limits).

4. **Reconnection backoff (future)**  
   Add exponential backoff + jitter when reconnecting after channel errors so many clients don’t reconnect at the same time (reduces burst load; doesn’t change peak billing by itself).

---

## File reference

- Realtime lifecycle (mobile): `lib/main.dart` – `didChangeAppLifecycleState` (disconnect on pause, connect on resume).
- Realtime subscriptions and cleanup:  
  `lib/providers/home_providers.dart`,  
  `lib/providers/chat_provider.dart`,  
  `lib/providers/match_notification_provider.dart`,  
  `lib/providers/typing_provider.dart`.
- Web visibility/unload handling: `lib/main.dart` – new web-only logic for `visibilitychange`, `beforeunload`, `pagehide`.
