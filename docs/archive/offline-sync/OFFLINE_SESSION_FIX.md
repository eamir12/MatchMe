# Offline Session Persistence Fix

## Problem
When the device goes offline after a user logs in and the app is closed:
1. User reopens the app while still offline
2. App takes a long time to load (15+ seconds)
3. App shows login screen instead of using the cached session
4. User cannot access the app until connection is restored

## Root Cause
Two timing issues were causing the delay:

1. **Supabase Initialization Timeout**: The bootstrap was waiting up to 15 seconds for Supabase to initialize before showing any UI
2. **Auth Stream Delay**: The `authStateProvider` was waiting indefinitely for the auth stream to emit an event, which never happens when offline

## Solution
Implemented a two-part fix:

### Part 1: Reduce Supabase Initialization Timeout (lib/main.dart)
- Changed timeout from 15 seconds to 5 seconds
- When offline, Supabase init fails faster, allowing the app to proceed
- The bootstrap gracefully handles the timeout and sets offline mode

### Part 2: Add Auth Stream Fallback (lib/providers/auth_provider.dart)
- Added a 5-second timeout to the `authStateProvider`
- If the auth stream doesn't emit within 5 seconds, emit a fallback event
- The fallback uses the cached session from `auth.currentSession`
- This unblocks the UI from the loading state

## Changes Made

### File 1: `lib/main.dart` (lines 1430-1445)
```dart
// Reduced timeout from 15 to 5 seconds
const supabaseInitTimeout = Duration(seconds: 5);

final supabaseInitFuture = Supabase.initialize(
  url: supabaseUrl,
  anonKey: supabaseAnonKey,
).timeout(
  supabaseInitTimeout,
  onTimeout: () {
    debugPrint('⚠️ [BOOTSTRAP] Supabase initialization timed out after ${supabaseInitTimeout.inSeconds}s - likely offline, continuing with cached session');
    throw TimeoutException('Supabase initialization timeout', supabaseInitTimeout);
  },
);
```

### File 2: `lib/providers/auth_provider.dart` (lines 28-180)

Added timeout tracking and fallback mechanism:
```dart
bool initialEventEmitted = false;
Timer? initialEventTimeout;

void emitInitialEvent() {
  if (initialEventEmitted || disposed) return;
  initialEventEmitted = true;
  initialEventTimeout?.cancel();
  
  // Emit the current session state (cached locally)
  final currentSession = auth.currentSession;
  final currentUser = auth.currentUser;
  
  debugPrint('🔄 [AUTH] Emitting initial auth state from cache (offline fallback)');
  
  controller.add(AuthState(
    AuthChangeEvent.initialSession,
    currentSession,
  ));
}

// Set 5-second timeout for stream emission
initialEventTimeout = Timer(const Duration(seconds: 5), emitInitialEvent);
```

## How It Works

**Online scenario (unchanged):**
- Supabase initializes quickly → stream emits immediately → normal flow continues
- Timeouts are cancelled and never fire

**Offline scenario (new behavior):**
1. Supabase init times out after 5 seconds (instead of 15)
2. Bootstrap sets offline mode and continues
3. Auth stream doesn't emit (no network)
4. After 5 seconds, auth provider timeout fires
5. Fallback emits cached session
6. UI shows user profile with offline data
7. When connection restored, stream can emit updates

## Benefits
- ✅ App loads in ~5 seconds when offline (instead of 15+)
- ✅ User sees their profile immediately when offline
- ✅ No more long loading times or unexpected login screens
- ✅ Seamless transition when connection is restored
- ✅ Backward compatible - doesn't affect online behavior

## Testing
To verify the fix works:
1. Log in to the app while online
2. Close the app
3. Turn off device network/WiFi
4. Reopen the app
5. App should show the user's profile within ~5 seconds (not login screen)
6. Turn network back on
7. App should sync and update normally
