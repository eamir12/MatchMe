# Offline Mutation Buffering Guide

## Overview

Your MatchMe app now has a **complete offline mutation buffering system**. When users are offline or Supabase is unavailable, all mutations (messages, profile updates, visibility changes, etc.) are automatically queued and synced to Supabase as soon as the connection is restored.

This provides a **seamless offline experience** where users don't lose their changes - they're just synced later.

## ✨ Features

- ✅ **Automatic Queuing**: All mutations automatically queue when offline
- ✅ **Transparent**: Users can send messages and make changes without knowing about the queue
- ✅ **Auto-Sync**: Syncs automatically every 60 seconds when backend available
- ✅ **Retry Logic**: Failed mutations retry up to 5 times
- ✅ **Pending Indicator**: Shows users when changes are syncing
- ✅ **Optimistic Updates**: Messages appear immediately in UI, synced in background
- ✅ **Conflict Resolution**: Last-write-wins strategy for simultaneous updates

## 🏗️ Architecture

### Components

1. **OfflineMutationQueue** (`lib/services/offline_mutation_queue.dart`)
   - Stores pending mutations in Hive
   - Handles syncing to Supabase
   - Manages retries and error tracking

2. **MutationWrapper** (`lib/services/mutation_wrapper.dart`)
   - Simple API for executing mutations
   - Handles offline detection
   - Provides pre-built mutation helpers

3. **PendingMutationsIndicator** (`lib/widgets/pending_mutations_indicator.dart`)
   - Shows pending changes count
   - Displays mutation details
   - Visual feedback to users

4. **Global Sync Manager** (updated)
   - Syncs pending mutations every 60 seconds
   - Integrated with connection health checks

## 🔄 How It Works

### When Online
```
User sends message
  ↓
MutationWrapper.sendMessage() called
  ↓
Message inserted to Supabase ✅
  ↓
Local DB updated with server response
```

### When Offline
```
User sends message
  ↓
MutationWrapper.sendMessage() called
  ↓
Offline detection triggered
  ↓
Mutation queued in Hive database
  ↓
Message appears optimistically in UI with "syncing" badge
  ↓
When connection restored → Auto-sync every 60 seconds
  ↓
Server processes mutation ✅
  ↓
"Syncing" badge removed
```

## 📝 Usage Examples

### Sending Messages (Already Integrated)

```dart
// In chat_screen.dart or chat_provider.dart
// Simply use the existing sendMessage - it now queues offline!

await chatProvider.sendMessage(
  matchId: matchId,
  text: messageText,
  replyToMessageId: replyMessageId,
);

// User experience:
// - Online: Message sent immediately ✅
// - Offline: Message queued, appears in UI with badge 📤
//           Auto-syncs when connection restored
```

### Direct Mutation Wrapper Usage

```dart
import 'package:matchme/services/mutation_wrapper.dart';

// Queue a message
await MutationWrapper.sendMessage(
  matchId: matchId,
  senderId: userId,
  text: 'Hello!',
  replyToMessageId: null,
);

// Update visibility status
await MutationWrapper.updateVisibilityStatus(
  userId: currentUserId,
  status: 'visible', // or 'invisible'
);

// Update profile
await MutationWrapper.updateProfile(
  userId: currentUserId,
  updates: {
    'bio': 'New bio text',
    'interests': ['reading', 'hiking'],
  },
);

// React to message
await MutationWrapper.reactToMessage(
  messageId: messageId,
  userId: currentUserId,
  emoji: '❤️',
);

// Delete message
await MutationWrapper.deleteMessage(
  messageId: messageId,
);

// Mark chat as read
await MutationWrapper.markChatAsRead(
  matchId: matchId,
  userId: currentUserId,
);
```

### Custom Mutations

For any other mutations:

