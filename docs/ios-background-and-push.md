# Background location, presence and push — cross-platform architecture

This document describes how MatchMe keeps a user's location and presence
alive while the app UI is closed, how it stays consistent across Android and
iOS, and how to verify each piece on a real device.

It is the reference for the iOS parity work; read it before changing
`ios/Runner/MatchMeBackgroundService.swift` or the permission flow.

---

## 1. What the server expects

Everything the app does in the background lands in Supabase. The server-side
contracts that matter:

| Contract | Where | Rule |
|---|---|---|
| `user_activity.last_activity` | `online_presence_user_ids(61)`, `is_user_truly_visible` | A user is **online** only if the heartbeat is younger than **61 seconds**. |
| `user_locations.updated_at` | `is_user_truly_visible` | A user is **visible** only if their location row is younger than **15 minutes**. |
| `update_user_activity(p_user_id)` | RPC | UPSERTs `last_activity = now()`, `is_online = true`, and derives `is_visible` from `users.user_visibility_setting`. |
| `update_user_location(p_user_id, p_latitude, p_longitude, p_speed, p_heading)` | RPC | UPSERTs the location row **and** calls `update_user_activity`, so one location write refreshes both signals. |

Consequences:

* The presence heartbeat interval must stay **comfortably below 61 s** on
  every platform. Anything at or above 61 s makes the user flicker in and out
  of the admin counts.
* `cleanup_old_user_locations` deletes rows older than 15 minutes (pinned
  home-bases are exempt), which lines up with the visibility window.

---

## 2. Platform model

|  | Android | iOS |
|---|---|---|
| Keeps the process alive in the background | Foreground service (`foregroundServiceType="location"`) + WorkManager chain | `UIBackgroundModes: location` + `CLLocationManager` with `allowsBackgroundLocationUpdates` |
| Background heartbeat driver | Coroutine loop (30 s) + WorkManager one-time chain (≤55 s) | Native timer (25 s) **plus** every `CLLocationManager` callback |
| Keeps running after the user swipes the app away | **Yes** (the foreground service is re-promoted in `onTaskRemoved`) | **No** — a swipe-up in the app switcher terminates the app, and iOS then stops delivering location updates and remote notifications until the user launches it again |
| Background location prerequisite | `ACCESS_BACKGROUND_LOCATION` (API 29+) | `CLAuthorizationStatus.authorizedAlways` |
| Recovering after a network drop | `ConnectivityManager` + Supabase reachability probe | `NWPathMonitor` + automatic retry |
| Background Matching Mode OFF | no native GPS; presence still kept alive by the WorkManager chain | no coordinate upload; presence still kept alive by the native heartbeat (the location manager keeps the process alive) |

The iOS side deliberately mirrors the Android method-channel surface so both
platforms behave the same from Dart's point of view.

### 2.1 The presence / location split (both platforms)

| | Presence (`update_user_activity`) | Coordinates (`update_user_location`) |
|---|---|---|
| Gated by visibility? | **No** — Android's heartbeat coroutine and iOS's native timer both run regardless | **Yes** — only visible users upload |
| Gated by Background Matching Mode? | **No** on either platform | **Yes** on iOS (`backgroundMatchingMode`); on Android the switch stops the native GPS entirely |
| Gated by the app being open? | No (as long as the platform keeps the process alive) | No |

Why the split exists: an invisible user must still count as *online*
(`online_presence_user_ids` does not look at visibility) but must not be
tracked. Android expresses that with a foreground service that stays alive
without GPS; iOS has no foreground service, so the location manager stays
running at `kCLLocationAccuracyNearestTenMeters` purely to keep the process
alive — the same effect, and it uploads nothing.


---

## 3. iOS native service

`ios/Runner/MatchMeBackgroundService.swift` owns everything iOS does while
the UI is closed.

### 3.1 Location

* `updateLocationTracking()` decides whether `CLLocationManager` should run.
  The gate is `(isVisible || logged in) && !pinned` (or an active live
  location share) — see the presence/location split in §2.1.
