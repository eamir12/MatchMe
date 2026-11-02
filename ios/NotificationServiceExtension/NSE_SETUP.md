# iOS Notification Service Extension

The `NotificationServiceExtension` target is wired into `Runner.xcodeproj` and
embedded in the app. It adds a matched user's avatar to eligible remote
notifications only when that image is already present in the shared local
cache. It does not fetch photo URLs or add them to push payloads.

## Required Apple signing setup

The project uses `group.com.app.matchme` in the Runner and extension
entitlements. Before distributing an iOS build:

1. Register that App Group identifier in the Apple Developer account for the
   app's team.
2. Enable the App Group for both the app ID `com.app.matchme` and extension
   app ID `com.app.matchme.NotificationServiceExtension`.
3. Regenerate or update both targets' provisioning profiles so they include
   the App Group entitlement, and sign both targets with the same team.
4. If that identifier is unavailable, choose an App Group registered to the
   team, update both Runner entitlement files and the extension entitlement
   file, and update `MatchMeBackgroundService.notificationAvatarAppGroup` and
   `NotificationService.appGroup` to the same value.

The repository cannot verify Apple Developer registration, provisioning
profiles, or the final signed archive. An iOS build must be completed on macOS.

## Behavior and verification

The app copies a resized avatar already in its local image cache into the App
Group. The extension hashes the notification's match ID, looks up that local
file, and attaches it. Missing cache entries, unavailable entitlements, or
attachment errors leave the original text notification intact.

The push must be an alert with `mutable-content: 1` for iOS to invoke the
extension. Build/archive on macOS, install a correctly signed build, then test
notifications with the app foregrounded, backgrounded, and terminated, both
with a pre-cached avatar and with a cache miss. iOS controls whether and how
prominently an attachment is shown in each notification presentation; compact
banners are not guaranteed to display the image.
