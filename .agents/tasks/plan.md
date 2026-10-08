# Implementation Plan

## Issue 1: Circular Dependency in isVisibleProvider

### Problem Analysis
The circular dependency occurs in `updateRadius` in `ProfileEditNotifier`. The call chain is:

1. `updateRadius()` (line 3855) → calls `ref.invalidate(isVisibleProvider)` (line 3875)
2. `isVisibleProvider.build()` → imports `profile_provider.dart` (line 9 of visibility_provider.dart)
3. Inside `build()`, it reads `profileEditProvider(userId)` (lines 596-600, 652-654, 708-710)

This creates a cycle: `profileEditProvider` → invalidates `isVisibleProvider` → rebuilds → reads `profileEditProvider`.

The `ref.invalidate(isVisibleProvider)` on line 3875 of `profile_provider.dart` is unnecessary because:
- The visibility provider watches `profileEditProvider` changes directly via `ref.listen` (line 378-382)
- Invalidating the provider causes a full rebuild just to propagate a radius change

### Files to Modify
- `lib/providers/profile_provider.dart` (lines 3874-3875)

### Fix
Remove the `ref.invalidate(isVisibleProvider)` line from `updateRadius()`. The visibility provider already listens to `profileEditProvider` changes and reads GPS settings via `_getGpsInterval()` and `_isSmartThrottlingEnabled()` methods.

```dart
// DELETE this line from updateRadius():
// ref.invalidate(isVisibleProvider);
```

### Verification
Run the app and test changing the match radius in Matching Settings. Verify no errors appear in logs and the change persists correctly.

---

## Issue 2: Main Thread Blocking (Skipped 299 Frames)

### Problem Analysis
The bootstrap sequence in `_bootstrapInitialize()` (main.dart lines 2365-2965) performs these blocking operations:

1. **VoiceGuidanceService.loadEnabledFromPrefs()** (line 323) - called synchronously but as `unawaited()`, not blocking
2. **Hive.initFlutter()** (lines 2428-2445) - synchronous platform channel calls
3. **DotEnv.load()** (line 2449) - async but awaited before Supabase
4. **Supabase.initialize()** (lines 2503-2526) - heavy initialization with session recovery
5. **LocalDbService.instance** (lines 2558-2572) - Hive box opens, called as `unawaited()`
6. **OfflineMutationQueue.instance.initialize()** (lines 2575-2586) - called as `unawaited()`
7. **ChatKeyProvider initialization** (line 2935) - deferred via `_runPostFrameChatKeyInit`
8. **Map tile warming** (lines 3350-3360) - deferred 6 seconds

Most operations are already deferred or run in parallel. The main remaining blocker is **Supabase session recovery** during `Supabase.initialize()` which runs synchronously and can take 1-5 seconds.

### Files to Modify
- `lib/main.dart` (bootstrap sequence)

### Fix
The current implementation already has good deferral. The remaining optimizations:

1. **Move Supabase session validation off the critical path** - already partially done with the timeout
2. **Defer VoiceGuidanceService.init() completely** - it's already `unawaited()` but could be moved post-frame

The main issue is that `await supabaseInitFuture` blocks the entire bootstrap. This is necessary for auth state, but the JWT validation loop (lines 2640-2760) can be made non-blocking:

Move the JWT validation AFTER the first frame renders:

```dart
// In _bootstrapInitialize(), after line 2760 (after session recovery):
// Instead of blocking on getUser validation, defer it:
if (recoveredSession != null && offlineCacheManager.isSupabaseAvailable) {
  unawaited(_validateSessionPostFrame(recoveredSession));
}
```

Create a new function `_validateSessionPostFrame()` that runs the JWT validation logic after the app is visible.

### Verification
Run `flutter run --profile` and observe the frame timing in DevTools. Target: < 100 frames skipped during cold start.

---

## Issue 3: Missing Native Libraries (libmagtsync.so, libmbrainSDK)

### Problem Analysis
The search for `.so` files and `jniLibs` revealed:
- No `jniLibs` directory exists under `android/app/src/main/`
- The error messages reference libraries that don't exist in the project

These libraries appear to be from a third-party SDK ("MEOW" plugin system) that was either:
1. Never fully integrated
2. Removed but the loading code remains
3. Intended to be optional but missing graceful fallback

The grep for `MEOW` found only domain names in a blocklist (e.g., `salmeow.tk`, `sexymeowers.site`), not actual plugin code.

### Files to Modify
This issue cannot be fixed without knowing the source of these libraries. The error likely comes from:
- A native plugin in `pubspec.yaml` that's misconfigured
- Android native code in `android/app/src/main/kotlin/` or `java/`

### Fix
1. **Audit pubspec.yaml** for native plugins that might load these libraries
2. **Check AndroidManifest.xml** for `<meta-data>` or service declarations
3. **Add graceful fallback** in the native Android code if the plugin is optional

Since I cannot find the loading code, the recommended fix is:
- If the feature is required: Add the missing `.so` files to `android/app/src/main/jniLibs/{arch}/`
- If the feature is optional: Wrap the loading in try-catch with logging

### Verification
Run `adb logcat | grep -E "libmagtsync|libmbrainSDK"` to capture the exact error and traceback, then locate the source file.

---

## Issue 4: Excessive ProfileSyncService Calls

### Problem Analysis
`ProfileSyncService.syncProfile` is called from 15+ locations:

