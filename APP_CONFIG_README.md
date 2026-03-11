# App Configuration System

## Overview

The MatchMe app now uses a centralized configuration system that allows runtime configuration of application settings through a Supabase `app_config` table. This eliminates hardcoded values and enables admins to adjust settings without code changes.

## Architecture

### Three-Tier Configuration Pattern

1. **`app_config` Table (Supabase)** - Source of truth for all configs
   - System-wide settings (admin-only)
   - Default values for user-configurable settings
   
2. **`users` Table Columns** - User-specific overrides
   - Existing columns like `gps_interval_default`, `match_radius_default`
   - User can customize their own settings
   
3. **Hardcoded Fallbacks** - Safety net
   - If config service fails, app uses reasonable defaults

### Resolution Order

```
User's Profile Value → app_config Default → Hardcoded Fallback
```

## Database Setup

### 1. Run the SQL Migration

Execute `create_app_config_table.sql` in your Supabase SQL Editor:

```bash
# From project root
psql -h <your-db-host> -U postgres -d postgres -f create_app_config_table.sql
```

Or copy-paste the contents into Supabase Dashboard → SQL Editor.

### 2. Verify Installation

```sql
SELECT COUNT(*) FROM app_config;
-- Should return ~60+ config entries

SELECT * FROM app_config WHERE category = 'gps';
-- Should show GPS-related configs
```

## Usage in Code

### Basic Usage

```dart
import 'package:matchme/services/app_config_service.dart';

// Get a config value
final batteryThreshold = await appConfigService.getInt(
  'gps.battery_low_threshold_percent', 
  defaultValue: 15
);

// Get duration (returns Duration object)
final syncInterval = await appConfigService.getDuration(
  'sync.global_interval_seconds',
  defaultValue: Duration(seconds: 60)
);

// Get boolean
final isEnabled = await appConfigService.getBool(
  'feature.some_flag',
  defaultValue: false
);

// Get array
final radiusOptions = await appConfigService.getIntList(
  'profile.match_radius_options_km',
  defaultValue: [5, 10, 20, 100]
);
```

### Initialization

The service is automatically initialized in `main.dart` after the first frame:

```dart
// Already handled in main.dart
unawaited(appConfigService.initialize().then((_) {
  debugPrint('App config initialized');
}));
```

### Force Refresh

```dart
// Refresh config from database (e.g., after admin updates)
await appConfigService.refresh();
```

### Get All Configs in Category

```dart
final gpsConfigs = await appConfigService.getCategory('gps');
// Returns Map<String, dynamic> with all 'gps.*' keys
```

## Configuration Categories

| Category | Description | Examples |
|----------|-------------|----------|
| `gps` | GPS and location settings | Battery thresholds, intervals, accuracy |
| `sync` | Data synchronization | Sync intervals, heartbeat timing |
| `cache` | Local caching durations | Profile cache, visibility cache |
| `calendar` | Calendar sync settings | Token expiry, fetch ranges |
| `notification` | Notification behavior | Auto-dismiss times, delays |
| `ui` | UI/UX behavior | Debounce values, delays |
| `profile` | Profile settings | Age ranges, file size limits |
| `translation` | Translation service | API limits, confidence thresholds |
| `performance` | Performance tuning | Sampling rates, retry intervals |

## Key Configuration Keys

### GPS & Location
- `gps.battery_low_threshold_percent` - When to throttle GPS (default: 15%)
- `gps.battery_throttle_interval_seconds` - GPS rate when low battery (default: 60s)
- `gps.stationary_max_positions` - Positions to track for stationary detection (default: 5)
- `gps.stationary_similarity_threshold_meters` - Distance for stationary (default: 10m)
- `gps.interval_default_seconds` - Default GPS interval for users (default: 5s)

### Sync & Updates
- `sync.global_interval_seconds` - Match/chat sync frequency (default: 60s)
- `sync.heartbeat_interval_seconds` - Activity heartbeat (default: 20s)
- `sync.outbox_retry_interval_seconds` - Message retry rate (default: 5s)

### Caching
- `cache.profile_duration_seconds` - Profile cache TTL (default: 300s)
- `cache.visibility_duration_seconds` - Visibility cache TTL (default: 1800s)
- `cache.events_duration_seconds` - Events cache TTL (default: 300s)

### User Configurable
- `profile.match_radius_options_km` - Allowed radius options [5,10,20,100]
- `profile.match_radius_default_km` - Default match radius (default: 20km)
- `gps.interval_options_seconds` - Allowed GPS intervals [5,10,20,30,60]
- `notification.match_auto_dismiss_seconds` - Match notification duration (default: 5s)

See `create_app_config_table.sql` for complete list.

## Admin Management

**⚠️ SECURITY: Admin functionality is NOT in the MatchMe app.**

Admins should manage configurations using Supabase Dashboard or a separate admin interface.

### Option 1: Supabase Dashboard (Recommended)

1. Login to your Supabase project
2. Navigate to **Table Editor** → **app_config**
3. Find the config row you want to edit
4. Click to edit the **config_value** column
5. Save changes (app picks up within 5 minutes)

### Option 2: SQL Editor

```sql
-- Update a config value
UPDATE app_config 
SET config_value = '20'
WHERE config_key = 'gps.battery_low_threshold_percent';

-- View all GPS configs
SELECT config_key, config_value, description 
FROM app_config 
WHERE category = 'gps'
ORDER BY config_key;

-- Find user-configurable settings
SELECT config_key, config_value, description
FROM app_config
WHERE is_user_configurable = true;
```

