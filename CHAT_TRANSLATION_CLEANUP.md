# Chat Translation Settings Cleanup

## Problem
When you delete chats and messages from the database and start fresh, the app client was remembering the old chat translation settings from local storage. This caused the new chats to have mismatched settings:
- **Local Storage**: `translation_enabled = true` (from old chat)
- **Database**: `translation_enabled = false` (new default)

The trigger was exiting early because the database showed translation disabled, so messages were never translated.

## Solution
Updated `LocalDbService` to properly clean up translation settings when chats are deleted:

### Changes Made:

1. **`deleteChat()` method** - Now calls helper methods to clean up:
   - `clearChatMessages()` - Removes all messages for the chat
   - `clearChatTranslationSettings()` - Removes translation settings from local cache

2. **New helper methods added**:
   - `clearChatTranslationSettings(userId, matchId)` - Removes a specific chat's translation settings
   - `clearAllChats(userId)` - Completely clears all chats for a user
   - `clearChatMessages(matchId)` - Removes cached messages for a chat
   - `syncChatTranslationSettings()` - Syncs local cache with server state

3. **Existing `clearDatabase()` method** - Already clears the chats box completely

### How It Works:

**When you delete a chat:**
```dart
await localDb.deleteChat(matchId, userId: userId);
// This now:
// 1. Removes chat from recent_chats list
// 2. Clears all cached messages for that chat
// 3. Clears translation settings from local storage
```

**When you clear all app data:**
```dart
await localDb.clearDatabase();
// This already cleared the chatsBox, which contains all translation settings
```

**When chats sync from server after clearing:**
```dart
await localDb.syncChatTranslationSettings(userId, matchId, false, null);
// This ensures local cache matches what the server sends
// (translation_enabled = false, translation_language = null)
```

## Benefits

✅ **No stale settings** - Deleting chats now properly clears local storage  
✅ **Fresh starts** - New chats start with correct default settings (translation disabled)  
✅ **Consistent state** - Local cache stays in sync with database  
✅ **No more duplicates** - Trigger correctly sees `translation_enabled = false` for fresh chats  

## Testing

To verify this works:
1. **Clear app data** - Settings → Clear All Local Data
2. **Create new chat** - Translation should be disabled by default
3. **Enable translation** - In chat settings, turn on translation and select language
4. **Send message** - Trigger now works because `translation_enabled = true` in database
5. **Delete chat** - Translation settings are cleared from local storage
6. **Create new chat** - Starts fresh with translation disabled again

## Files Modified

- `lib/services/local_db_service.dart` - Added cleanup methods and updated deleteChat()