```dart
// Queue a custom mutation
await MutationWrapper.executeMutation(
  type: 'update',  // 'insert', 'update', or 'delete'
  table: 'user_preferences',
  payload: {
    'notifications_enabled': false,
    'theme': 'dark',
  },
  where: {'id': userId},
  onlineExecution: (supabase) async {
    await supabase
        .from('user_preferences')
        .update({'notifications_enabled': false, 'theme': 'dark'})
        .eq('id', userId);
  },
);
```

## 📊 Monitoring Mutations

### Get Pending Count

```dart
final count = await offlineCacheManager.getPendingMutationCount();
print('$count changes waiting to sync');
```

### Get Pending Mutations List

```dart
final mutations = await offlineCacheManager.getPendingMutations();
for (final mutation in mutations) {
  print('${mutation.type} on ${mutation.table}: ${mutation.id}');
  print('  Retries: ${mutation.retryCount}');
  if (mutation.errorMessage != null) {
    print('  Error: ${mutation.errorMessage}');
  }
}
```

### Listen to Changes

```dart
offlineCacheManager.pendingMutationsChanged.listen((mutations) {
  print('Pending mutations updated: ${mutations.length}');
  // Update UI here
});
```

### Get Sync Status

```dart
final hasPending = await offlineCacheManager.hasPendingMutations();
if (hasPending) {
  print('Changes waiting to sync');
}
```

## 🎨 UI Integration

### Add Pending Indicator to Screens

```dart
import 'package:matchme/widgets/pending_mutations_indicator.dart';

// In your screen build:
Column(
  children: [
    const OfflineIndicator(),
    const PendingMutationsIndicator(),
    // Rest of your UI
  ],
)
```

### Show Badge on Navigation Items

```dart
import 'package:matchme/widgets/pending_mutations_indicator.dart';

Stack(
  children: [
    Icon(Icons.mail),
    PendingMutationsBadge(
      badgeColor: Colors.red,
      badgeSize: 18,
    ),
  ],
)
```

### Show Details Dialog

```dart
import 'package:matchme/widgets/pending_mutations_indicator.dart';

onTap: () async {
  final count = await offlineCacheManager.getPendingMutationCount();
  if (count > 0 && mounted) {
    showPendingMutationsDialog(context, count: count);
  }
}
```

## 🔍 Debugging

### Logs to Look For

```
// When mutation is queued:
[OfflineMutationQueue] Queued update on chat_messages: abc123...

// When syncing:
🔄 [SYNC] Starting mutation sync...
[OfflineMutationQueue] Starting sync of 3 mutations

// Success:
✅ [SYNC] Synced: update on users

// Failure with retry:
❌ [SYNC] Failed: chat_messages - Permission denied
[OfflineMutationQueue] Cleared failed mutation: abc123... (max retries reached)
```

### Check Hive Box

```dart
// View all pending mutations in Hive
final mutations = await offlineCacheManager.getPendingMutations();
debugPrint('${mutations.length} pending mutations');
```

### Clear Stuck Mutations

```dart
// If mutations are repeatedly failing, clear the queue (CAUTION!)
await OfflineMutationQueue.instance.clearAll();
debugPrint('Cleared all pending mutations');

// Or clear only failed mutations (auto-retries max 5 times):
await OfflineMutationQueue.instance.clearFailedMutations(maxRetries: 3);
```

## 🎯 User-Facing Features

### What Users See When Offline

1. **Banner at Top**: "MatchMe is offline"
2. **Badge on Buttons**: Small orange "syncing" indicator
3. **Pending Changes**: Shows "Syncing 3 changes" in banner
4. **Details**: Tap to see what's waiting to sync

### User Communication

```dart
// Show message to user
showOfflineFeatureDialog(
  context,
  title: 'Message Saved',
  message: 'Your message will be sent when your connection is restored.',
);
```

## ⚙️ Configuration

### Sync Interval

Edit `OFFLINE_FIRST_README.md` to see how to configure sync intervals via AppConfig:

```dart
// Default: 60 seconds
sync.global_interval_seconds = 60

// Max retries for failed mutations
offline.mutation_max_retries = 5
```

