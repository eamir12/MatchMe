// OFFLINE_FIRST_IMPLEMENTATION_GUIDE.md
# MatchMe Offline-First Implementation Guide

## ✅ What Has Been Completed

### 1. **Core Infrastructure**
- ✅ `OfflineCacheManager` - Central caching coordinator
- ✅ `LocalDbService` extensions - Cache data loading/saving methods
- ✅ `OfflineIndicator` widget - Visual indicator for offline state
- ✅ `Bootstrap timeout` - 15-second limit on Supabase initialization
- ✅ `Global sync manager` integration - Reports Supabase availability

### 2. **Data Caching**
The following data is automatically cached to local storage (Hive):

```
✅ Recent Matches
✅ Recent Chats  
✅ Chat Messages
✅ User Profile
✅ User Events
✅ User Settings & Preferences
✅ Last-known Online Count
```

### 3. **Offline Detection**
```dart
// Check if Supabase is currently unavailable
bool isOffline = offlineCacheManager.shouldUseCachedData();
```

### 4. **User Experience Improvements**
- App loads instantly with cached data instead of showing blank screen
- No timeouts or hanging when Supabase is down
- Clear visual indicator ("MatchMe is offline - showing cached data")
- Users can still view all previously cached data

## 📋 Integration Checklist

### Step 1: Import the New Services
Add these imports to screens showing user data:

```dart
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/offline_provider_fallback.dart';
import 'package:matchme/widgets/offline_indicator.dart';
```

### Step 2: Add Offline Indicator to Main Screens

#### Home Screen (navHome)
```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  return Column(
    children: [
      if (!offlineCacheManager.isSupabaseAvailable)
        const OfflineIndicator(),
      // Rest of your home screen
      Expanded(child: _buildHomeContent(ref)),
    ],
  );
}
```

#### Chat Screen (chatScreen)
```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  return Column(
    children: [
      if (!offlineCacheManager.isSupabaseAvailable)
        const OfflineIndicator(height: 36),
      // Chat content
      Expanded(child: _buildChatContent(matchId)),
    ],
  );
}
```

#### Match/Profile Screens
```dart
@override
Widget build(BuildContext context) {
  return Scaffold(
    body: Column(
      children: [
        if (!offlineCacheManager.isSupabaseAvailable)
          const OfflineIndicator(),
        Expanded(child: _buildProfileContent()),
      ],
    ),
  );
}
```

### Step 3: Handle Offline-Disabled Features

When users try actions that won't work offline:

```dart
// In your edit profile button handler
Future<void> editProfile() async {
  if (offlineCacheManager.shouldUseCachedData()) {
    showOfflineFeatureDialog(
      context,
      title: 'Cannot Modify Profile',
      message: 'Profile editing requires an internet connection.',
    );
    return;
  }
  
  // Proceed with profile edit
}

// In your send message handler
Future<void> sendMessage(String text) async {
  if (offlineCacheManager.shouldUseCachedData()) {
    showOfflineFeatureDialog(
      context,
      title: 'Cannot Send Message',
      message: 'Messaging requires an internet connection.',
    );
    return;
  }
  
  // Proceed with sending
}

// In your create match handler
Future<void> createNewMatch() async {
  if (offlineCacheManager.shouldUseCachedData()) {
    showOfflineFeatureDialog(
      context,
      title: 'Cannot Create Match',
      message: 'Creating matches requires an internet connection.',
    );
    return;
  }
  
  // Proceed with match creation
}
```

### Step 4: Show Data Source in UI (Optional)

Display a subtle indicator showing data is from cache:

```dart
/// In chat bubble or message list
Widget buildMessageWithSourceIndicator() {
  final isFromCache = offlineCacheManager.shouldUseCachedData();
  
  return Column(
    children: [
      ChatBubble(message),
      if (isFromCache)
        Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '📦 Cached',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
    ],
  );
}
```

### Step 5: Add Manual Cache Debug Information

For troubleshooting, add a debug screen:

