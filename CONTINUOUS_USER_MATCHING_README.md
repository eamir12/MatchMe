# Continuous User Proximity Matching Setup

This document explains how user proximity matching now works continuously in the backend.

## Changes Made

1. **New Database Function**: `perform_continuous_user_matching()`
   - Located in: `supabase/migrations/20251226180000_create_continuous_user_matching_function.sql`
   - Iterates through all visible users with recent locations
   - Calls proximity matching logic for each user based on shared intents and interests

2. **Updated Cron Job**: `supabase/functions/cron-jobs/index.ts`
   - Added `handleContinuousUserMatching()` task
   - Runs the continuous user matching function periodically

## How It Works

- **Reactive matching**: Still works when users update their location (immediate)
- **Continuous matching**: Cron job runs periodically to find proximity matches for all users, regardless of recent movement

## Setup Instructions

### 1. Deploy the database function
The function is deployed via migration when you run database migrations.

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

To test the continuous user matching:
1. Have users logged in, visible, with locations, shared intents, and interests
2. Wait for the cron job to run (or trigger it manually if possible)
3. Check the `matches` table for new matches with `match_type = 'proximity'`

## Benefits

- Users who are stationary but within proximity will eventually get matched
- Complements the reactive location-based matching
- Ensures no potential matches are missed due to lack of movement

## Differences from Event Matching

- User matching is based on proximity and shared interests/intents
- Event matching is based on attending the same events
- Both run continuously via cron jobs