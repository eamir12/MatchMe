# Fix for External Ad Click Tracking Issue

## Problem Summary

The external ad system was creating **orphaned click events** - standalone database rows with `event_type = 'click'` that have no corresponding impression events. This resulted in impossible analytics like "0 impressions, 5 clicks".

### Root Cause

The `record_external_ad_click()` database function was **inserting new rows** instead of **updating existing impression rows** when users clicked on ads.

### Example of Bad Data

From your database (May 2, 2026):
- 10 click events with `event_type = 'click'`
- NO corresponding impression events
- Result: Analytics shows `0 impressions, 10 clicks` (impossible!)

```sql
-- These are orphaned clicks:
idx 623: event_type = 'click', created_at = '2026-05-02 04:01:39'
idx 637: event_type = 'click', created_at = '2026-05-02 07:36:05'
idx 644: event_type = 'click', created_at = '2026-05-02 02:05:11'
...and 7 more
```

### How It Should Work

1. **On impression**: Create row with `event_type = 'impression'`, `click_count = 0`
2. **On click**: UPDATE the same row → `click_count += 1`, `last_clicked_at = NOW()`

## The Fix

Two new migration files have been created:

### 1. Fix the Click Tracking Function
**File**: `supabase/migrations/20260703000000_fix_external_ad_click_tracking.sql`

Changes `record_external_ad_click()` to:
- Find the most recent impression (within 24 hours) for the same user/ad/placement
- Update that impression: increment `click_count`, set `last_clicked_at`
- Only create standalone click if NO matching impression found (edge case)

### 2. Clean Up Existing Bad Data
**File**: `supabase/migrations/20260703000001_cleanup_orphaned_clicks.sql`

- Deletes orphaned click events (`event_type = 'click'` with `click_count = 0`)
- Only removes clicks older than 1 hour (to avoid race conditions)
- Logs cleanup statistics

## How to Apply

### Option 1: Using Supabase CLI (Recommended)

```bash
# Navigate to project directory
cd c:\App\MatchMeGPT5.21\MatchMe4

# Apply migrations
supabase db push

# Or if you want to see the SQL first:
supabase db diff --file supabase/migrations/20260703000000_fix_external_ad_click_tracking.sql
```

### Option 2: Using Supabase Dashboard

1. Go to your Supabase project dashboard
2. Navigate to **SQL Editor**
3. Copy and paste the contents of `20260703000000_fix_external_ad_click_tracking.sql`
4. Click **Run**
5. Repeat for `20260703000001_cleanup_orphaned_clicks.sql`

### Option 3: Manual Execution

```bash
# Connect to your Supabase database
psql "postgresql://postgres:[YOUR-PASSWORD]@[YOUR-PROJECT-REF].supabase.co:5432/postgres"

# Run the migrations
\i supabase/migrations/20260703000000_fix_external_ad_click_tracking.sql
\i supabase/migrations/20260703000001_cleanup_orphaned_clicks.sql
```

## Verification

After applying the migrations, restart your app and check:

### 1. Check the Logs

You should see:
```
✓ [ExternalAds] Skipped 0 invalid cached entries  # No more bad cached data
✓ [ExternalAds] Fetched data: 732 impressions, 63 clicks  # Proper ratio
```

### 2. Verify in Database

```sql
-- Check for remaining orphaned clicks
SELECT COUNT(*) as orphaned_clicks
FROM ad_revenue_events
WHERE event_type = 'click' AND click_count = 0;
-- Should return 0 or very few

-- Check proper click tracking
SELECT 
  event_type,
  COUNT(*) as count,
  SUM(click_count) as total_clicks
FROM ad_revenue_events
WHERE created_at >= NOW() - INTERVAL '7 days'
GROUP BY event_type;
```

### 3. Test Click Tracking

1. Run the app
2. See an external ad (impression tracked)
3. Click the ad (click should update the impression, not create new row)
4. Check database:

```sql
SELECT 
  id,
  event_type,
  click_count,
  last_clicked_at,
  created_at
FROM ad_revenue_events
WHERE user_id = '[YOUR-USER-ID]'
ORDER BY created_at DESC
LIMIT 5;
```

You should see:
- ONE row with `event_type = 'impression'`
- `click_count = 1` (or more if clicked multiple times)
- `last_clicked_at` is set

## Expected Improvements

### Before Fix
```
[ExternalAds] Fetched data: 0 impressions, 5 clicks, CTR: 0.00%
[ExternalAds] Skipping cache of invalid data: 0 impressions, 5 clicks
```

### After Fix
```
[ExternalAds] Fetched data: 732 impressions, 63 clicks, CTR: 8.61%
[ExternalAds] Cached analytics data with key: ...
```

## Technical Details

### Old Behavior (Buggy)
```sql
-- On impression: Create impression row
INSERT INTO ad_revenue_events (..., event_type) VALUES (..., 'impression');

-- On click: Create SEPARATE click row (WRONG!)
INSERT INTO ad_revenue_events (..., event_type) VALUES (..., 'click');
```

### New Behavior (Fixed)
```sql
-- On impression: Create impression row
INSERT INTO ad_revenue_events (..., event_type, click_count) 
VALUES (..., 'impression', 0);

-- On click: UPDATE existing impression (CORRECT!)
UPDATE ad_revenue_events
SET click_count = click_count + 1,
    last_clicked_at = NOW()
WHERE id = [impression_id];
```

### Edge Case Handling

The fix handles edge cases where no impression is found:
- User clicks before impression tracking completes (race condition)
- Impression was deleted/lost
- Click attribution window expired (> 24 hours old)

In these rare cases, it creates a standalone click event BUT sets `click_count = 1` so analytics queries can still count it properly.

## Rollback (If Needed)

If you need to rollback, you can restore the old function:

```sql
-- Restore old behavior (NOT RECOMMENDED - creates orphaned clicks)
CREATE OR REPLACE FUNCTION public.record_external_ad_click(...)
RETURNS uuid AS $$
BEGIN
  INSERT INTO public.ad_revenue_events (..., event_type)
  VALUES (..., 'click');
  RETURN v_id;
END;
$$ LANGUAGE plpgsql;
```

## Questions?

If you encounter any issues:
1. Check Supabase logs for errors
2. Verify migrations were applied successfully
3. Check app logs for "Skipped invalid cached entries"
4. Clear app cache and restart

The validation logic in the Flutter app will continue to prevent caching invalid data, so even if some bad data slips through, it won't persist in the app cache.
