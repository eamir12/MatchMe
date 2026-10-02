# Anchored Summary

## Goal
- Fix Android build failures/warnings and debug a Riverpod crash causing chat messages to turn blank after a few seconds.

## Constraints & Preferences
- Must eliminate all build warnings and errors; plugin authors' KGP warnings are acceptable only if there is no substitute.

## Progress
### Done
- **compileSdk fix:** changed `compileSdk = flutter.compileSdkVersion` → `compileSdk = 36` in `android/app/build.gradle.kts:13`; also forced `compileSdk = 36` for all library subprojects via `afterEvaluate {}` in `android/build.gradle.kts`.
- **Kotlin classpath:** added `buildscript` block with `org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20` and `plugins.withId("com.android.library") { apply(plugin = "org.jetbrains.kotlin.android") }` so `file_picker` 11.0.2 Kotlin sources compile even when the plugin itself skips KGP (AGP >= 9).
- **Kotlin version warning (2.2.10 → 2.2.20):** added `kotlin_version=2.2.20` to `android/gradle.properties`; Flutter's `VersionFetcher.getKGPVersion()` reads this property and stops warning.
- **Migrator flags:** kept `android.builtInKotlin=false` and `android.newDsl=false` (required because 19+ plugins still apply KGP, which breaks with built-in Kotlin).
- **Research on plugin substitution:** looked up pub.dev, GitHub issues (plus_plugins#3745, Flutter#184836) for all 19 KGP-applying plugins; **none have a version that drops KGP** – the ecosystem migration from Flutter 3.44 (released 2026-05-15) is less than 8 days old, and most plugins still apply KGP unconditionally.

### In Progress
- **Chat messages turning blank after a few seconds.** A Riverpod assertion error fires in `StreamProvider<List<ChatModel>>#f3d45` (the `recentChatsProvider` in `home_providers.dart:169`):
  ```
  Failed assertion: 'actualPausedCount == expectedPausedCount':
  Expected pausedActiveSubscriptionCount to be 2, but was 3.
  ```
  Stack trace shows the crash originates from `_TickerModeState._updateEffectiveMode` → `ConsumerStatefulElement._updateTickerMode` → `ProviderSubscriptionImpl.resume` → `ProviderElement._onChangeSubscription`. This causes a rebuild during which messages can briefly render with empty `contentOriginal`, making them appear blank.

### Blocked
- The KGP warning from Flutter 3.44 about plugins applying KPG cannot be eliminated until plugin authors release updated versions (tracked by Flutter issue #184836). No current plugin upgrade path exists.

## Key Decisions
- Keep `android.builtInKotlin=false` and `android.newDsl=false` because the plugin ecosystem has not migrated to Built-in Kotlin yet.
- Override `kotlin_version` in `gradle.properties` instead of enabling built-in Kotlin (which would break the 19+ plugins that still apply KGP).
- The Riverpod pause-count assertion is a known issue with `autoDispose` + stream providers + ticker mode changes.

## Next Steps
1. Debug `chatMessagesProvider` in `lib/providers/chat_provider.dart` (line 198, `StreamProvider.autoDispose.family<List<ChatMessageModel>, String>`) – test removing `autoDispose` or adding `ref.keepAlive()` so the provider doesn't get re-disposed during ticker-mode changes.
2. Verify that the decrypted `contentOriginal` is correctly persisted by `mergeMessages` and not overwritten by a subsequent `localDb.watchMessages` emission.
3. Confirm the build still passes with zero warnings/errors after the provider fix.

## Critical Context
- **Flutter 3.44.0** (2026-05-15) is the first stable to ship AGP 9 + Built-in Kotlin. The migrator set `android.builtInKotlin=false` / `android.newDsl=false` for backwards compatibility.
- `file_picker` 11.0.2 has AGP-9 guard but skips KGP, leaving Kotlin sources uncompiled unless the root build forcefully applies KGP.
- Riverpod assertion line: `package:riverpod/src/core/element.dart:1086 pos 7`. Occurs during `ConsumerStatefulElement._updateTickerMode` (ticker mode changes triggered by navigation). The `pausedActiveSubscriptionCount` mismatch suggests a double-pause or pause-on-already-paused subscription.
- The `chatMessagesProvider` line 198 uses `autoDispose` and watches `chatKeyProvider.select((s) => s.privateKeyBytes)`. A key-state change restarts the entire provider, which may trigger the pause-count bug.
- **`syncMessages` in `ChatSyncService` (line 60-160)** fetches all messages from Supabase and writes them via `localDb.saveMessages(matchId, data)` at line 82. This **replaces all messages for the match** in the local DB. If the server returns `content_original` as empty string (because the original (unencrypted) content is not stored server-side), this **wipes out the decrypted `contentOriginal`** that was previously persisted by `mergeMessages` after decryption. The `watchMessages` stream then re-emits with empty `contentOriginal`, and the UI shows blank bubbles until decryption re-runs on the next provider emission cycle.

## Relevant Files
- `android/app/build.gradle.kts`: `compileSdk = 36` (line 13), `kotlinOptions` (line 22-24)
- `android/build.gradle.kts`: buildscript with KGP classpath (line 1-9), `plugins.withId` KGP apply (line 32-34), `afterEvaluate` compileSdk/namespace (line 36-50, 52-64)
- `android/gradle.properties`: `kotlin_version=2.2.20` (line 33), migrator flags (line 31-32)
- `android/settings.gradle.kts`: plugin declarations (line 20-24)
- `lib/providers/home_providers.dart`: `recentChatsProvider` (line 169) – source of the Riverpod assertion error
- `lib/providers/chat_provider.dart`: `chatMessagesProvider` (line 198, `autoDispose`), `ChatSyncService.syncMessages` (line 60-160, calls `saveMessages` at line 82)
- `lib/screens/chats/chat_screen.dart`: chat UI, `_MessageBubble` (line 1013), message text rendered from `message.contentOriginal` (line 1205-1207)