```dart
// In settings or debug menu
Future<void> showCacheDebugInfo() async {
  final stats = await offlineCacheManager.getCacheStats();
  
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Cache Statistics'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Supabase: ${stats.isSupabaseAvailable ? "✅ Available" : "❌ Unavailable"}'),
            Text('Cached Matches: ${stats.cachedMatches}'),
            Text('Cached Chats: ${stats.cachedChats}'),
            Text('Cached Messages: ${stats.cachedMessages}'),
            Text('Last Check: ${stats.lastCheckTime}'),
            SizedBox(height: 16),
            Text(stats.debugSummary),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('OK'),
        ),
      ],
    ),
  );
}
```

## Testing Offline Mode

### Manual Testing
1. **Desktop/Emulator**:
   - Disconnect network while running
   - App should instantly show cached data
   - Offline indicator should appear

2. **Mobile Device**:
   - Enable Airplane Mode
   - App should show cached data
   - Try to perform actions (send message, edit profile)
   - See appropriate offline dialogs

3. **Network Simulation** (in code):
   ```dart
   // Simulate offline mode for testing
   offlineCacheManager.setSupabaseAvailability(false);
   
   // UI should immediately show offline state
   // Cached data should appear
   
   // Simulate coming back online
   offlineCacheManager.setSupabaseAvailability(true);
   ```

### Automated Testing
Create a widget test that verifies offline behavior:

```dart
testWidgets('Shows offline indicator when Supabase unavailable', (tester) async {
  // Set offline
  offlineCacheManager.setSupabaseAvailability(false);
  
  await tester.pumpWidget(MyApp());
  
  // Verify offline indicator is shown
  expect(find.byType(OfflineIndicator), findsOneWidget);
  expect(find.text('MatchMe is offline'), findsOneWidget);
});
```

## Performance Benefits

### Before Implementation
- ⏱️ **15-30 seconds** blank white screen when Supabase unavailable
- ❌ No user feedback about what's happening
- 😟 User might think app crashed

### After Implementation
- ⏱️ **Instant** display of cached data
- ✅ Clear "offline" indication
- 😊 Users can still browse their data
- 🚀 Much better user experience

## Monitoring & Debugging

### Logs to Watch
When offline mode is active, you'll see logs like:
```
📦 [OFFLINE] Supabase availability changed: true -> false
📦 [OFFLINE] Cached user data for user-id
✅ [CACHE] Saved 5 matches to offline cache
⚠️ [SYNC] Supabase unavailable - using offline mode with cached data
```

### Debug Commands
```dart
// Check current status
debugPrint('Offline: ${offlineCacheManager.shouldUseCachedData()}');

// Get cache stats
final stats = await offlineCacheManager.getCacheStats();
debugPrint(stats.debugSummary);

// Debug specific data
final cachedMatches = await offlineCacheManager.getCachedRecentMatches();
print('Cached matches: ${cachedMatches.length}');
```

## Important Notes

⚠️ **Data Limitations When Offline**:
- ✅ View cached data (matches, chats, messages)
- ✅ Read user profiles
- ✅ Browse events
- ❌ Send new messages
- ❌ Create/delete matches
- ❌ Update profile
- ❌ Change visibility
- ❌ Create events

⚠️ **Cache Behavior**:
- Cache is persistent (survives app restart)
- Cache is cleared on logout
- Cache is automatically updated on every successful sync
- No manual cache clearing needed for users

## Future Enhancements

Potential improvements for future versions:
- [ ] Message queue for offline messaging (send when online)
- [ ] Profile edit draft saving
- [ ] Partial sync detection (show which data is stale)
- [ ] Smarter cache expiration (invalidate old matches)
- [ ] Offline-first UI animations/transitions
- [ ] Detailed offline analytics

## Troubleshooting

### Issue: Offline indicator always shows
**Solution**: Check if `GlobalSyncManager` is running. Verify Supabase connectivity.

### Issue: Cached data isn't appearing
**Solution**: Check Hive boxes are properly initialized in `LocalDbService.init()`.

### Issue: Old cached data showing
**Solution**: This is expected behavior - data doesn't expire. Restart app or manually refresh.

### Issue: Users can't exit offline mode
**Solution**: This happens if device is actually offline. Reconnect to network.

## Questions & Support

For issues or questions:
1. Check the logs (debug output)
2. Review cache debug info dialog
3. Test with manual offline simulation
4. Check if Supabase is actually accessible from network
