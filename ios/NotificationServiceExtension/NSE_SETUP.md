# iOS Notification Service Extension — setup (5 min in Xcode)

The extension source (`NotificationService.swift` + `Info.plist` in this
folder) is complete and crash-safe, but the Xcode target is intentionally
**not** wired into `ios/Runner.xcodeproj` — hand-editing `project.pbxproj`
without Xcode to verify risks breaking the iOS build, so this stays a
checklist instead.

## Step 1 — create the target
1. Open `ios/Runner.xcworkspace` in Xcode.
2. File → New → Target → **Notification Service Extension** → name it
   `NotificationServiceExtension`, bundle ID
   `<app-bundle-id>.NotificationServiceExtension`.
3. When Xcode offers to activate the scheme, choose **Cancel**.
4. Delete the template files Xcode generated inside the new group, then drag
   this folder's `NotificationService.swift` + `Info.plist` into the new
   target (tick the extension target, untick Runner).

## Step 2 — App Group (required for future key handoff)
1. Runner target → Signing & Capabilities → **+ Capability → App Groups** →
   add `group.com.example.matchme` (use the production prefix, e.g.
   `group.com.matchme.app`, for store builds).
2. Same for the `NotificationServiceExtension` target (both must list it).
3. Update `NotificationService.appGroup` in the Swift file to the exact group.

## Step 3 — verify server payload (already done)
The extension only runs when `mutable-content: 1` is set — `push-message`
and `cron-jobs` already send it on every push, plus `matchId/match_id`,
`kind/type`, `senderId`, `recipientId` in `data`. No server change needed.

## Step 4 — E2EE key handoff (future, not implemented)
For real decrypted previews, the Flutter app must write the chat's message
key to the shared group defaults:
`UserDefaults(suite)["nse_keys_<matchId>"] = <base64 key>`, cleared on
logout. Then implement AES-GCM inside `trySharedDecrypt` (keep it allocation-
light: 30 s / ~24 MB budget). Until then the extension groups threads and
keeps the localized server placeholder — still a strict improvement over
ungrouped generic cards.

## Step 5 — build & test
1. `flutter build ipa` (or Archive in Xcode) — both targets must sign with
   the same team + `aps-environment`.
2. Kill the app, send a chat → tray card appears with per-chat grouping.
3. Confirm `serviceExtensionTimeWillExpire` path: no blank cards in logs.
