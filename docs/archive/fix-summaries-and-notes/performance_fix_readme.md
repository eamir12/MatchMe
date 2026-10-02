# Supabase Performance Advisor Fixes

This document explains the fixes applied to resolve performance issues identified by the Supabase Performance Advisor.

## Issues Fixed

### 1. auth_rls_initplan
**Problem**: `auth.<function>()` calls in RLS policies are re-evaluated for each row, causing poor performance at scale.

**Solution**: Wrap `auth.<function>()` calls in subqueries: `(select auth.<function>())`

**Impact**: Auth functions are evaluated once per query instead of once per row.

### 2. multiple_permissive_policies
**Problem**: Multiple permissive policies for the same role and action are executed for every relevant query.

**Solution**: Consolidate multiple policies into single policies where possible.

**Impact**: Reduces the number of policy evaluations per query.

### 3. duplicate_index
**Problem**: Identical indexes exist on the same columns.

**Solution**: Drop duplicate indexes, keeping only one.

**Impact**: Reduces storage and maintenance overhead.

## Files

- `performance_rls_fix.sql` - Main fix script
- `performance_fix_readme.md` - This documentation

## How to Apply

1. **Backup your database** before running any changes
2. Run the `performance_rls_fix.sql` script in your Supabase SQL Editor
3. Verify your application still works correctly
4. Check the Performance Advisor to confirm issues are resolved

## Rollback

If issues occur, you can rollback by:
1. Restoring from your database backup
2. Or manually recreating the original policies (see backup script comments)

## Verification

After applying fixes, check:

```sql
-- Check policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- Check indexes
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- Check performance advisor
SELECT name, title, level, categories, description
FROM performance_advisor
WHERE level = 'WARN'
ORDER BY name;
```

## Tables Affected

- users
- user_profiles
- events
- event_attendees
- matches
- chat_messages
- profile_edit_requests
- user_invisibility_rules
- user_visibility_schedules
- user_locations
- intents
- interests
- user_intents
- user_interests
- user_profiles_backup
- translations (indexes only)

## Security Notes

- All fixes maintain the same security logic as the original policies
- User data access restrictions remain unchanged
- Only performance optimizations were applied