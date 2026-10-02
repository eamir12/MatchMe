# MatchMe Session Persistence & Startup Fixes

## Overview

Your app now implements a **permissive session persistence policy** with robust recovery mechanisms. Users will stay logged in indefinitely unless they:
1. Explicitly click "Log Out" in the UI, OR
2. The configured `forced_sign_out_days` limit is reached, OR  
3. They delete their account

All startup issues have been fixed to prevent unintended logouts and ensure all data is displayed.

---

## Why the Issues Happened (Root Causes)

### 1. Token Refresh Race Condition

**What went wrong:**
- Supabase uses single-use rotating refresh tokens (security feature)
- When the native background service (Android/iOS) and Flutter app both tried to refresh concurrently, only one would succeed
- The other would get `refresh_token_already_used`, and Supabase would revoke the **entire session family** server-side
- The SDK would emit a `signedOut` event, clearing the in-memory session
- **Without recovery logic**, the app would show the login screen (user unintentionally logged out)

**Root cause:**
- Architectural issue: No serialization between native and Dart refresh attempts
- No fallback recovery logic when one side failed
- Session state was held only in memory, not persisted

**Fix applied:**
- `SessionService.safeRefreshSession()` now:
  - Uses a mutex (`_refreshCompleter`) to serialize concurrent refresh calls
  - Retries with native `flutter.refresh_token` if already_used occurs
  - Uses exponential backoff (50ms × 2^attempts, max 3 attempts)
  - Marks auth permanently failed only after exhausting retries

### 2. Background Service Lifecycle Loop

**What went wrong:**
- During bootstrap, providers were being initialized in rapid succession
- Each provider rebuild triggered `updateAppForeground()` and `updateVisibility()` calls
- These sent intents to the native service repeatedly
- Native service would rapidly: onCreate → onStartCommand(STOP) → onDestroy → onCreate (loop)
- This wasted resources and could interfere with location sharing

**Root cause:**
- No debouncing on rapid state changes
- Each provider initialization was treated as a separate event
- Native service lacked batching logic

**Fix applied:**
- Added 500ms debouncing to `updateAppForeground()` and `updateVisibility()`
- Rapid successive changes are collapsed into a single update
- Debounces are canceled in `stop()` to clean up pending updates

### 3. Typing Status Rate Limiting (429 Errors)

**What went wrong:**
- Typing status was polled every 2 seconds from all open chats with no backoff
- If 10 chats were open: 10 requests per 2 seconds = 60 requests/chat/minute
- When errors occurred (network timeout, auth issues), polling continued at the same rate
- This created a burst of 429 rate limit errors

**Root cause:**
- No exponential backoff on poll failures
- No request coalescing or throttling
- Multiple chats polling independently without coordination

**Fix applied:**
- Exponential backoff: 2s base × 1.5^failures, capped at 30s
- Failure count resets on success
- 500ms throttle on typing status database updates
- Rapid keystrokes are batched into single write

### 4. Translation Sync Cascade

**What went wrong:**
- At startup, translation sync would loop through all chats sequentially
- If 20+ chats were enabled for translation, each one would:
  - Query local DB for last message
  - Call translation service to detect language
  - Call translate-proxy edge function
  - Fetch translated result from Supabase
- All requests were made back-to-back with no delay
- Supabase rate limiting would kick in, returning 429 errors
- These errors cascaded, preventing completion of other startup tasks

**Root cause:**
- Sequential processing without batching
- No rate limiting strategy
- No delays between requests to different chats

**Fix applied:**
- Batch processing: 3 chats per batch
- 500ms delay between batches
- Parallel processing within each batch for speed
- Failed chats don't block others (`eagerError: false`)
- Only translates last message per chat (lazy mode)

### 5. Incomplete Data Load After Token Refresh

**What went wrong:**
- During bootstrap, when token refresh succeeded, providers were already initialized
- They had cached the old (invalid) token
- Providers wouldn't automatically retry with the new token
- Location share, recent chats, and match notifications would fail silently
- User would see the home screen but with incomplete/stale data

**Root cause:**
- Providers weren't invalidated after token refresh
- No mechanism to signal providers "token changed, retry now"
- Data sync only happened once at provider initialization

**Fix applied:**
- After successful token refresh, immediately invalidate:
  - `recentChatsProvider(userId)`
  - `recentMatchesProvider(userId)`  
  - `matchNotificationProvider`
- Invalidation forces providers to rebuild with fresh token
- Same recovery happens after native token refresh (race recovery)
- Uses `Future.microtask()` for safe invalidation without blocking

---

## Session Persistence: How It Works Now

### Guarantee: User Stays Logged In

```
User is logged in IF:
  ✓ Session snapshot exists in SharedPreferences
  ✓ AND user has NOT explicitly clicked "Log Out"
  ✓ AND forced_sign_out_days deadline has NOT been exceeded
```

### Guarantee: Only Explicit Actions Log Out

The only ways for a user to be logged out:

1. **User clicks "Log Out"** (Main navigation, profile wizard, or settings)
   - Sets `SessionService._explicitUserSignOut = true`
   - Revokes all sessions server-side
   - Clears session snapshot from disk
   - Clears all in-memory caches

