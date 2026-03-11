# Comprehensive Local Caching Plan for Supabase Data

## Current State Analysis

### ✅ Already Cached Locally:
- **Chat messages** (per match)
- **Recent chats** (per user)
- **Matches** (recent matches)
- **User profiles** (current user + viewed profiles)
- **User events** (attending events)
- **Translations** (per language)
- **Options hierarchy** (intents/interests)
- **Settings** (user preferences)

### ❌ NOT Cached Locally (Fetched Fresh):
- **Dashboard stats** (online/nearby user counts)
- **Event details** (when viewing event pages)
- **Other user profiles** (when not recently viewed)
- **Search results** (dynamic queries)
- **Real-time subscription data**

## Implementation Plan

### 1. Cache Dashboard Statistics
Add local caching for online/nearby user counts to reduce server load.

```dart
// Add to local_db_service.dart
Future<void> saveDashboardStats(int onlineCount, int nearbyCount) async {
  final box = await _getSettingsBox();
  await box.put('dashboard_stats', {
    'online_count': onlineCount,
    'nearby_count': nearbyCount,
    'last_updated': DateTime.now().toIso8601String(),
  });
}

Future<Map<String, int>?> getDashboardStats() async {
  final box = await _getSettingsBox();
  final data = box.get('dashboard_stats');
  if (data == null) return null;

  final lastUpdated = DateTime.parse(data['last_updated']);
  // Cache for 5 minutes
  if (DateTime.now().difference(lastUpdated) > Duration(minutes: 5)) {
    return null; // Expired
  }

  return {
    'online': data['online_count'] ?? 0,
    'nearby': data['nearby_count'] ?? 0,
  };
}
```

### 2. Cache Event Details
Cache event information when viewing events.

```dart
// Add to local_db_service.dart
Future<void> saveEventDetails(String eventId, Map<String, dynamic> eventData) async {
  final box = await _getEventsBox();
  final key = 'event_$eventId';
  await box.put(key, {
    ...eventData,
    'cached_at': DateTime.now().toIso8601String(),
  });
}

Future<Map<String, dynamic>?> getEventDetails(String eventId) async {
  final box = await _getEventsBox();
  final key = 'event_$eventId';
  return box.get(key);
}
```

### 3. Enhanced Profile Caching
Ensure profiles for other users are cached when viewed.

```dart
// Enhance existing userProfileProvider to cache other users' profiles
Future<void> cacheOtherUserProfile(String userId, Map<String, dynamic> profileData) async {
  final localDb = ref.read(localDbProvider);
  // Save to a separate box for other users' profiles
  await localDb.saveOtherUserProfile(userId, profileData);
}
```

### 4. Cache Search Results
Cache recent search results to improve performance.

```dart
Future<void> saveSearchResults(String query, List<Map<String, dynamic>> results) async {
  final box = await Hive.openBox('search_cache');
  final key = 'search_${query.hashCode}';
  await box.put(key, {
    'query': query,
    'results': results,
    'timestamp': DateTime.now().toIso8601String(),
  });
}
```

## Database Schema Additions

### Add New Tables/Boxes:
1. `dashboard_stats` - Cache online/nearby counts
2. `event_details` - Cache individual event information
3. `other_user_profiles` - Cache profiles of other users
4. `search_cache` - Cache search results

## Provider Updates

### Update dashboardStatsProvider:
```dart
final dashboardStatsProvider = StreamProvider<Map<String, int>>((ref) {
  final localDb = ref.watch(localDbProvider);

  // Try local cache first
  final cached = localDb.getDashboardStats();
  if (cached != null) {
    return Stream.value(cached);
  }

  // Fall back to fresh fetch
  return Stream.fromFuture(_fetchFreshStats());
});
```

## Benefits

### Performance:
- **Reduced server load** - Less frequent API calls
- **Faster UI** - Instant loading from local cache
- **Offline support** - App works with cached data when offline

### User Experience:
- **Smoother navigation** - No loading delays for cached data
- **Better offline experience** - Core features work without internet
- **Reduced data usage** - Fewer network requests

### Platform Consistency:
- **Web and Android parity** - Both platforms use same caching strategy
- **Storage reliability** - Robust error handling for storage failures
- **Data persistence** - Appropriate cache expiration policies

## Implementation Priority

1. **High Priority**: Dashboard stats caching (frequently accessed)
2. **Medium Priority**: Event details caching (performance improvement)
3. **Low Priority**: Search results caching (nice-to-have)

## Testing Strategy

- **Unit tests** for cache operations
- **Integration tests** for cache invalidation
- **Performance tests** comparing cached vs non-cached scenarios
- **Cross-platform tests** ensuring web and Android behave identically</contents>
</xai:function_call: Write file successfully to comprehensive_local_caching_plan.md. Let me start implementing the caching improvements, beginning with dashboard stats. 

<xai:function_call name="todo_write">
<parameter name="merge">false


