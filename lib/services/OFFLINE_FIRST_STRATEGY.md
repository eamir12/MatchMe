// lib/services/offline_first_strategy.md
# OfflineFirst Strategy for MatchMe

## Overview
This document outlines how MatchMe provides a seamless offline experience with comprehensive local caching.

## Architecture

### 1. Core Offline Manager (OfflineCacheManager)
- **File**: `offline_cache_manager.dart`
- **Purpose**: Central manager for offline cache operations
- **Key Methods**:
  - `isSupabaseAvailable`: Track current Supabase status
  - `getCachedUserProfile()`: Retrieve cached user profile
  - `getCachedRecentMatches()`: Get cached matches list
  - `getCachedRecentChats()`: Get cached chats
  - `getCachedChatMessages()`: Get cached messages for a match
  - `getCachedUserEvents()`: Get cached user events

### 2. Local Storage (Hive + LocalDbService)
- **Hive Boxes**: Persistent local storage
- **Key BoxesData Stored**:
  - `userProfileBox`: User profile data
  - `recentMatchesBox`: Recent matches
  - `recentChatsBox`: Recent chats per user
  - `chatMessagesBox`: Messages per match
  - `userEventsBox`: Cached user events
  - `userSettingsBox`: User preferences and last-known counts

### 3. Bootstrap Process Changes
- **Problem**: App showed white loading screen indefinitely when Supabase was unavailable
- **Solution**:
  1. Added 15-second timeout for Supabase initialization
  2. Graceful fallback to offline mode if timeout occurs
  3. App loads with cached data instead of blocking
- **File**: `lib/main.dart` - `_bootstrapInitialize()` function

### 4. Data Caching Strategy

#### When Data is Cached:
1. **After successful Supabase queries**:
   - GlobalSyncManager syncs and caches matches
   - GlobalSyncManager syncs and caches chats
   - Profile syncs cache user data
   - Event provider caches events

2. **On every update**:
   - Messages are cached locally before sending
   - Chat reactions are cached immediately
   - Matches are cached on creation/deletion

3. **User-initiated**:
   - Profile updates cache new profile data
   - Match operations cache updated lists

#### What Data is Available Offline:
✅ **Fully Functional Offline**:
- View cached matches
- Browse chat history
- Read message threads
- View user events
- Access user profile
- See user preferences

❌ **Not Available Offline**:
- Send new messages (queued for later)
- Create new matches
- Update profile
- Change visibility status
- Make any real-time updates

### 5. UI Indicators

#### Offline Indicator Widget (`offline_indicator.dart`):
- Banner at top of screen when Supabase unavailable
- Shows "MatchMe is offline - showing cached data"
- Orange color for high visibility

### 6. Provider Fallback

Providers ask the cache manager directly before fetching:
```dart
if (offlineCacheManager.shouldUseCachedData()) {
  // Serve the cached data instead of calling Supabase
}
```

### 7. Global Sync Manager Integration

The `GlobalSyncManager` now:
1. Automatically caches all synced data
2. Detects when Supabase becomes unavailable
3. Updates `offlineCacheManager` status
4. Allows providers to use cached data

## Implementation Checklist

✅ OfflineCacheManager created
✅ Bootstrap timeout added
✅ LocalDbService extended with cache methods
✅ OfflineIndicator widget created
✅ Offline provider fallback utilities
✅ Global sync manager updates cache status

📋 Next Steps:
- [ ] Providers fully integrate offline fallback
- [ ] UI shows offline indicators in key screens
- [ ] Event provider uses offline fallback
- [ ] Profile provider shows cached data when offline
- [ ] Message sync caches all data properly
- [ ] Test offline scenarios thoroughly

## Testing Offline Mode

### Manual Testing:
1. Enable Airplane Mode on device
2. Or disconnect WiFi/mobile data
3. App should show cached data
4. No crashes or blank screens
5. Offline indicator should be visible

### Automating Offline Status:
```dart
// Debug/test code
offlineCacheManager.setSupabaseAvailability(false); // Simulate offline
offlineCacheManager.setSupabaseAvailability(true);  // Simulate online
```

## Performance Improvements

### Before Offline Support:
- White blank screen for 15+ seconds when Supabase unavailable
- No user feedback
- Unclear what was happening

### After Offline Support:
- Instant display of cached data
- Clear "offline" indication
- Users can still browse their matches and chats
- Non-blocking experience

## Cache Invalidation Strategy

### How cache is kept fresh:
1. **Periodic sync** (60 seconds): Fresh data replaces cache
2. **Real-time subscriptions**: Updates trigger immediate cache refresh
3. **Manual refresh**: User can manually refresh any screen
4. **Background service**: Updates cache during app lifecycle

### Cache expiration:
- Most data cached indefinitely (matches, chats, messages)
- Online count refreshes every sync
- Events checked for staleness (5-minute window)

## Security Considerations

- Cached data stored locally in Hive (encrypted on mobile)
- Chat-translation prefs mirror (secondary cold-start fallback) stores values
  encrypted with the per-user device cache key (`enc1:` prefix); legacy
  plaintext entries are re-encrypted on first authenticated run
  (`migrateLegacyTranslationPrefs`) and removed when no key is available
- Live counters are never served from cache (fresh RPC only)
- Per-user isolation on shared devices: logout / direct account switch wipes
  the signed-out user's chats, matches, messages, profile, minimap snapshots,
  other-user profile caches, profile translations, and chat-translation prefs
- No sensitive credentials cached
- Cache cleared on logout
- Offline data only for already-authenticated users
