# Ad System Fix - Migration Guide

## Problem
Ads from the internal ad system weren't displaying in the MatchMe app.

## Root Cause
The ad system requires several PostgreSQL functions and configuration entries to work properly. These may have been:
- Missing after a database migration
- Deleted accidentally
- Not properly initialized

## Solution
Created migration file: `20260501040000_fix_ad_system_functions_and_config.sql`

### What the Migration Does

1. **Recreates Helper Functions:**
   - `app_config_jsonb()` - Gets JSONB config values with defaults
   - `app_config_bool()` - Gets boolean config values with defaults  
   - `user_can_receive_ads()` - Checks if user should see ads based on subscription

2. **Recreates Main Ad Functions:**
   - `get_sponsored_ad_for_placement()` - Fetches internal/sponsored ads
   - `get_external_ad_for_placement()` - Fetches external ad network ads

3. **Recreates Tracking Functions:**
   - `record_ad_impression()` / `record_external_ad_impression()`
   - `record_ad_click()` / `record_external_ad_click()`
   - `report_ad()` - For reporting inappropriate ads

4. **Ensures Proper Configuration:**
   - Sets `ads.internal.enabled = true` (enables internal ads)
   - Sets all required config keys with proper defaults
   - Includes all placements: home_inline, matches_inline, chats_inline, events_inline, profile_inline
   - Includes all platforms: android, ios, web, windows, macos, linux

5. **Grants Proper Permissions** to authenticated users

## How to Apply the Fix

### Option 1: Using Supabase Dashboard (Recommended)
1. Go to your Supabase project dashboard
2. Navigate to the SQL Editor
3. Copy the contents of `supabase/migrations/20260501040000_fix_ad_system_functions_and_config.sql`
4. Run the SQL

### Option 2: Using Supabase CLI
```bash
supabase db push
```

Or apply just this migration:
```bash
supabase migration up
```

## Admin App Configuration

After applying the migration, use the Admin app to configure ads:

### For Internal (Sponsored) Ads:
1. Go to **Sponsored Ads Dashboard** in the Admin app
2. Ensure "Internal Ads Enabled" toggle is ON
3. Create campaigns with creatives for each placement
4. Set moderation status to "approved"
5. Add translations for headlines, body, CTA, and sponsor name

### For External Ads (AdMob, etc.):
1. Go to **External Ads Dashboard** in the Admin app  
2. Enable "External Ads" toggle
3. Add ad networks (AdMob, Facebook, etc.)
4. Configure ad units for each placement/platform combination

## Testing the Fix

Run this SQL in Supabase SQL Editor to verify the fix:

```sql
-- Check if internal ads are enabled
SELECT public.app_config_bool('ads.internal.enabled', false) as internal_ads_enabled;

-- Test the sponsored ad function (as authenticated user)
SELECT * FROM public.get_sponsored_ad_for_placement('home_inline', 'en', 'android');

-- Check external ads config
SELECT public.app_config_bool('ads.external.enabled', false) as external_ads_enabled;

-- Test external ad function (as authenticated user)  
SELECT * FROM public.get_external_ad_for_placement('home_inline', 'android');
```

## Troubleshooting

If ads still don't display:

1. **Check User Tier**: Only free tier users see ads by default (config: `ads.internal.free_tier_only`)
2. **Check Campaign Status**: Campaigns must be:
   - `is_active = true`
   - `moderation_status = 'approved'`
   - `starts_at <= NOW()`
   - `ends_at IS NULL OR ends_at > NOW()`
3. **Check Translations**: Headlines must have translations for the user's locale
4. **Check Placement**: Placement must be in `ads.internal.allowed_placements` config
5. **Check Platform**: Platform must be in `ads.internal.allowed_platforms` config

## Files Changed
- Created: `supabase/migrations/20260501040000_fix_ad_system_functions_and_config.sql`
