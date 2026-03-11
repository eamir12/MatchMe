# App Config Quick Reference

**⚠️ ADMIN NOTE:** Admin functionality is NOT in the MatchMe app for security.  
Admins should use Supabase Dashboard or build a separate admin interface.

## 🚀 Quick Start

```dart
import 'package:matchme/services/app_config_service.dart';

// Get any config value
final value = await appConfigService.getInt('config.key', defaultValue: 0);
```

## 📋 Common Config Keys

### GPS & Location
```dart
// Battery threshold for throttling (default: 15%)
final threshold = await appConfigService.getInt('gps.battery_low_threshold_percent', defaultValue: 15);

// GPS interval when battery low (default: 60s)
final interval = await appConfigService.getInt('gps.battery_throttle_interval_seconds', defaultValue: 60);

// Stationary detection threshold (default: 10m)
final stationaryThreshold = await appConfigService.getDouble('gps.stationary_similarity_threshold_meters', defaultValue: 10.0);

// Default GPS interval for users (default: 5s)
final defaultInterval = await appConfigService.getInt('gps.interval_default_seconds', defaultValue: 5);

// Allowed GPS interval options
final options = await appConfigService.getIntList('gps.interval_options_seconds', defaultValue: [5, 10, 20, 30, 60]);
```

### Sync & Updates
```dart
// Global sync interval (default: 60s)
final syncInterval = await appConfigService.getDuration('sync.global_interval_seconds', defaultValue: Duration(seconds: 60));

// Heartbeat interval (default: 20s)
final heartbeat = await appConfigService.getDuration('sync.heartbeat_interval_seconds', defaultValue: Duration(seconds: 20));

// Outbox retry interval (default: 5s)
final retryInterval = await appConfigService.getDuration('sync.outbox_retry_interval_seconds', defaultValue: Duration(seconds: 5));
```

### Cache Durations
```dart
// Profile cache (default: 5 minutes)
final profileCache = await appConfigService.getDuration('cache.profile_duration_seconds', defaultValue: Duration(minutes: 5));

// Visibility cache (default: 30 minutes)
final visibilityCache = await appConfigService.getDuration('cache.visibility_duration_seconds', defaultValue: Duration(minutes: 30));

// Events cache (default: 5 minutes)
final eventsCache = await appConfigService.getDuration('cache.events_duration_seconds', defaultValue: Duration(minutes: 5));
```

### Notifications
```dart
// Match notification auto-dismiss (default: 5s)
final matchDismiss = await appConfigService.getDuration('notification.match_auto_dismiss_seconds', defaultValue: Duration(seconds: 5));

// System notification auto-dismiss (default: 6s)
final systemDismiss = await appConfigService.getDuration('notification.system_auto_dismiss_seconds', defaultValue: Duration(seconds: 6));
```

### Profile & User
```dart
// Match radius options (default: [5, 10, 20, 100])
final radiusOptions = await appConfigService.getIntList('profile.match_radius_options_km', defaultValue: [5, 10, 20, 100]);

// Default match radius (default: 20km)
final defaultRadius = await appConfigService.getInt('profile.match_radius_default_km', defaultValue: 20);

// Minimum age (default: 18)
final minAge = await appConfigService.getInt('profile.age_range_min', defaultValue: 18);

// Max file size (default: 5MB)
final maxFileSize = await appConfigService.getInt('profile.max_file_size_bytes', defaultValue: 5242880);
```

## 🔧 Service Methods

```dart
// Get integer
await appConfigService.getInt('key', defaultValue: 0)

// Get double/float
await appConfigService.getDouble('key', defaultValue: 0.0)

// Get boolean
await appConfigService.getBool('key', defaultValue: false)

// Get string
await appConfigService.getString('key', defaultValue: '')

// Get list
await appConfigService.getList('key', defaultValue: [])

// Get int list (converts all elements to int)
await appConfigService.getIntList('key', defaultValue: [])

// Get duration (converts seconds to Duration)
await appConfigService.getDuration('key', defaultValue: Duration.zero)

// Get percentage (same as double, semantic meaning)
await appConfigService.getPercentage('key', defaultValue: 0.0)

// Get all configs in a category
await appConfigService.getCategory('gps')

// Check if key exists
await appConfigService.hasKey('key')

// Force refresh cache
await appConfigService.refresh()

// Get raw value (for debugging)
await appConfigService.getRaw('key')
```

## 📝 Best Practices

### ✅ DO
```dart
// Always provide a default
final value = await appConfigService.getInt('key', defaultValue: 10);

// Cache config values in providers
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

// Use semantic types
final duration = await appConfigService.getDuration('key', ...);
final percentage = await appConfigService.getPercentage('key', ...);
```

### ❌ DON'T
```dart
// Don't forget defaults
final value = await appConfigService.getInt('key'); // Defaults to 0

// Don't block UI
final value = await appConfigService.getInt('key', defaultValue: 10);
setState(() { /* UI update */ }); // Good

// Don't hardcode
const batteryThreshold = 15; // Bad - use config instead
```

## 🔐 Security Notes

- **Anyone can READ** configs (both authenticated and anonymous)
- **Only ADMINS can WRITE** (users with `is_admin = true`)
- Configs are cached for 5 minutes
- Values are validated against min/max constraints

## 🐛 Debugging

```dart
// Check if config loaded
if (await appConfigService.hasKey('gps.battery_low_threshold_percent')) {
  debugPrint('✅ Config loaded');
} else {
  debugPrint('❌ Config missing');
}

// Get raw value to see actual type
final raw = await appConfigService.getRaw('gps.battery_low_threshold_percent');
debugPrint('Raw value: $raw (${raw.runtimeType})');

// Force refresh if values seem stale
await appConfigService.refresh();
debugPrint('Config refreshed');
```

## 📚 All Categories

| Category | Description |
|----------|-------------|
| `gps` | GPS and location settings |
| `sync` | Data synchronization |
| `cache` | Local caching durations |
| `calendar` | Calendar sync settings |
| `notification` | Notification behavior |
| `ui` | UI/UX behavior |
| `profile` | Profile settings |
| `translation` | Translation service |
| `performance` | Performance tuning |
| `time_ranges` | Time period definitions |

## 🔗 Related Files

- **Service**: `lib/services/app_config_service.dart`
- **SQL Schema**: `create_app_config_table.sql`
- **Full Docs**: `APP_CONFIG_README.md`
- **Summary**: `IMPLEMENTATION_SUMMARY.md`
- **Deployment**: `DEPLOYMENT_CHECKLIST.md`

## 💡 Examples

### Example 1: Simple Usage
```dart
final batteryThreshold = await appConfigService.getInt(
  'gps.battery_low_threshold_percent',
  defaultValue: 15
);

if (batteryLevel <= batteryThreshold) {
  // Throttle GPS
}
```

### Example 2: Duration
```dart
final syncInterval = await appConfigService.getDuration(
  'sync.global_interval_seconds',
  defaultValue: Duration(seconds: 60)
);

Timer.periodic(syncInterval, (timer) {
  // Sync data
});
```

### Example 3: Array Options
```dart
final radiusOptions = await appConfigService.getIntList(
  'profile.match_radius_options_km',
  defaultValue: [5, 10, 20, 100]
);

// Use in dropdown
DropdownButton<int>(
  items: radiusOptions.map((radius) => 
    DropdownMenuItem(value: radius, child: Text('$radius km'))
  ).toList(),
  // ...
);
```

### Example 4: User Override Pattern
```dart
// Get effective value (user preference or app default)
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

---

**Need help?** Check `APP_CONFIG_README.md` for full documentation.
