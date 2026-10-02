# Real-time Admin Dashboard Update on User Logout

## Problem
When a user logs off from the regular app, the online users count in the admin dashboard was not updating immediately. The admin had to manually refresh the page to see the updated count.

## Root Cause
The logout flow was correctly calling `set_user_offline()` RPC to mark the user as offline in the `user_activity` table, but the admin dashboard's realtime subscription was not listening to changes in the `user_activity` table. It was only listening to the `admin_dashboard_tick` table.

## Solution
Added a database trigger that automatically updates the `admin_dashboard_tick` table whenever the `user_activity` table changes. This ensures the admin dashboard's realtime subscription receives the update immediately.

## Implementation Details

### Migration File
**File:** `supabase/migrations/20260501100000_add_user_activity_realtime_trigger.sql`

Creates a trigger on the `user_activity` table that calls `touch_admin_dashboard_tick()` whenever:
- A user activity record is inserted
- A user activity record is updated
- A user activity record is deleted

### How It Works

1. **User Logs Off** (Regular App)
   - User taps logout button in `lib/screens/main_navigation_screen.dart`
   - `supabase.auth.signOut()` is called
   - Auth state listener in `visibility_provider.dart` detects logout
   - `set_user_offline(userId)` RPC is called

2. **Database Updates**
   - `set_user_offline()` function updates `user_activity` table:
     - Sets `is_online = false`
     - Updates `updated_at = NOW()`
   - **NEW:** Trigger `trg_touch_admin_dashboard_tick_user_activity` fires
   - Trigger calls `touch_admin_dashboard_tick()` function
   - `admin_dashboard_tick` table is updated with new timestamp

3. **Admin Dashboard Updates**
   - Admin dashboard has realtime subscription to `admin_dashboard_tick` table
   - Receives PostgresChangePayload when `admin_dashboard_tick` is updated
   - Calls `_scheduleReload()` to refresh dashboard metrics
   - Online users count is recalculated from `user_activity` table
   - Admin sees updated count immediately (within ~800ms debounce)

### Database Functions Involved

**`set_user_offline(p_user_id uuid)`**
- Located in: `supabase/migrations/20260220000000_improve_user_status_handling.sql`
- Updates `user_activity` table to mark user offline
- Gracefully handles deleted users

**`touch_admin_dashboard_tick()`**
- Located in: `supabase/migrations/20260225093500_admin_dashboard_tick_realtime.sql`
- Updates `admin_dashboard_tick.updated_at = now()`
- Triggers realtime notification to subscribed clients

**`get_online_users_count(p_user_id uuid)`**
- Located in: `supabase/migrations/20260414000000_increase_online_count_window.sql`
- Returns count of users with `is_online = true` and `last_activity > NOW() - 2 minutes`
- Used by admin dashboard to display online users metric

### Realtime Flow

```
User Logout
    ↓
set_user_offline() RPC
    ↓
user_activity table UPDATE
    ↓
trg_touch_admin_dashboard_tick_user_activity trigger fires
    ↓
touch_admin_dashboard_tick() function
    ↓
admin_dashboard_tick table UPDATE
    ↓
Realtime subscription notifies admin dashboard
    ↓
_scheduleReload() called (800ms debounce)
    ↓
get_online_users_count() recalculated
    ↓
Admin sees updated online users count
```

## Testing

To verify the implementation:

1. **Deploy the migration** to your Supabase project
2. **Log in to the regular app** as a test user
3. **Open the admin dashboard** in another browser/device
4. **Verify the user appears** in the online users count
5. **Log off from the regular app**
6. **Observe the admin dashboard** - the online users count should decrease within ~1 second

## Performance Considerations

- **Trigger Type:** STATEMENT-level trigger (fires once per statement, not per row)
- **Frequency:** Only fires when `user_activity` changes (not on every heartbeat)
- **Debounce:** Admin dashboard has 800ms debounce to prevent excessive reloads
- **Impact:** Minimal - only updates a single row in `admin_dashboard_tick` table

## Related Code

### Logout Flow
- `lib/screens/main_navigation_screen.dart` (lines 623-651) - Logout button handler
- `lib/providers/visibility_provider.dart` (lines 1080-1087) - Auth state listener

### Admin Dashboard
- `matchme_admin/lib/main.dart` (lines 2122-2280) - Realtime subscription setup
- `matchme_admin/lib/main.dart` (lines 2851-2884) - Online users display

### Background Service
- `lib/services/background_service.dart` (lines 372-379) - Calls `set_user_offline` on stop
- `lib/services/background_service.dart` (lines 721-727) - Calls `set_user_offline` on connectivity loss

### Web App
- `lib/main.dart` (lines 2452-2464) - Uses beacon API for offline logout
- `lib/main.dart` (lines 2733-2737) - Calls `set_user_offline` on page detach