### Option 3: Separate Admin Web App

For a better admin experience, create a dedicated admin interface:
- Build standalone web app (Next.js, Flutter Web, etc.)
- Use Supabase client with service role key
- Deploy on admin-only subdomain (admin.matchme.com)
- Keep completely separate from user-facing app

## Migration Strategy

### Phase 1: Infrastructure (DONE)
- ✅ Created `app_config` table
- ✅ Created `AppConfigService`
- ✅ Integrated into app startup
- ✅ Example usage in `visibility_provider.dart`

### Phase 2: Systematic Replacement (TODO)
Replace hardcoded values throughout the codebase:
1. GPS & Location services
2. Sync managers
3. Cache services
4. Calendar sync
5. Notification handlers
6. UI components

### Phase 3: Admin Interface (TODO)
- Admin settings screen
- Real-time config updates
- Validation and constraints
- Change history/audit log

## Best Practices

### For Developers

1. **Always provide a fallback default**
   ```dart
   final value = await appConfigService.getInt('key', defaultValue: 10);
   ```

2. **Cache config values in providers**
   ```dart
   // Load once in build() or init
   int _batteryThreshold = 15;
   
   @override
   void build() {
     Future.microtask(() async {
       _batteryThreshold = await appConfigService.getInt(
         'gps.battery_low_threshold_percent',
         defaultValue: 15
       );
     });
   }
   ```

3. **Use semantic naming**
   ```dart
   // Good
   'gps.battery_low_threshold_percent'
   
   // Bad
   'threshold1'
   ```

4. **Document what the config does**
   - Add description in SQL INSERT
   - Include min/max validation values

### For Admins

1. **Validate before changing**
   - Check `min_value` and `max_value` constraints
   - Review `allowed_values` for enum-like configs

2. **Test in staging first**
   - Critical configs like GPS intervals can affect UX

3. **Monitor after changes**
   - Watch error logs for issues
   - Monitor user feedback

4. **Document changes**
   - Keep track of what you changed and why

## Troubleshooting

### Config not loading

```dart
// Check if service initialized
if (await appConfigService.hasKey('gps.battery_low_threshold_percent')) {
  print('Config loaded');
} else {
  print('Config missing - check database');
}
```

### Values not updating

```dart
// Force refresh cache
await appConfigService.refresh();
```

### App using old values

1. Check the config exists in database
2. Verify key name matches exactly (case-sensitive)
3. Ensure app has re-initialized after config change
4. Check logs for config load errors

## Security

### Row Level Security (RLS)

The `app_config` table has RLS enabled:
- ✅ **Read**: All authenticated and anonymous users can read
- ❌ **Write**: Only admins (users with `is_admin = true`) can insert/update/delete

### API Access

```dart
// Anyone can read configs
final configs = await supabase.from('app_config').select();

// Only admins can update
await supabase.from('app_config')
  .update({'config_value': '20'})
  .eq('config_key', 'gps.battery_low_threshold_percent');
// Fails if current user is not admin
```

## Performance

### Caching Strategy

- Configs cached in memory for 5 minutes
- Refresh happens automatically on cache expiry
- Manual refresh available via `appConfigService.refresh()`

### Startup Impact

- Config load happens **after first frame** (non-blocking)
- Uses fallback defaults until loaded
- ~50-100ms to load all configs

### Network Usage

- Initial load: ~5KB
- Refresh: ~5KB
- Minimal impact on bandwidth

## Examples

### Example 1: Using GPS Config

```dart
// In visibility_provider.dart
class IsVisible extends _$IsVisible {
  int _batteryLowThreshold = 15;
  
  @override
  bool build() {
    // Load config value
    Future.microtask(() async {
      _batteryLowThreshold = await appConfigService.getInt(
        'gps.battery_low_threshold_percent',
        defaultValue: 15
      );
    });
    
    return false;
  }
  
  Future<void> checkBattery() async {
    final batteryLevel = await getBatteryLevel();
    if (batteryLevel <= _batteryLowThreshold) {
      // Throttle GPS
    }
  }
}
```

### Example 2: User-Configurable Setting

```dart
// Get user's preference or fallback to app default
Future<int> getEffectiveGpsInterval(String userId) async {
  // 1. Check user's profile
  final profile = await getUserProfile(userId);
  if (profile.gpsIntervalDefault != null) {
    return profile.gpsIntervalDefault!;
  }
  
  // 2. Fallback to app_config default
  return await appConfigService.getInt(
    'gps.interval_default_seconds',
    defaultValue: 5
  );
}
```

### Example 3: Admin Override

```sql
-- Admin wants to reduce battery threshold globally
UPDATE app_config
SET config_value = '20'
WHERE config_key = 'gps.battery_low_threshold_percent';

-- Users will get new value within 5 minutes (cache expiry)
-- Or immediately after app restart
```

## Future Enhancements

- [ ] Real-time config updates via Supabase Realtime
- [ ] A/B testing support
- [ ] Feature flags system
- [ ] Per-environment configs (dev/staging/prod)
- [ ] Config change audit log
- [ ] Rollback mechanism
- [ ] Admin UI with validation
- [ ] Config export/import
- [ ] Analytics on config impact

## Support

For questions or issues:
1. Check logs for `[AppConfig]` messages
2. Verify database has config entries
3. Test with `appConfigService.refresh()`
4. Check that key names match exactly

---

**Last Updated**: January 19, 2026  
**Version**: 1.0.0  
**Status**: Production Ready ✅