* **Background Matching Mode gates the upload**, not the tracking:
  `startMatchingTimer()` and `sendLatestMatchingLocationIfDue()` both
  require `backgroundMatchingMode`. Before this, the setting did *nothing*
  on iOS, which is a bug of its own — the user asked for "GPS only while
  the app is open" and iOS kept the GPS on.
* The accuracy follows what will actually be uploaded: high accuracy only
  when the position is going to be transmitted, otherwise
  `kCLLocationAccuracyNearestTenMeters` (the updates exist purely to keep
  the process alive).
* `isOnline` is deliberately **not** part of the gate. Android keeps its
  foreground service alive while offline and simply retries the upload; iOS
  used to stop GPS *and* the heartbeat on the first failed connectivity probe,
  and since Dart cannot deliver `setConnectivity(true)` while the app is
  suspended, that one flap silently ended background tracking for the rest
  of the session.
* Uploads are best-effort: a failed request is retried on the next location
  fix, and any successful response flips `isOnline` back to `true`.
* `authorizedWhenInUse` is detected and reported to Dart as the
  `location_always` permission issue **only while Background Matching Mode is
  ON**, and cleared as soon as "Always" is granted or the mode is turned off
  — see §5.1.

### 3.2 Presence heartbeat

* Interval: **25 s** (below the 61 s server window, with margin).
* Success is written to the ring buffer on the first heartbeat and on
  recovery only; failures are latched on transition. That keeps a long
  background session from evicting the rest of the 300-entry log.
* Driven by **both** a `Timer` and every `CLLocationManager` callback. An app
  kept alive by the `location` background mode still receives location
  callbacks and runs its run loop, so the callback-driven heartbeat is what
  survives suspension.
