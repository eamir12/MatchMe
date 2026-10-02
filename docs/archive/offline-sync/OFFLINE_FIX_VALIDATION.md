# Offline Performance Fix - Validation Checklist

## Code Changes Verification

### ✅ connectivity_provider.dart Changes
- [x] `offlineReprobeInterval` added to `ConnectivityMonitorConfig` (60 seconds)
- [x] `suspectProbeInterval` changed from 3s to 30s
- [x] `sample()` method updated to skip Supabase probes when `!hasTransport`
- [x] Interval selection logic updated:
  - [x] Uses `offlineReprobeInterval` when `!hasTransport`
  - [x] Uses `healthyProbeInterval` when online
  - [x] Uses `suspectProbeInterval` when degraded

### ✅ global_sync_manager.dart Changes
- [x] Removed immediate sync on startup
- [x] Added connectivity listener that starts/stops sync based on backend health
- [x] Sets `offlineCacheManager.setSupabaseAvailability(false)` when offline
- [x] Proper error logging with connectivity state

### ✅ home_screen.dart Changes
- [x] Timer setup for periodic activity updates (30 seconds)
- [x] Activity update only when online
- [x] Better error handling with silent failures
- [x] Proper timer cleanup in dispose

## Expected Behavior

### Offline Scenario
1. **App Launch (No Network)**
   - [ ] Shows loading screen briefly
   - [ ] Displays home screen within 1 second
   - [ ] Shows offline indicator banner
   - [ ] All data comes from local cache
   - [ ] No network timeouts or hangs

2. **Offline Navigation**
   - [ ] Can navigate between screens smoothly
   - [ ] No unnecessary refreshes or flicker
   - [ ] Matches/chats display from cache
   - [ ] Chat messages load instantly
   - [ ] No "Loading..." indicators

3. **Offline Timeline**
   - [ ] 0-100ms: Loading screen appears
   - [ ] 100-500ms: Bootstrap completes
   - [ ] 500-1000ms: Home screen renders with cached data
   - [ ] After: Stable display, no refreshes

### Online Scenario
1. **Startup (Online)**
   - [ ] Loading screen shows
   - [ ] Home screen displays within 1-2 seconds
   - [ ] No offline indicator
   - [ ] Sync begins automatically
   - [ ] Fresh data appears as it arrives

2. **Connectivity Health**
   - [ ] Probes run every 10-30 seconds (not constant)
   - [ ] No 5-second hangs visible
   - [ ] Smooth transitions between updates

### Offline → Online Transition
1. **Automatic Sync Start**
   - [ ] When connectivity confirmed, sync begins
   - [ ] Matches/chats refresh with new data
   - [ ] No manual refresh needed
   - [ ] Offline indicator disappears

2. **Message Delivery**
   - [ ] Pending messages send automatically
   - [ ] Realtime updates begin working
   - [ ] Activity status updates

### Online → Offline Transition
1. **Graceful Degradation**
   - [ ] Cached data remains visible
   - [ ] Offline indicator appears
   - [ ] Network calls stop cleanly
   - [ ] No error messages spam logs

2. **UI Stability**
   - [ ] No constant refreshing
   - [ ] No visual flicker
   - [ ] Smooth experience with cached data

## Performance Metrics Validation

### Startup Performance
```
METRIC: Time to home screen display
EXPECTED: < 1 second (offline) / 1-2 seconds (online)
VALIDATION: Use Flutter DevTools Timeline
```

### Connectivity Check Frequency
```
METRIC: Supabase health_check call frequency when offline
EXPECTED: None (skip Supabase probes entirely)
VALIDATION: Monitor "health_check" calls in network tab
```

```
METRIC: Transport check frequency when offline
EXPECTED: Every 60 seconds
VALIDATION: Connectivity().checkConnectivity() called ~every 60s
```

### Home Screen Stability
```
METRIC: Widget rebuild frequency (offline)
EXPECTED: < 1 rebuild per minute
VALIDATION: Flutter DevTools widget rebuild stats
```

```
METRIC: Provider invalidation frequency
EXPECTED: Only on real data changes, not connectivity bounces
VALIDATION: Monitor globalSyncManagerProvider invalidations
```

## Debugging Techniques

### Check Connectivity State in DevTools
```dart
// Paste in Flutter Console:
ref.read(connectivityHealthProvider)

// Should return:
// - When offline: ConnectivityHealth(status: offline, hasNetworkTransport: false, backendReachable: false)
// - When degraded: ConnectivityHealth(status: degraded, hasNetworkTransport: true, backendReachable: false)
// - When online: ConnectivityHealth(status: online, hasNetworkTransport: true, backendReachable: true)
```

### Check Supabase Availability
```dart
// In console:
offlineCacheManager.isSupabaseAvailable

// Should be false when offline/degraded
// Should be true when online and synced
```

### Monitor Sync Status
```dart
// Watch logs for:
"✅ [SYNC] Backend is healthy - starting sync"  // Good: Sync started
"⏸️ [SYNC] Backend is not healthy - stopping"    // Good: Offline detected
```

### Trace Network Calls
1. Open DevTools Network tab
2. Filter for "health_check" calls
3. When offline: Should see very few (only every 60s check for transport)
4. When online, degraded: Should see every 30s
5. When online, healthy: Should see every 10s

## Common Issues & Solutions

### Issue: Home screen still refreshing frequently
**Debug:**
- Check if there are other providers watching connectivity
- Check if realtime listeners are setting up/tearing down
- Look for provider invalidations in logs

**Solution:**
- Verify all home_providers use `.family` with proper invalidation logic
- Ensure realtime listeners are stable (not recreated frequently)

### Issue: Offline detection not working
**Debug:**
- Check `connectivityProvider.value` in DevTools
- Look for "Backend is healthy" logs

**Solution:**
- Verify network connectivity actually down
- Check Supabase service status
- Verify health_check RPC function exists and works

### Issue: Sync not starting when online
**Debug:**
- Check backend connectivity health status
- Look for sync start logs: "Backend is healthy"

**Solution:**
- Verify network connectivity is good
- Check app logs for "Backend is healthy" message
- Look for any errors preventing sync

## Rollback Plan

If issues arise, restore original files:
- `lib/providers/connectivity_provider.dart` (revert `suspectProbeInterval` to 3s)
- `lib/services/global_sync_manager.dart` (restore immediate sync on startup)
- `lib/screens/home/home_screen.dart` (restore inline activity update)

Changes are non-destructive and can be reverted without data loss.

## Sign-Off Checklist

- [ ] All code changes verified for syntax errors
- [ ] No errors in connectivity_provider.dart
- [ ] No errors in global_sync_manager.dart
- [ ] No errors in home_screen.dart
- [ ] Documentation created: OFFLINE_PERFORMANCE_FIX.md
- [ ] Offline startup < 1 second verified
- [ ] No Supabase health_check calls when offline verified
- [ ] Home screen refresh frequency tested
- [ ] Offline → online transitions work smoothly
- [ ] Online → offline transitions work smoothly
- [ ] No visual glitches or hangs observed
- [ ] Performance metrics improved as documented