## 🧪 Testing

### Simulate Offline Mode

```dart
// In your test or during development
offlineCacheManager.setSupabaseAvailability(false);

// Now all mutations will queue instead of executing
```

### Test Message Sending Offline

1. Enable Airplane Mode
2. Kill the app
3. Send a message (tap send)
4. You should see:
   - ✅ Message appears immediately in UI
   - 📤 "Syncing" badge appears
5. Disable Airplane Mode
6. After 60 seconds (or tap Settings sync):
   - ✅ Badge disappears
   - ✅ Message is confirmed sent

### View Queued Mutations

```dart
// In debug console while offline:
final mutations = await offlineCacheManager.getPendingMutations();
print(mutations); // See what's queued
```

## 📋 Mutation Types Supported

| Mutation Type | Table | Supported |
|---|---|---|
| Send Message | chat_messages | ✅ |
| Update Visibility | users | ✅ |
| Update Profile | users | ✅ |
| React to Message | message_reactions | ✅ |
| Delete Message | chat_messages | ✅ |
| Mark Chat Read | chat_rooms | ✅ |
| Custom | Any table | ✅ |

## ⚠️ Important Notes

1. **Optimistic Updates**: Messages appear in UI immediately, even if not yet synced
2. **Retry Strategy**: Failed mutations retry auto matically up to 5 times over ~5 minutes
3. **Last-Write-Wins**: If same field updated online+offline, last write wins
4. **Server Validation**: Server-side validation still applies after sync
5. **Conflicts**: User is informed if sync fails due to conflicts

## 🐛 Troubleshooting

### Mutations Not Syncing

Check logs:
```
- Is Supabase available? (check OfflineCacheManager.isSupabaseAvailable)
- Are mutations in the queue? (call getPendingMutations())
- Any permission errors? (check errorMessage in mutations)
```

### High Retry Count

Mutation has retried 5+ times = likely a server-side issue:
```dart
// View the error:
final mutations = await offlineCacheManager.getPendingMutations();
mutations.where((m) => m.retryCount > 3).forEach((m) {
  print('${m.table}: ${m.errorMessage}');
});

// Clear if confirmed safe:
await OfflineMutationQueue.instance.clearFailedMutations(maxRetries: 3);
```

### Users Confused About "Syncing" Badge

- Explain that changes are temporarily cached locally
- Assure them changes will sync automatically
- Show them the pending changes count/details

## 🚀 Future Enhancements

Potential improvements:
- Smart conflict resolution UI
- Per-mutation retry strategies
- Mutation history/audit log
- Selective sync (allow user to manually retry)
- Progressive sync hints based on mutation priority

## 📚 Related Files

- [OFFLINE_FIRST_README.md](OFFLINE_FIRST_README.md) - Overall offline strategy
- [lib/services/offline_mutation_queue.dart](lib/services/offline_mutation_queue.dart) - Core queue logic
- [lib/services/mutation_wrapper.dart](lib/services/mutation_wrapper.dart) - Mutation API
- [lib/widgets/pending_mutations_indicator.dart](lib/widgets/pending_mutations_indicator.dart) - UI widgets
- [lib/services/global_sync_manager.dart](lib/services/global_sync_manager.dart) - Sync orchestration

## ✅ Checklist for Integration

- [ ] Verify OfflineMutationQueue initializes (check logs for "OfflineMutationQueue initialized")
- [ ] Test offline message sending (Enable Airplane Mode → Send → Check UI)
- [ ] Add PendingMutationsIndicator to home/chat screens
- [ ] Test online sync (Disable Airplane Mode → Wait 60s → Verify sync)
- [ ] Add badge to navigation items (optional)
- [ ] Document user-facing behavior in Help/FAQ
- [ ] Monitor mutation sync logs in production

---

**Ready to go live!** 🚀 Users can now send messages and make changes offline, with automatic sync when back online.
