# Event Matching Diagnostic Queries

This folder contains diagnostic queries to troubleshoot why event matching isn't working for your users.

## Important Notes
- **Supabase Limitation**: Supabase SQL Editor doesn't support running multiple SELECT statements in a single execution. Each query must be run separately.
- **User IDs**: All queries are pre-configured with your user IDs:
  - User 1: `35fe114e-eae5-49d6-9eba-8459617e7b82`
  - User 2: `ffc20046-a777-463b-922a-547151aa1455`
- **Event ID**: All queries are pre-configured with your event ID: `6497a84c-6ae6-445b-b3e1-e7acc984b2c5`

## Confirmed Facts
✅ Both users are attending the same event (6497a84c-6ae6-445b-b3e1-e7acc984b2c5)
✅ Event attendance timestamps show they joined at different times

## Step-by-Step Diagnostic Process

### Step 1: Check Function Deployment
Run `query_1_check_function.sql`
- Should return 1 row with `perform_event_matching(UUID)`
- If no results, you need to run `perform_event_matching_complete.sql`

### Step 2: Check Trigger Deployment
Run `query_2_check_trigger.sql`
- Should return 1 row with trigger details
- If no results, you need to run `create_event_matching_trigger.sql`

### Step 3: Check User Settings
Run `query_3_check_users.sql`
- Both users should have `shared_event_matching_enabled = true`
- Both users should have non-empty `active_modes` arrays
- Both users should have interests data

### Step 4: Check Event Attendance (Already Confirmed)
Both users are confirmed attending event `6497a84c-6ae6-445b-b3e1-e7acc984b2c5`
- User 1 joined: 2025-12-23 02:06:45
- User 2 joined: 2025-12-23 02:21:06

### Step 5: Check Event Attendance Details
Run `query_5_check_attendance.sql`
- Should show both users attending with their settings

### Step 6: Manual Function Test
Run `query_6_manual_trigger.sql`
- This manually triggers matching for the event

### Step 7: Check for Matches
Run `query_7_check_matches.sql`
- Should show any matches created for the event

## Expected Results

For matching to work, all of these must be true:
1. ✅ Function deployed
2. ✅ Trigger deployed
3. ✅ Both users have `shared_event_matching_enabled = true`
4. ✅ Both users have at least one shared intent in `active_modes`
5. ✅ Both users have at least one shared interest in the same category
6. ✅ Both users are attending the same event (6497a84c-6ae6-445b-b3e1-e7acc984b2c5) ✅

## Troubleshooting

### If matches still don't appear:
- Check that the interests are stored correctly (JSONB structure)
- Verify the `active_modes` contain matching values
- Ensure the event is current/future (not past)
- Check Supabase function logs for errors

### If trigger doesn't work:
- The trigger only runs on NEW event attendance
- Existing attendees need manual triggering or periodic sync

## Alternative: Use Combined Diagnostic
If you prefer, you can use `comprehensive_event_matching_diagnostic.sql` but run each "QUERY X" section separately in Supabase.