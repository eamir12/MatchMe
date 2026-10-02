# Ad System Standardization - Complete Implementation

## Overview

Both the internal (sponsored ads) and external (third-party networks) ad systems now use a unified configuration approach through the `app_config` table. This eliminates inconsistency and makes configuration management simpler across both admin and regular apps.

## Architecture

### Configuration Table: `app_config`

All ad system configuration is now stored in the `app_config` table with standardized key naming:

**Internal System Keys** (prefix: `ads.internal.*`)
- `ads.internal.enabled` - Enable/disable internal ads
- `ads.internal.free_tier_only` - Only free tier users see ads
- `ads.internal.sponsored_cards_enabled` - Enable/disable sponsored cards
- `ads.internal.allowed_placements` - JSON array of allowed placements
- `ads.internal.allowed_tiers` - JSON array of allowed subscription tiers
- `ads.internal.allowed_platforms` - JSON array of allowed platforms
- `ads.internal.max_impressions_per_session` - Cap per session (default: 3)
- `ads.internal.min_minutes_between_impressions` - Pacing interval (default: 8 minutes)
- `ads.internal.first_impression_delay_seconds` - Delay after app start (default: 90 seconds)
- `ads.internal.report_enabled` - Allow user reporting
- `ads.internal.mobile_native_enabled` - Enable native mobile ads
- `ads.internal.mobile_provider` - Mobile ad provider (none, admob)

**External System Keys** (prefix: `ads.external.*`)
- `ads.external.enabled` - Enable/disable external ads
- `ads.external.allowed_placements` - JSON array of allowed placements
- `ads.external.allowed_tiers` - JSON array of allowed subscription tiers
- `ads.external.allowed_platforms` - JSON array of allowed platforms
- `ads.external.max_impressions_per_user_per_day` - Rate limit per day (default: 5)
- `ads.external.max_impressions_per_user_per_hour` - Rate limit per hour (default: 2)
- `ads.external.personalized_ads_default` - Default personalization setting
- `ads.external.show_consent_form` - Show consent form on first launch
- `ads.external.min_user_age_for_personalization` - COPPA compliance (default: 13)
- `ads.external.mediation_enabled` - Enable ad mediation
- `ads.external.admob_enabled` - Enable AdMob
- `ads.external.facebook_enabled` - Enable Facebook Audience Network
- `ads.external.applovin_enabled` - Enable AppLovin
- `ads.external.unity_enabled` - Enable Unity Ads

### Data Tables (Unchanged)

**Internal System:**
- `ad_campaigns` - Campaign definitions
- `ad_creatives` - Creative variants per placement/platform
- `ad_impressions` - Impression audit trail
- `ad_clicks` - Click audit trail
- `ad_reports` - User reports

**External System:**
- `ad_networks` - Network providers (AdMob, Facebook, etc.)
- `ad_units` - Network-specific placements
- `ad_revenue_events` - Event tracking and revenue
- `ad_network_analytics` - Aggregated metrics
- `ad_consent` - User privacy preferences

## Mutual Exclusivity

Only one ad system can be enabled at a time:

- If `ads.internal.enabled = true` → `ads.external.enabled` is set to `false`
- If `ads.external.enabled = true` → `ads.internal.enabled` is set to `false`

This is enforced at the application layer (admin dashboards) with user confirmation dialogs.

## Admin Dashboards

### Internal System Dashboard
- **File:** `matchme_admin/lib/screens/sponsored_ads_dashboard.dart`
- **Configuration Keys:** `ads.internal.*`
- **Reads/Writes:** `app_config` table
- **Confirmation Dialog:** When enabling, warns user that external ads will be disabled

### External System Dashboard
- **File:** `matchme_admin/lib/screens/external_ads_dashboard.dart`
- **Configuration Keys:** `ads.external.*`
- **Reads/Writes:** `app_config` table
- **Confirmation Dialog:** When enabling, warns user that internal ads will be disabled

### Unified Dashboard
- **File:** `matchme_admin/lib/screens/integrated_ad_dashboard.dart`
- **Tabs:** Internal System | External System
- **Each tab contains:** Analytics | Ad Controls | Sponsored Ads (campaigns)

## Regular App Integration

### AppConfigService
The `AppConfigService` in the regular app reads from `app_config` table and provides methods:

```dart
// Internal system
Future<bool> areAdsEnabled() // reads ads.internal.enabled
Future<List<String>> getAdAllowedPlacements() // reads ads.internal.allowed_placements
Future<bool> isAdsFreeTierOnly() // reads ads.internal.free_tier_only

// External system
Future<bool> isExternalAdsEnabled() // reads ads.external.enabled
Future<int> getExternalAdMaxPerDay() // reads ads.external.max_impressions_per_user_per_day
Future<int> getExternalAdMaxPerHour() // reads ads.external.max_impressions_per_user_per_hour
```

### AdSlot Widget
The `AdSlot` widget checks which system is enabled and displays accordingly:

```dart
if (externalEnabled) {
  return _buildExternalAd(context, ref);
} else if (internalEnabled) {
  return _buildSponsoredAd(context, ref);
} else {
  return const SizedBox.shrink();
}
```

## Migration Path

1. **Database:** Run migrations to create `app_config` entries for external system
2. **Admin Dashboards:** Updated to read/write from `app_config` table
3. **Regular App:** `AppConfigService` already supports both systems
4. **Deprecation:** Old `ad_system_config` table can be deprecated after verification

## Benefits

✅ **Consistency:** Both systems use the same configuration table and naming convention
✅ **Simplicity:** Single source of truth for all ad configuration
✅ **Maintainability:** Easier to add new configuration options
✅ **Scalability:** Can easily add more ad systems in the future
✅ **Mutual Exclusivity:** Enforced at application layer with user confirmation
✅ **Unified Admin UI:** Both systems managed from same dashboard
✅ **Regular App:** Uses same service for both systems

## Configuration Initialization

Run these migrations to initialize the unified configuration:

```bash
supabase migration up
```

This will:
1. Create the `ad_system_config_view` for backward compatibility
2. Initialize all `app_config` entries for both systems with sensible defaults
3. Ensure mutual exclusivity is documented

## Future Enhancements

- Add more ad networks (Tapjoy, Vungle, etc.)
- Add scheduling rules (time-based, day-based)
- Add geographic targeting
- Add A/B testing framework
- Add revenue optimization algorithms
