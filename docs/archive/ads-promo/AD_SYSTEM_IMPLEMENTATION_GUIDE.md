# Unified Ad System Implementation Guide

## Overview

The advertising system has been completely redesigned to provide unified management of both internal (sponsored cards) and external (AdMob, Facebook, etc.) ad networks through a single admin interface. The system features:

- **Master on/off switch** for all advertising
- **System-aware controls** where only one system can be active at a time
- **Shared configuration** for both systems (placements, tiers, schedules, rate limiting)
- **Flexible management** allowing different configurations per system
- **Database-driven** with full Supabase integration

---

## Database Schema

### New Tables

#### `ad_system_config`
Master configuration table for each ad system (internal/external).

```sql
- id: UUID (primary key)
- system_type: TEXT ('internal' or 'external') - UNIQUE
- is_enabled: BOOLEAN (default: false)
- priority: INTEGER (default: 100)
- allowed_placements: JSONB (array of placement strings)
- allowed_tiers: JSONB (array of tier strings)
- allowed_platforms: JSONB (array of platform strings)
- schedule_enabled: BOOLEAN
- schedule_start_time: TEXT (HH:MM format)
- schedule_end_time: TEXT (HH:MM format)
- schedule_days: JSONB (array of day names)
- max_impressions_per_session: INTEGER
- min_minutes_between_impressions: INTEGER
- first_impression_delay_seconds: INTEGER
- daily_impression_cap: INTEGER
- config: JSONB (system-specific configuration)
- created_at: TIMESTAMPTZ
- updated_at: TIMESTAMPTZ
```

#### `ad_system_placements`
Per-placement configuration for each ad system.

```sql
- id: UUID (primary key)
- system_config_id: UUID (foreign key to ad_system_config)
- placement: TEXT ('home_inline', 'matches_inline', 'chats_inline', 'events_inline')
- is_enabled: BOOLEAN (default: true)
- priority: INTEGER (default: 100)
- created_at: TIMESTAMPTZ
- updated_at: TIMESTAMPTZ
- UNIQUE(system_config_id, placement)
```

#### `ad_system_tiers`
Per-tier configuration for each ad system.

```sql
- id: UUID (primary key)
- system_config_id: UUID (foreign key to ad_system_config)
- tier: TEXT ('free', 'premium', 'vip')
- is_enabled: BOOLEAN (default: true)
- created_at: TIMESTAMPTZ
- updated_at: TIMESTAMPTZ
- UNIQUE(system_config_id, tier)
```

#### `ad_system_schedules`
Complex scheduling rules for ad systems (for future use).

```sql
- id: UUID (primary key)
- system_config_id: UUID (foreign key to ad_system_config)
- name: TEXT
- description: TEXT
- is_active: BOOLEAN
- start_date: DATE
- end_date: DATE
- start_time: TEXT (HH:MM format)
- end_time: TEXT (HH:MM format)
- days_of_week: JSONB (array of day names)
- daily_impression_cap: INTEGER
- total_impression_cap: INTEGER
- created_at: TIMESTAMPTZ
- updated_at: TIMESTAMPTZ
```

### Migration File

Location: `supabase/migrations/20260423000000_unified_ad_system_config.sql`

This migration:
- Creates all four new tables
- Sets up proper indexes for performance
- Enables Row Level Security (RLS) with admin-only policies
- Creates triggers for automatic `updated_at` timestamps
- Initializes default configurations for both systems

---

## Admin Dashboard

### Location
`matchme_admin/lib/screens/unified_ad_management_dashboard.dart`

### Features

#### Master Switch
- Global on/off for all advertising
- When OFF: both systems are disabled regardless of individual toggles
- When ON: either system can be enabled (not both simultaneously)

#### System-Specific Sections

Each system (Internal and External) has:

1. **Enable Toggle**
   - Only available when master switch is ON
   - Disabled state shows helpful message

2. **Placements Configuration**
   - Toggle each placement on/off
   - Placements: Home Inline, Matches Inline, Chats Inline, Events Inline
   - Per-system configuration

3. **User Tiers Configuration**
   - Toggle each tier on/off
   - Tiers: Free, Premium, VIP
   - Per-system configuration

4. **Schedule Configuration**
   - Enable/disable time-based scheduling
   - Start time and end time (HH:MM format)
   - Days of week selection (future enhancement)

5. **Rate Limiting Configuration**
   - Max impressions per session
   - Min minutes between impressions
   - First impression delay (seconds)
   - Daily impression cap

### Admin Navigation

The dashboard is accessible under "Sponsored Ads" in the admin app navigation:
- Navigation rail shows "Ad System Settings" section
- Settings icon for easy identification
- Integrated with existing admin app structure

---

## Main App Integration

### AdSlot Widget
Location: `lib/widgets/ad_slot.dart`

The widget now:
1. Queries `ad_system_config` table to check which system is enabled
2. Displays external ads if external system is enabled
3. Falls back to internal ads if internal system is enabled
4. Shows nothing if both are disabled

```dart
// Checks ad_system_config table
final externalEnabled = await supabase
    .from('ad_system_config')
    .select('is_enabled')
    .eq('system_type', 'external')
    .maybeSingle();

final internalEnabled = await supabase
    .from('ad_system_config')
    .select('is_enabled')
    .eq('system_type', 'internal')
    .maybeSingle();
```

---

## Configuration Flow

### Admin Updates Settings

