Visibility migration checklist

Goal: Rename `is_visible` → `user_visibility_setting`, add `system_visibility_status`, add `public.is_user_truly_visible` helper, and update all code and RLS to enforce true visibility (online + user setting + system status = 'visible').

Steps:
1. Review and commit migrations in repo (already added):
   - 20260101120000_create_mask_full_name_function.sql
   - 20260101130000_rename_is_visible_to_user_visibility_setting.sql
   - 20260102100000_create_is_user_truly_visible_function.sql

2. Apply migrations to staging DB (in a maintenance window):
   - Run `supabase db push` or apply migrations via CI
   - Verify `user_visibility_setting` column exists and data migrated (old `is_visible` values copied/renamed)

3. Deploy server-side function changes and SQL replacements (already applied in repo). Verify in staging:
   - `perform_continuous_user_matching` and `find_nearby_users` use the new predicate
   - `get_recent_chats`, `get_potential_event_matches` return masked names via `public.mask_full_name`

4. Update RLS policies:
   - Ensure all SELECTs and RPCs that should exclude invisible users use `public.is_user_truly_visible(user_id)` in their policies where appropriate
   - Example: `USERS` row-level ROLE policies may allow `SELECT` only if `public.is_user_truly_visible( id ) = TRUE` for anonymous or restricted roles
   - Add test queries to ensure invisible users are not returned

5. Update Supabase functions/cron/serverless deployments (match-engine, cron-jobs) to use the new column names (already done). Deploy to staging and verify logs.

6. Run integration tests:
   - Execute `supabase/tests/test_is_user_truly_visible.sql` in staging
   - Run app E2E smoke tests to confirm matching and location updates work as expected

7. Monitoring and rollback plan:
   - Monitor `find_nearby_users` counts, matching rates, and dashboards after deployment
   - Keep rollback migration ready that renames `user_visibility_setting` back to `is_visible` if needed

Notes:
- This change must be deployed in coordination with client app releases that rely on `user_visibility_setting` usage for writes to avoid transient mismatches.
- Ensure docs and API refs are updated to reflect new field name and visibility semantics.
