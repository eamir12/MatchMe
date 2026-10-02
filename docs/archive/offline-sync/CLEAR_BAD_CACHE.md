# Clear Bad Analytics Cache

The app is caching analytics data with bad click counts. You need to clear this cache before the fix will work properly.

## Quick Fix (Easiest)

### Option 1: Uninstall and Reinstall the App
This completely clears all cached data:
```bash
# Uninstall
adb uninstall [your.package.name]

# Reinstall
flutter run --release
```

### Option 2: Clear App Data (Android)
1. Go to **Settings → Apps → MatchMe**
2. Tap **Storage**
3. Tap **Clear Data** (NOT just Clear Cache)
4. Restart the app

### Option 3: Add a Cache Clear Button (Temporary)

Add this to your External Ads Dashboard to clear bad cache programmatically:

```dart
// In external_ads_dashboard.dart, add this button temporarily:

// In _buildAnalyticsTab or _buildControlsTab, add:
if (kDebugMode)
  ElevatedButton(
    onPressed: () async {
      final localDb = await AdminLocalDbService.instance;
      await localDb.clearExternalAds();  // Clear ads cache
      await localDb.saveExternalAdAnalyticsCache({});  // Clear analytics cache
      
      setState(() {
        _analyticsCache.clear();
        _cachedDashboard = null;
        _dashboardFuture = null;
      });
      
      _scheduleDashboardReload(clearCache: true);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared! Refreshing...')),
      );
    },
    child: const Text('Clear Bad Cache (Debug)'),
  ),
```

## Why This Is Needed

Your app cached analytics data that includes:
- **90d range**: 732 impressions, 63 clicks (includes standalone click events)
- **All range**: 732 impressions, 5 clicks (excludes standalone click events for some reason)

The cached "All" range has bad data (missing 58 clicks). Until you clear this cache, the app will keep showing those bad numbers.

## After Clearing Cache

1. Apply the database migrations (see FIX_AD_CLICK_TRACKING.md)
2. Clear the app cache (using one of the methods above)
3. Restart the app
4. The app will fetch fresh data from Supabase
5. You should see correct numbers for all date ranges

## Verify the Fix

After clearing cache and restarting:
- **90d**: Should show `732 impressions, 63 clicks` ✓
- **All**: Should ALSO show `732 impressions, 63 clicks` ✓ (not 5!)

If you still see different numbers:
1. Check that database migrations were applied
2. Verify standalone click events were deleted
3. Check Supabase logs for errors