1. Admin opens "Ad System Settings" in admin app
2. Adjusts master switch and system toggles
3. Configures placements, tiers, schedules, rate limits
4. Clicks "Save Settings"

### Admin App Saves to Database

The dashboard updates:
- `app_config` table: Master switch (`ads.enabled`)
- `ad_system_config` table: System-specific settings
- `ad_system_placements` table: Per-placement toggles
- `ad_system_tiers` table: Per-tier toggles

### Main App Reads Configuration

1. AdSlot widget queries `ad_system_config` on build
2. Determines which system to display
3. Renders appropriate ad widget (external or internal)
4. Configuration changes are reflected immediately

---

## Key Design Decisions

### 1. Master On/Off Switch
- Provides global kill switch for all advertising
- Prevents accidental simultaneous operation of both systems
- Stored in `app_config` table for backward compatibility

### 2. System-Aware Controls
- Only one system can be active at a time
- Prevents confusion and resource conflicts
- Admin UI enforces this constraint

### 3. Shared Configuration
- Both systems use same placement/tier/schedule structure
- Reduces complexity and maintenance
- Allows easy switching between systems

### 4. Flexible System-Specific Config
- `config` JSONB column in `ad_system_config` for system-specific settings
- Allows external systems to store provider-specific data
- Extensible for future ad networks

### 5. Database-Driven
- All configuration stored in Supabase
- No hardcoded values
- Changes take effect immediately
- Audit trail via timestamps

---

## Usage Instructions

### For Admins

1. **Enable Advertising**
   - Open Admin App → Sponsored Ads → Ad System Settings
   - Toggle "Advertising System" ON

2. **Choose System**
   - Toggle "Enable Internal Ads" OR "Enable External Ads" (not both)
   - Configure placements where ads should appear
   - Select user tiers that should see ads

3. **Optional: Set Schedule**
   - Toggle "Schedule" ON
   - Set start and end times (HH:MM format)
   - Ads will only show during scheduled hours

4. **Optional: Rate Limiting**
   - Set max impressions per session
   - Set minimum time between impressions
   - Set first impression delay
   - Set daily impression cap

5. **Save**
   - Click "Save Settings"
   - Changes take effect immediately in main app

### For Developers

#### Adding a New Placement
1. Add to `ad_system_placements` table
2. Update AdSlot widget to handle new placement
3. Update admin dashboard UI

#### Adding a New Tier
1. Add to `ad_system_tiers` table
2. Update tier checking logic in main app
3. Update admin dashboard UI

#### Adding System-Specific Config
1. Store in `config` JSONB column of `ad_system_config`
2. Query and parse in main app
3. Add UI controls in admin dashboard

---

## Testing Checklist

- [ ] Master switch disables all ads when OFF
- [ ] Internal ads show when enabled and external is disabled
- [ ] External ads show when enabled and internal is disabled
- [ ] Placement toggles control where ads appear
- [ ] Tier toggles control which users see ads
- [ ] Schedule times prevent ads outside scheduled hours
- [ ] Rate limiting prevents excessive impressions
- [ ] Settings persist after app restart
- [ ] Admin changes reflect immediately in main app
- [ ] Both systems cannot be enabled simultaneously

---

## Future Enhancements

1. **Complex Scheduling**
   - Use `ad_system_schedules` table for advanced scheduling
   - Support recurring schedules
   - Support date ranges

2. **A/B Testing**
   - Add variant configuration
   - Track performance per variant
   - Automatic winner selection

3. **Geo-Targeting**
   - Add location-based configuration
   - Different settings per region

4. **Device-Specific Config**
   - Different settings per platform (iOS/Android/Web)
   - Device type targeting

5. **Analytics Dashboard**
   - Real-time impression/click tracking
   - Revenue reporting
   - Performance metrics per system

---

## Database Migration

To apply the new schema:

```bash
# Run the migration
supabase migration up

# Or manually execute the SQL file in Supabase dashboard
# File: supabase/migrations/20260423000000_unified_ad_system_config.sql
```

The migration automatically:
- Creates all tables with proper constraints
- Sets up RLS policies
- Initializes default configurations
- Creates necessary indexes

---

## Troubleshooting

### Ads Not Showing
1. Check master switch is ON in admin dashboard
2. Check system is enabled (Internal or External)
3. Check placement is enabled for that screen
4. Check user tier is enabled
5. Check schedule (if enabled) allows current time
6. Check rate limiting hasn't been exceeded

### Settings Not Saving
1. Verify admin user has `is_admin = true` in database
2. Check Supabase connection
3. Check browser console for errors
4. Verify RLS policies allow admin access

### Performance Issues
1. Check indexes are created (migration should do this)
2. Monitor database query performance
3. Consider caching configuration in main app

---

## Files Modified/Created

### New Files
- `supabase/migrations/20260423000000_unified_ad_system_config.sql`
- `matchme_admin/lib/screens/unified_ad_management_dashboard.dart`

### Modified Files
- `matchme_admin/lib/main.dart` (updated imports and screen reference)
- `lib/widgets/ad_slot.dart` (updated to query new tables)

### Deleted Files
- `matchme_admin/lib/screens/ad_system_settings_dashboard.dart` (replaced by unified dashboard)

---

## Support

For questions or issues:
1. Check the troubleshooting section above
2. Review the database schema
3. Check admin dashboard for configuration errors
4. Verify RLS policies in Supabase dashboard
