# Deployment Instructions for Security Fixes

## Quick Start

These migration files fix all database-level security issues identified by Supabase's database linter.

### Option 1: Using Supabase CLI (Recommended)

```bash
# Navigate to project root
cd /path/to/MatchMe4

# Verify migrations exist
ls supabase/migrations/20260506*.sql

# Push migrations to your Supabase project
supabase db push

# Verify deployment
supabase db pull  # Should show latest schema
```

### Option 2: Manual Deployment via Supabase Console

1. **Go to SQL Editor in Supabase Console**
   - https://supabase.com/dashboard/project/[YOUR_PROJECT_ID]/sql/new

2. **Create new query for each migration file (in order):**
   
   a. `20260506200000_comprehensive_security_advisor_fixes.sql`
      - Copy entire file content
      - Run
      - Verify: "Success" message
   
   b. `20260506201000_fix_critical_admin_update_promo_codes_config.sql`
      - Copy entire file content
      - Run
      - Verify: "Success" message
   
   c. `20260506202000_revoke_admin_functions_from_authenticated.sql`
      - Copy entire file content
      - Run
      - Verify: "Success" message (may show ~40 REVOKE statements)
   
   d. `20260506204000_grant_admin_functions_to_service_role.sql`
      - Copy entire file content
      - Run
      - Verify: "Success" message (may show ~35 GRANT statements)

3. **Test that database works**
   - Run: `SELECT 1;` → Should return 1
   - Run: `SELECT COUNT(*) FROM users;` → Should return user count

### Option 3: Via Admin Application

If you have an admin dashboard:
1. Go to Settings → Database → Migrations
2. Upload/deploy the migration files
3. Monitor deployment status
4. Verify no errors

---

## Testing After Deployment

### Test 1: Verify Authenticated Access Revoked

```sql
-- Login as regular authenticated user
-- Run this - should fail with permission denied:
SELECT * FROM ad_campaigns LIMIT 1;

-- Expected error: "permission denied for schema public"
-- This is SUCCESS - the security fix is working!
```

### Test 2: Verify Admin Functions Protected

```sql
-- Login as regular authenticated user
-- Try to call an admin function - should fail:
SELECT admin_get_dashboard_stats('day');

-- Expected error: "permission denied for function"
-- This is SUCCESS!
```

### Test 3: Verify Admin Functionality Works

```sql
-- Login as admin user (is_admin = true)
-- This should work:
SELECT admin_get_dashboard_stats('day');

-- Expected: Returns JSON with dashboard data
-- If error: Check user has is_admin = true

-- Verify user is admin:
SELECT id, email, is_admin FROM users WHERE id = auth.uid();
-- Should show is_admin = true
```

### Test 4: Verify Non-Admin Gets Rejected

```sql
-- Verify the admin check works:
-- Login as non-admin user
-- Try: SELECT admin_get_promo_usage_stats(NULL);
-- Expected error: "not authorized"
```

---

## Rollback (If Needed)

If you need to rollback these changes:

```bash
# Using Supabase CLI
supabase db push --dry-run  # See what would happen

# Then manually undo:
# GRANT SELECT ON TABLE public.ad_campaigns TO authenticated;
# GRANT EXECUTE ON FUNCTION admin_* TO authenticated;
```

---

## Production Deployment Checklist

- [ ] Test migrations in development environment first
- [ ] Verify all migration files are present in `supabase/migrations/`
- [ ] Create backup of current database: `supabase db dump > backup.sql`
- [ ] Run migrations: `supabase db push`
- [ ] Verify no errors in deployment
- [ ] Test with admin user: Functions should work
- [ ] Test with regular user: Functions should fail gracefully
- [ ] Monitor logs for any issues for 24 hours
- [ ] Document deployment timestamp and status
- [ ] Manual action: Enable leaked password protection in Supabase Console
- [ ] Update security documentation

---

## Post-Deployment Actions

### REQUIRED: Enable Leaked Password Protection

⚠️ **This cannot be automated - must be done manually via Supabase Dashboard**

1. Go to: https://supabase.com/dashboard
2. Select your project
3. Navigate to: **Authentication** → **Password & Email**
4. Find "Leaked Password Protection" or "Breach Detection"
5. Toggle it **ON**
6. Verify: Status should show "Enabled"

See `SUPABASE_SECURITY_ADVISOR_FIXES.md` for detailed instructions.

---

## Monitoring

After deployment, monitor:

```sql
-- Check for any errors in recent logs
SELECT * FROM pg_stat_statements 
WHERE query LIKE '%admin_%' 
ORDER BY calls DESC;

-- Monitor function execution
SELECT function_name, call_count, error_count 
FROM function_stats 
WHERE function_name LIKE 'admin_%' 
ORDER BY call_count DESC;
```

---

## Troubleshooting

### Issue: "permission denied" when running SELECT on users table
**Solution:** This is expected! Admin functions need proper access. Verify:
- User has `is_admin = true`
- Using correct authentication token
- Function is being called via REST API or SQL client with proper auth

### Issue: Admin function returns "not authorized"
**Solution:** Check:
```sql
SELECT is_admin FROM users WHERE id = auth.uid();
-- Should return true
```

### Issue: Migrations failed to apply
**Solution:**
1. Check migration syntax for errors
2. Verify Supabase project is healthy
3. Try running migrations individually
4. Check logs: Supabase Dashboard → Logs → Functions

### Issue: Breaking existing admin application
**Solution:**
- Ensure admin app uses tokens with admin users (is_admin = true)
- Use Supabase client library with proper auth
- May need to update function calls if app expects different behavior

---

## Questions?

Refer to:
- `SUPABASE_SECURITY_ADVISOR_FIXES.md` - Full security documentation
- Individual migration files - Detailed comments on each fix
- Supabase Docs: https://supabase.com/docs/guides/database/database-linter

---

**Deployment Status: Ready ✅**
**Last Tested:** 2026-05-06
**Version:** 1.0