1. **users-table-realtime** (profile_provider.dart:2460) - every Supabase realtime event
2. **app-bootstrap-startup** (main.dart:3312-3313) - 4 second delay
3. **web-tab-visible** (main.dart:4011)
4. **home-pull-to-refresh** (home_screen.dart:901)
5. **settings-screen-open** (settings_screen.dart:72)
6. **profile-check-startup** (profile_check_screen.dart:433)
7. **match-profile-init-current-user** (match_profile_screen.dart:161)
8. **match-profile-init-other-user** (match_profile_screen.dart:169)
9. **match-profile-current-user-loading** (match_profile_screen.dart:1524, 1707)
10. **match-profile-other-user-loading** (match_profile_screen.dart:1714)
11. **profile-screen-return-from-wizard** (profile_screen.dart:902)
12. **profile-screen-retry-empty** (profile_screen.dart:932)
13. **profile-screen-pull-to-refresh** (profile_screen.dart:945)
14. **profile-screen-retry-error** (profile_screen.dart:2413)
15. **match-box-mounted** (match_box.dart:363)
16. **profile-outbox-sync** (outbox_sync_service.dart:480, 492)
17. **admin-review-change** (profile_provider.dart:2244)
18. **manual-review-request** (verification_screen.dart:514)
19. **verification-screen-refresh** (verification_screen.dart:1047)

The existing deduplication in `syncProfile()` (lines 1506-1512) only prevents concurrent in-flight requests:
```dart
final existing = _inFlight[userId];
if (existing != null) return existing;
```

This doesn't prevent rapid sequential calls (e.g., bootstrap + realtime + settings-open within seconds).

### Files to Modify
- `lib/providers/profile_provider.dart` (ProfileSyncService class, around line 1500)

### Fix
Add a debounce mechanism that suppresses redundant syncs within a time window:

```dart
class ProfileSyncService extends _$ProfileSyncService {
  // ... existing code ...
  
  DateTime? _lastSuccessfulSyncAt;
  static const _debounceWindow = Duration(seconds: 5);
  
  Future<ProfileSyncResult> syncProfile(String userId, {String source = ''}) {
    final existing = _inFlight[userId];
    if (existing != null) return existing;
    
    // Debounce: skip if a sync succeeded within the last 5 seconds
    final now = DateTime.now();
    if (_lastSuccessfulSyncAt != null && 
        now.difference(_lastSuccessfulSyncAt!) < _debounceWindow &&
        source != 'manual-review-request' && // Allow explicit user actions
        source != 'admin-review-change') {
      debugPrint('ProfileSyncService.syncProfile SKIP debounced source=$source');
      return Future.value(ProfileSyncResult(status: ProfileSyncStatus.skipped));
    }
    
    final future = _syncProfileInternal(userId, source: source);
    _inFlight[userId] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlight[userId], future)) {
          _inFlight.remove(userId);
        }
        // Update last successful sync time
        if (future.status == ProfileSyncStatus.success) {
          _lastSuccessfulSyncAt = DateTime.now();
        }
      }),
    );
    return future;
  }
}
```

Additionally, remove redundant sync calls:
- **settings-screen-open** (settings_screen.dart:72) - remove or reduce to only on first open
- **match-profile-init-current-user** - only sync if cache is stale (>5 minutes old)

### Verification
Add logging to count sync calls per session. Target: < 5 syncs in the first 30 seconds of app start.

---

## Issue 5: Zero-Width Viewport / FlutterRenderer

### Problem Analysis
The search for `FlutterRenderer` and `zero-width viewport` found no results in the Dart code. This error originates from the Flutter engine's native rendering layer, typically occurring when:

1. The Activity is started before the window is measured
2. The FlutterFragment/FlutterView is added to a container with zero dimensions
3. The surface is created before layout completes

The relevant native code would be in:
- `android/app/src/main/kotlin/.../MainActivity.kt`
- AndroidManifest.xml theme configuration

### Files to Modify
- `android/app/src/main/kotlin/.../MainActivity.kt` (likely location)
- `android/app/src/main/res/values/styles.xml` (theme configuration)

### Fix
Add a post-layout callback to defer FlutterEngine start until the view has non-zero dimensions:

In `MainActivity.kt`:
```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
  // Ensure the window has dimensions before Flutter attaches
  window.decorView.post {
    // Flutter engine will attach after this callback
  }
  super.onCreate(savedInstanceState)
}
```

Or in the theme, ensure the initial window size is valid:
```xml
<style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
  <item name="android:windowBackground">@drawable/launch_background</item>
  <item name="android:windowFullscreen">false</item>
</style>
```

### Verification
Run `adb logcat | grep "FlutterRenderer"` and verify no zero-width viewport errors appear during cold start.

---

## Summary of Changes

| Issue | File | Lines | Change |
|-------|------|-------|--------|
| 1 | `lib/providers/profile_provider.dart` | 3874-3875 | Remove `ref.invalidate(isVisibleProvider)` |
| 2 | `lib/main.dart` | 2640-2760 | Defer JWT validation post-frame |
| 3 | Native code | TBD | Add missing .so files or graceful fallback |
| 4 | `lib/providers/profile_provider.dart` | 1506-1520 | Add debounce mechanism |
| 5 | `android/.../MainActivity.kt` | onCreate | Postpone engine start until view measured |

---

## Verification Commands

```bash
# Build and run the app
flutter run --profile

# Check for frame jank
flutter screenshot --type=skia

# Monitor sync calls
adb logcat | grep "syncProfile"

# Check for native library errors
adb logcat | grep -E "libmagtsync|libmbrainSDK|FlutterRenderer"
```
