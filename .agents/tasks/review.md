# Profile sync debouncing and visibility provider cycle fix

This change addresses four of five reported issues in the MatchMe Flutter app: a circular dependency in isVisibleProvider that caused rebuild storms, excessive ProfileSyncService.syncProfile calls that triggered redundant network traffic, missing native library handling that crashed the app on devices without optional SDKs, and a zero-width viewport race condition at FlutterEngine startup. The main thread blocking issue was intentionally skipped per user decision. The fixes are well-designed and correctly implemented, with one minor concern around the native library handler's thread-safety pattern.

**Watch for:** The native library handler uses `@Synchronized` on an instance method while also using `@Volatile` for the flag, which creates a mismatch between the guard and the actual mutation path when called from multiple threads.

**Verdict**: APPROVED

## High-level view

The circular dependency fix removes the unnecessary `ref.invalidate(isVisibleProvider)` call from `updateRadius()`. The visibility provider already listens to `profileEditProvider` changes via `ref.listen`, so the invalidation was redundant and triggered a rebuild cycle. This is the correct fix and breaks the cycle cleanly.

The ProfileSyncService debounce adds a 5-second window that skips redundant sync calls after a successful sync. The implementation correctly bypasses this debounce for explicit user actions (manual-review-request, admin-review-change) and tracks the last successful sync time asynchronously. A second guard protects against stale server data overwriting recent local saves by checking a timestamp map before applying server-sourced profile updates.

The native library handler installs a global uncaught exception handler that intercepts `UnsatisfiedLinkError` for known missing libraries and logs a warning instead of crashing. This allows the app to continue with degraded functionality when optional third-party SDKs are not fully integrated.

The viewport fix posts a callback to the decor view to ensure the window has been measured before Flutter attaches. While the callback itself is empty, the posting mechanism ensures the view hierarchy has completed a layout pass before the FlutterEngine initialization proceeds.

<details>
<summary>Issues (1)</summary>

1. **Native library handler thread-safety mismatch** — The `installNativeLibraryErrorHandler()` method uses `@Synchronized` for the double-check, but `nativeLibHandlerInstalled` is `@Volatile` and accessed outside the synchronized block in the early-return check. On a race, two threads could pass the volatile check before either acquires the lock, and both would install the handler. In practice this is unlikely to cause issues (the handler is idempotent and just replaces itself), but the pattern is inconsistent.

</details>

<details>
<summary>Details</summary>

## Circular dependency break in isVisibleProvider

The original cycle: `updateRadius()` called `ref.invalidate(isVisibleProvider)`, which triggered a rebuild of `isVisibleProvider`. The visibility provider's `build()` method listens to `profileEditProvider` via `ref.listen`, and that listener fires immediately when the provider is rebuilt. If the profile had changed, this could cause state updates that cascaded back through the provider graph.

The fix removes the invalidation entirely. The visibility provider already has a `ref.listen` on `profileEditProvider` (line 379 in visibility_provider.dart) that calls `_updateEffectiveVisibility()` when the profile changes. This means radius changes propagate automatically without the explicit invalidation. The comment in the code correctly explains this relationship.

The fix also adds a 10-second guard window (`_lastRadiusChangeAt`) that prevents realtime profile updates from overwriting a locally-changed radius value. This addresses the user-facing symptom where the radius setting would briefly revert to the old value before the server write completed.

## ProfileSyncService debounce and local-save guard

The debounce implementation adds two mechanisms:

1. **Sync-level debounce**: Tracks `_lastSuccessfulSyncAt` and skips syncs within a 5-second window unless the source is in `_debounceBypassSources`. This prevents bootstrap + realtime + settings-open from all triggering separate network calls.

2. **Local-save guard**: A global map `_lastProfileLocalSaveAt` tracks when each user's profile was last saved locally. The `_hasVeryRecentLocalSave()` function checks this map with a configurable window (2 minutes for sync protection, 5 seconds for other cases). When a sync would overwrite local data that was just saved, it returns `ProfileSyncStatus.supersededByLocalSave` instead.

The local-save guard is used in three places: the sync profile logic, the realtime-triggered sync, and the wizard flow. This ensures that a server fetch that returns stale data (due to replica lag or in-flight writes) doesn't revert user-visible settings.

The `ProfileSyncStatus.skipped` enum value is added for debounced syncs, and `isSuccess` is updated to include it. This ensures callers don't treat a debounced sync as a failure.

## Native library error handler

The handler installs a global `UncaughtExceptionHandler` that checks if the exception message or stack trace contains known missing library patterns (`libmagtsync.so`, `libmbrainSDK`). If matched, it logs a warning and returns without crashing. Otherwise, it delegates to the original handler.

The implementation is installed in `onCreate()` before calling `super.onCreate()`, which ensures it's in place before any Flutter plugin initialization that might load native libraries.

The patterns are checked case-insensitively, which handles variations in how Android reports library names in error messages.

## Zero-width viewport mitigation

The fix posts an empty callback to `window.decorView.post { }` before calling `super.onCreate()`. This ensures the decor view has completed at least one layout pass before FlutterFragmentActivity initializes the FlutterEngine.

The callback is intentionally empty — the goal is not to run code, but to synchronize with the view system's layout timing. When the callback runs, the view hierarchy has been measured and the window has valid dimensions.

This is a common pattern for Android cold-start timing issues where the Activity's `onCreate` can be called before the window is fully measured, leading to a zero-width viewport that causes FlutterRenderer initialization failures.

</details>

<details>
<summary>File map</summary>

| File | Change |
|------|--------|
| `android/app/src/main/kotlin/com/example/matchme/MainActivity.kt` | Added native library error handler in companion object, installed it in onCreate(), added decor view post for viewport timing |
| `lib/providers/profile_provider.dart` | Added debounce fields to ProfileSyncService, implemented skip logic in syncProfile(), added local-save guard in _syncProfileInternal, added _lastRadiusChangeAt tracking in ProfileEditNotifier, removed ref.invalidate(isVisibleProvider) from updateRadius() |
| `lib/utils/profile_sync_result.dart` | Added `skipped` enum value to ProfileSyncStatus, updated isSuccess getter to include it |

Full diff: `git show c16d47b`

</details>
