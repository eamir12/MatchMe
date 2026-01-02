# Continuous Event Matching Setup

This document explains how event matching now works continuously in the backend.

## Changes Made

1. **New Database Function**: `perform_continuous_event_matching()`
   - Located in: `create_continuous_event_matching_function.sql`
   - Iterates through all current and future events
   - Calls `perform_event_matching()` for each event

2. **Updated Cron Job**: `supabase/functions/cron-jobs/index.ts`
   - Added `handleContinuousEventMatching()` task
   - Runs the continuous matching function periodically

## How It Works

- **Trigger-based matching**: Still works when users join events (immediate)
- **Continuous matching**: Cron job runs periodically to find matches in all events, regardless of when users joined or their online status

## Setup Instructions

### 1. Deploy the database function
Run the SQL in `create_continuous_event_matching_function.sql` in your Supabase database:
```sql
-- The function is already created with the SQL file
```

### 2. Deploy the updated Edge Function
```bash
supabase functions deploy cron-jobs
```
✅ **Completed**: Function deployed successfully!

### 3. Set up cron schedule in Supabase Dashboard
1. Go to Supabase Dashboard > Edge Functions
2. Find the `cron-jobs` function  
3. Set up a cron schedule (recommended: every 15-30 minutes)
   - Example cron expression: `*/15 * * * *` (every 15 minutes)
   - Or `*/30 * * * *` (every 30 minutes)

## Testing

To test the continuous matching:
1. Create events with attendees who have matching interests and intents
2. Wait for the cron job to run (or trigger it manually if possible)
3. Check the `matches` table for new matches with `match_type = 'event'`

## Benefits

- Event matching happens continuously in the backend
- Independent of user online status or app usage
- Matches are created based on data already in Supabase
- No dependency on user proximity or app activity