2. **forced_sign_out_days limit is reached**
   - Checked on each app restart via `checkForcedSignOut()`
   - Compares current time to `session_created_at` + configured duration
   - If exceeded: marks explicit, signs out, clears snapshot
   - Duration of 0 (default) = disabled, no forced logout

3. **Account is deleted**
   - User deletes account via settings
   - Marks explicit and signs out
   - Clears all local data

### Guarantee: Non-Explicit Logouts Are Recovered

If Supabase SDK fires a `signedOut` event (e.g., from background token refresh failure):

```dart
if (SessionService.consumeExplicitUserSignOutFlag()) {
  // User explicitly logged out — only clear the snapshot
  await SessionService.clearPersistedSupabaseSessionSnapshot();
} else {
  // Non-explicit (e.g., refresh_token_already_used race)
  // RECOVER the persisted session and stay logged in
  await SessionService.recoverPersistedSupabaseSession();
  
  // If that fails (network/cooldown), restore offline without network IO
  await SessionService.restorePersistedSessionOfflineOnly();
}
```

### Flow on App Restart

1. **Parallel initialization** (0-500ms):
   - Supabase.initialize() starts connecting
   - LocalDbService opens SQLite cache
   - SessionService.recoverPersistedSupabaseSession() tries to restore session from disk

2. **Auth stream initializes** (100-1000ms):
   - SDK emits `initialSession` event
   - Auth provider checks: is session null? If yes, try recovery again
   - Sets 1-second timeout in case SDK stalls

3. **Offline fallback** (1000ms+):
   - If auth stream hasn't emitted after 1 second, fallback triggers
   - Calls `emitInitialEvent()` which tries offline recovery
   - Emits cached session to unblock UI from loading state

4. **Forced sign-out check** (on initialSession):
   - Checks if `forced_sign_out_days` is exceeded
   - If yes: signs out explicitly
   - If no: continues with session

5. **Data sync** (5-10s):
   - GlobalSyncManager waits for backend health check
   - Calls `syncChatsNow(userId)` to refresh chats from server
   - Realtime subscriptions re-establish

**Result:** User sees their data immediately from cache, updates populate asynchronously as network completes.

---

## Data Availability Guarantee

Once logged in, users will see:

| Data | When | Source | Offline? |
|------|------|--------|----------|
| **Chats** | Immediate (0ms) | LocalDbService cache | ✓ Yes |
| **Messages** | Immediate (0ms) | LocalDbService cache | ✓ Yes |
| **Recent Matches** | Immediate (0ms) | LocalDbService cache | ✓ Yes |
| **Profile** | Immediate (0ms) | LocalDbService cache | ✓ Yes |
| **Recent Chats** | 5-10s | Server sync | Online only |
| **Location Share Signals** | Realtime | Supabase realtime | Online only |
| **Online Count** | 5-10s initial, then 30s periodic | Server fetch | Online only |
| **Match Notifications** | Realtime | Supabase realtime | Online only |

**Key point:** Cached data shows immediately while network syncs happen in background. No loading screen blocking.

---

## Configuration: Forced Sign Out

Set in the `app_config` table:

```sql
INSERT INTO app_config (key, value) VALUES 
('auth.forced_sign_out_days', '0');  -- Disabled (default)
-- OR
('auth.forced_sign_out_days', '30'); -- Auto-logout after 30 days
-- OR
('auth.forced_sign_out_days', '7');  -- Auto-logout after 7 days
```

When user logs in, `session_created_at` is set to current timestamp in SharedPreferences. On each app restart, if the configured duration has passed, user is automatically signed out.

---

## Testing: Verify Session Persistence

### Test 1: Log In → Close App → Reopen
**Expected:** User is still logged in, sees cached data immediately

### Test 2: Log In → Enable Airplane Mode → Reopen App
**Expected:** User is still logged in, sees cached data, no errors shown

### Test 3: Log In → Wait for forced_sign_out_days → Reopen App
**Expected:** User is automatically signed out, sees login screen

### Test 4: Log In → Click "Log Out" → Reopen App
**Expected:** User sees login screen (session cleared)

### Test 5: Log In → Background Service Refresh Fails
**Expected:** User stays logged in (no unintended logout)

### Test 6: Open 10+ chats with typing enabled
**Expected:** No 429 rate limit errors, smooth performance

---

## Summary: Why Your App Now Works Correctly

✅ **Refresh token races are handled gracefully** → No unintended logouts
✅ **Background service doesn't loop** → Better resource usage, location sharing stable
✅ **Typing polling has backoff** → No 429 rate limit cascades
✅ **Translation sync is batched** → No startup hang
✅ **Providers recover after token refresh** → Complete data displayed
✅ **Session persists across app restarts** → Users stay logged in
✅ **Forced sign-out is configurable** → Control when users must re-login
✅ **Offline-first architecture** → Data displays immediately from cache

Your users will now have a seamless experience: they stay logged in, all data is available, and the app gracefully handles network issues.