* Never stopped by a connectivity loss — a failed request is harmless and the
  service recovers by itself (parity with Android's heartbeat coroutine).
* Refreshes the JWT and retries once on 401/403.
* Watches for pinned-home-base transitions, like Android's heartbeat does.

> **Do not rely on `BGTaskScheduler` for presence.** iOS does not honour
> sub-minute `earliestBeginDate` values; `BGAppRefreshTask` typically runs
> minutes-to-hours later. `BGTaskScheduler` is a best-effort keep-alive only.

### 3.3 Connectivity

`NWPathMonitor` gives the service an OS-level network signal. When the path
becomes satisfied again the service immediately retries the heartbeat, resumes
location uploads and re-evaluates tracking — the iOS equivalent of Android's
`NetworkCallback.onAvailable` → `refreshConnectivityFromProbe`.

### 3.4 Diagnostics

The service keeps a 300-entry ring buffer, mirroring Android's
`diagBuffer`. It is retrieved over the method channel:

```dart
final lines = await BackgroundService.getDiagnostics();
```

The snapshot starts with a machine-readable header and then the event log:

```
heartbeatTimerArmed=true
visible=true
online=true
appInForeground=false
authorization=always
lastHeartbeatSuccess=4s ago
lastLocationUpload=6s ago
networkAvailable=true
pinned=false
<timestamp> ▶️ Background service starting (…)
<timestamp> 🌙 App entered background — handing GPS over to the native service
…
```

`heartbeatTimerArmed` only says the service was started and not stopped — iOS
can still have suspended the process. The two liveness numbers are the
authoritative answer.

`lastHeartbeatSuccess` / `lastLocationUpload` are the two numbers to look at
when a user "disappears from the admin counts": if the heartbeat age grows
past ~61 s, the user is outside the server's presence window.

The Dart app dumps the buffer on resume (`lib/main.dart`) and right after the
native service starts (`lib/services/background_service.dart`). Every entry is
also written to the OS log with the `[MatchMeBG]` prefix.

**Use this first** when debugging background behaviour — it shows the
authorization status, the GPS handover, every heartbeat and every upload
result.

---

## 4. Method-channel parity

Channel: `matchme/background_service`.

| Method | Android | iOS | Notes |
|---|---|---|---|
| `startService` / `stopService` / `isRunning` / `initialize` | ✅ | ✅ | |
| `updateVisibility` / `setConnectivity` / `updateAppForeground` | ✅ | ✅ | |
| `updateBackgroundMatchingMode` / `updateConfig` / `updateToken` | ✅ | ✅ | |
| `startLocationShare` / `stopLocationShare` / `updateLocationShareDuration` | ✅ | ✅ | |
| `getDiagnostics` | ✅ | ✅ | 300-entry ring buffer on both |
| `updatePinnedState` | ✅ | ✅ | Re-evaluates GPS/foreground state |
| `consumePermissionIssue` / `setPermissionIssue` | ✅ | ✅ | iOS raises `location_always` |
| `getLocationAuthorizationStatus` | ❌ | ✅ | iOS-only: the authoritative `CLAuthorizationStatus` |

Android-only methods (`checkNotifications`, `wasMatchNotified`,
`markMatchNotified`, `cancelServerCard`, `setViewingChat`,
`clearViewingChat`, `resetChatNotification`, `dismissChatNotification`,
`isIgnoringBatteryOptimizations`, `requestIgnoreBatteryOptimizations`,
`setPermissionStrings`, `setBackgroundNotificationStrings`,
`refreshBackgroundNotification`, `setSecureString`, `getSecureString`,
`clearSecureKeys`, `getWorkManagerLastSuccessMs`, `traceLog`) are **not**
implemented on iOS. The Dart callers are all `Platform.isAndroid`-guarded, so
they are no-ops on iOS rather than errors.

The iOS equivalents for the notification-dedupe methods already exist on the
Dart side (`lib/services/mobile_local_notification_service.dart` uses
`getActiveNotifications()` on iOS), so no native counterpart is needed.

---

## 5. Permissions

### 5.1 The iOS "Always" upgrade — the classic trap

iOS shows the "Allow While Using / Change to Always" prompt **once per
install**. If the user declines it, the OS never asks again and the only
recovery path is Settings.

The app therefore has to:

1. Ask for "Always" whenever it holds "While Using" — **not** only on the
   first launch. This used to be dead code behind an early
   `return true` in `MobileLocationService.handleLocationPermission`.
2. Detect the stuck state and offer a **Settings deep link**
   (`PermissionCoordinator._ensureIosBackgroundLocation`). The
   `location_always` issue is only recorded while **Background Matching Mode
   is ON** — raising it for every "While Using" user would show the dialog on
   every launch even to users who never asked for background matching.
3. Never silently disable Background Matching Mode because of it — the user
   explicitly asked for it, so the app raises a `location_always` permission
   issue instead and keeps the mode on.

On iOS `Permission.locationAlways.status` returns `permanentlyDenied` for
`authorizedWhenInUse`, and `Permission.locationAlways.request()` throws
`MISSING_WHENINUSE_PERMISSION` if "While Using" has not been granted yet —
hence the ordering (foreground first, then "Always").

### 5.2 Cross-platform audit

`PermissionCoordinator.checkAndPromptIfNeeded` audits both platforms:

| | Android | iOS |
|---|---|---|
| Foreground location | `Permission.location` | `Permission.location` |
| Background location | `Permission.locationAlways` (`ACCESS_BACKGROUND_LOCATION`) | `Permission.locationAlways` (`authorizedAlways`) |
| Notifications | `Permission.notification` (API 33+) | requested by `firebase_messaging` |
| Battery optimisation | `requestIgnoreBatteryOptimizations` | n/a (no equivalent) |

`UserPreferencesNotifier.validateBackgroundMatchingPermission()` is
cross-platform too: Android switches the mode off when the permission was
revoked, iOS raises the permission issue instead.

---

## 6. Push notifications on iOS

### 6.1 The entitlement

Every build configuration signs with `CODE_SIGN_ENTITLEMENTS =
$(MM_CODE_SIGN_ENTITLEMENTS_FILE)` → `Runner/Runner.sideload.entitlements`
(`ios/Flutter/Signing.xcconfig`).

That file **must** contain:

```xml
<key>aps-environment</key>
<string>$(APS_ENVIRONMENT)</string>
```

Without it the app is signed without push capability:
`registerForRemoteNotifications()` never returns a device token, FCM has no
route to the device, and **not a single notification is delivered** — while
the Firebase Installation ID still registers, so the server-side send
"succeeds" and the failure is completely silent.

`$(APS_ENVIRONMENT)` resolves per configuration from
`ios/Runner.xcodeproj/project.pbxproj` (`development` for Debug/Profile,
`production` for Release) and must match the provisioning profile. In
practice that means a **Release build must be signed with a distribution
profile** (TestFlight/App Store); signing Release with a development profile
produces an entitlement/profile mismatch and push (or the install itself)
fails. Use a Debug/Profile build for development signing.

> The **unsigned** sideload artifact (`codemagic.yaml`,
> `flutter build ios --release --no-codesign`) is re-signed by the sideload
> tool with its own entitlements, so it never has APNs. Push only works in
> TestFlight / App Store builds.

### 6.2 Honest self-checks

`AppDelegate.hasApsEnvironmentEntitlement()` combines three signals,
strongest first:

1. **The entitlement of the running (signed) task.** Read with
   `SecTaskCopyValueForEntitlement`; the entry points are resolved with
   `dlsym` at runtime because they are only declared for macOS / Mac
   Catalyst, so the inspection is skipped (not fatal) on a plain iOS build.
2. **The outcome of the real APNs registration.** A rejection proves the
   signed app has no usable push entitlement — whatever the provisioning
   profile says. This is the signal that actually matters on iOS.
3. **The provisioning profile scan** (fallback for unsigned / sideloaded
   builds, where there is no signed task to inspect).

The original implementation only did step 3, which is exactly the check that
hid this bug: the profile advertised push while the app was signed without
it.

`AppDelegate.pushDiagnostics()` returns:

```dart
{
  'hasApsEnvironment': bool,
  'apsEnvironment': 'development' | 'production' | null,
  'apnsRegistrationAttempted': bool,
  'apnsTokenRegistered': bool,
  'apnsRegistrationError': String | null,
}
```

Available as `AppInfoService.getPushDiagnostics()`.

Read it like this:

| `apnsRegistrationAttempted` | `apnsTokenRegistered` | Meaning |
|---|---|---|
| `false` | `false` | Registration is still pending (normal in the first seconds after launch). |
| `true` | `true` | Push is configured correctly. |
| `true` | `false` | **Push is broken** — the app is signed without a usable `aps-environment`, or the profile is wrong. |

---

## 7. Verification checklist (real device)

### 7.1 Background location + presence

1. Install, enable **Background Matching Mode**, set the profile **visible**.
2. Grant location. Confirm Settings → Privacy → Location → MatchMe shows
   **Always** (not "While Using").
3. Close the UI — **lock the screen or switch apps, do NOT swipe the app
   away** (see §8: a swipe-up is a force-quit on iOS).
4. Wait 90 seconds.
5. In Supabase, confirm both are fresh:
   * `select last_activity, is_online from user_activity where user_id = '<uid>';`
     → `last_activity` must be < 61 s old.
   * `select updated_at from user_locations where user_id = '<uid>';`
     → must be < 15 min old.
6. In the admin app the user must stay in the **online** and **visible** live
   cards.
7. The Flutter console (on resume) must show the native diagnostics: the
   header with `lastHeartbeatSuccess=` and `lastLocationUpload=` a few
   seconds old, plus `🌙 App entered background`, `💓 Heartbeat OK` and
   `📍 Location uploaded` entries. (Heartbeat/upload successes are logged on
   the first success and on recovery, not on every tick, so the 300-entry
   buffer is not evicted by routine traffic.)
8. Turn Background Matching Mode off and repeat (with the UI closed): the
   user must stay in the **online** card (presence is not gated by the mode
   on any platform) but `user_locations.updated_at` must **stop** advancing.
   Note the Dart foreground path is not mode-gated, so this only holds once
   the UI is closed — same on Android.

### 7.2 Push

1. Build a TestFlight/App Store build (the unsigned sideload IPA has no APNs).
2. Launch once. The console must print:
   * `🔔 [FCM] iOS push diagnostics: {hasApsEnvironment: true, apsEnvironment: production, apnsRegistrationAttempted: true, apnsTokenRegistered: true, …}`
   * `🔔 [FCM] iOS push route — FID: …, APNs token: …`
     — an **`APNs token: (none — push cannot be delivered)`** means the
     entitlement is still missing.
   * `🔔 [FCM] APNs REJECTED the registration: …` means the app is signed
     without a usable push entitlement.
3. Trigger a push from the backend (`push-message`).
4. Confirm the notification arrives in the tray, and that tapping it opens the
   right screen.

---

## 8. Things that cannot be fixed

* **Force-quitting the app terminates it on iOS.** A swipe-up in the app
  switcher is a force-quit: iOS stops delivering location updates *and*
  remote notifications to the app until the user launches it again. Android
  behaves differently — its foreground service survives the swipe and is
  re-promoted in `onTaskRemoved` — so a user who swipes the app away stays
  "online" on Android and disappears on iOS. **There is no client-side fix
  for this on iOS**; the only mitigations are server-side (a presence lease
  that outlives the client) or asking the user to lock the screen instead of
  swiping the app away.
  *Force-stopping* on Android has the same effect as force-quitting on iOS.
* **iOS has no equivalent of Android's foreground-service notification**, so
  there is no persistent "MatchMe Active" banner. The `location` background
  mode is the only lever, and it requires "Always" authorization.
* **`BGTaskScheduler` cannot guarantee sub-minute execution.** Any design
  that needs a sub-61-second cadence must be driven by location callbacks or
  by a foreground service — not by background tasks.
* **iOS cannot keep a backgrounded app alive without location, audio or
  VoIP.** That is why the location manager keeps running for invisible
  users and for users with Background Matching Mode off (§2.1, §3.1): it is
  the only way to keep the presence heartbeat alive.
* **A pinned home-base on iOS only gets "best effort" presence.** The pin
  deliberately stops the GPS, so the app has no way to stay alive; only the
  significant-change monitor is kept running, which wakes the app for
  location events rather than continuously. Android covers the same case
  with its WorkManager heartbeat chain, so a pinned backgrounded user can
  be "online" on Android and not on iOS. (The server already treats
  heartbeats as best-effort — see the note in
  `20262111000000_presence_online_only_and_dashboard_stats.sql` — and
  intentionally excludes pin-only users from the "online" count.)
* **Silent pushes are not a substitute.** A silent push would wake the app
  for a presence refresh, but iOS does not deliver remote notifications to a
  force-quit app, so it would not help the case above — and it would add
  server-side scheduling, battery cost and a new failure surface.

---

## 9. Change log

| Date | Change |
|---|---|
| 2026-10 | iOS parity work: `aps-environment` entitlement restored; honest entitlement/APNs diagnostics; native diagnostics ring buffer (`getDiagnostics`); `updatePinnedState`; permission-issue channel; "Always" authorization escalation + Settings deep link; event-driven 25 s presence heartbeat that survives connectivity flaps; `NWPathMonitor` connectivity recovery; presence parity for invisible users; cross-platform permission auditing. |
| 2026-10 | Review fixes: `location_always` only raised while Background Matching Mode is on; native stop now runs on iOS sign-out; `startService` reports the real foreground state; notification permission no longer gated on the push entitlement; liveness timestamps persisted across process relaunches; success logging latched to protect the diagnostics buffer; `SecTask` references released; pinned-branch behaviour documented honestly. |
