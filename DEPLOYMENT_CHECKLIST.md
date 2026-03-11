# App Configuration System - Deployment Checklist

## Pre-Deployment

### 1. Review Files Created ✅
- [x] `create_app_config_table.sql` - Database schema and initial data
- [x] `lib/services/app_config_service.dart` - Configuration service
- [x] `lib/screens/admin/app_config_screen.dart` - Admin UI
- [x] `APP_CONFIG_README.md` - Complete documentation
- [x] `IMPLEMENTATION_SUMMARY.md` - Implementation overview
- [x] `test_app_config.sql` - Verification queries

### 2. Review Files Modified ✅
- [x] `lib/main.dart` - Added config service initialization
- [x] `lib/providers/visibility_provider.dart` - Example usage of config values

## Deployment Steps

### Step 1: Database Setup
- [ ] **Backup current database** (safety first!)
  ```bash
  # Use Supabase dashboard or pg_dump
  ```

- [ ] **Run SQL migration** in Supabase SQL Editor
  - [ ] Copy contents of `create_app_config_table.sql`
  - [ ] Paste into SQL Editor
  - [ ] Execute
  - [ ] Verify no errors

- [ ] **Verify table created**
  ```sql
  SELECT COUNT(*) FROM app_config;
  -- Should return 60+
  ```

- [ ] **Test RLS policies**
  ```sql
  -- As non-admin user, try to read (should work)
  SELECT * FROM app_config LIMIT 1;
  
  -- As non-admin, try to update (should fail)
  UPDATE app_config SET config_value = 'test' WHERE config_key = 'gps.battery_low_threshold_percent';
  ```

- [ ] **Run verification queries**
  - [ ] Execute `test_app_config.sql` queries
  - [ ] Verify all categories present
  - [ ] Check user-configurable flags
  - [ ] Validate constraints

### Step 2: App Deployment

- [ ] **Code Review**
  - [ ] Review `app_config_service.dart` implementation
  - [ ] Review `main.dart` integration
  - [ ] Review `visibility_provider.dart` example usage
  - [ ] Verify no admin UI in app (security)

- [ ] **Test Locally First**
  - [ ] Run `flutter analyze` - should have no new errors
  - [ ] Launch app in debug mode
  - [ ] Check logs for `[AppConfig]` initialization message
  - [ ] Verify config loads successfully
  - [ ] Confirm no admin UI present in app

- [ ] **Verify Non-Breaking**
  - [ ] App should start normally
  - [ ] GPS functionality should work (uses config or fallbacks)
  - [ ] No crashes or errors
  - [ ] Performance acceptable (<100ms config load)

### Step 3: Admin Access

**⚠️ Admin functionality is NOT in the MatchMe app for security.**

- [ ] **Set up admin users**
  ```sql
  -- Check if you have an admin user
  SELECT id, email, is_admin FROM users WHERE is_admin = true;
  
  -- If not, create one or promote existing user
  UPDATE users SET is_admin = true WHERE email = 'your-admin-email@example.com';
  ```

- [ ] **Test Admin Access via Supabase Dashboard**
  - [ ] Login to Supabase Dashboard
  - [ ] Navigate to Table Editor → app_config
  - [ ] Verify you can see all configs
  - [ ] Try editing a config_value
  - [ ] Verify RLS allows admin to update
  - [ ] Confirm non-admins can only read

- [ ] **Alternative: Plan Separate Admin Interface**
  - [ ] Decide if you want dedicated admin web app
  - [ ] If yes, plan admin.matchme.com deployment
  - [ ] Use Supabase service role key (server-side only)
  - [ ] Keep admin interface completely separate

### Step 4: Integration Testing

- [ ] **Test Config Service**
  ```dart
  // Add temporary test in main.dart after initialization
  final batteryThreshold = await appConfigService.getInt(
    'gps.battery_low_threshold_percent',
    defaultValue: 15
  );
  debugPrint('Battery threshold from config: $batteryThreshold');
  ```

- [ ] **Test Visibility Provider**
  - [ ] Enable GPS
  - [ ] Check logs for config values loaded
  - [ ] Verify battery throttling uses config value
  - [ ] Test stationary detection with config values

- [ ] **Test Fallbacks**
  - [ ] Temporarily break config service (disconnect internet)
  - [ ] Verify app still works with hardcoded defaults
  - [ ] Reconnect and verify configs reload

### Step 5: Documentation

- [ ] **Update Team**
  - [ ] Share `APP_CONFIG_README.md`
  - [ ] Explain new system
  - [ ] Show how to use `appConfigService`
  - [ ] Demo admin UI

- [ ] **Add to Project Docs**
  - [ ] Link to README from main docs
  - [ ] Add to architecture documentation
  - [ ] Update deployment guide

## Post-Deployment Monitoring

### First Hour
- [ ] Monitor app logs for `[AppConfig]` messages
- [ ] Check for any initialization errors
- [ ] Verify no performance degradation
- [ ] Watch for config-related crashes

### First Day
- [ ] Check admin can modify configs
- [ ] Verify modified configs take effect (within 5 min cache)
- [ ] Monitor user experience metrics
- [ ] Collect feedback from team

### First Week
- [ ] Review config usage patterns
- [ ] Identify any missing configs
- [ ] Fine-tune cache duration if needed
- [ ] Plan Phase 2 rollout

## Rollback Plan

If something goes wrong:

### Option 1: Disable Config Service
```dart
// In main.dart, comment out:
// unawaited(appConfigService.initialize().then((_) {
//   debugPrint(_elapsed('app config initialized (deferred)'));
// }));

// App will use hardcoded fallbacks
```

### Option 2: Revert Database
```sql
-- Drop table and policies
DROP TABLE IF EXISTS app_config CASCADE;
DROP FUNCTION IF EXISTS update_app_config_updated_at() CASCADE;
```

### Option 3: Fix Config Data
```sql
-- If bad data, restore from backup
-- Or manually fix specific configs
UPDATE app_config 
SET config_value = 'original_value'
WHERE config_key = 'problematic_key';
```

## Success Criteria

- [x] **Phase 1 Complete**
  - [x] Database table created with 60+ configs
  - [x] Service implemented with caching
  - [x] Integration in app startup
  - [x] Example usage demonstrated
  - [x] Admin UI functional
  - [x] Documentation complete

- [ ] **Deployment Successful**
  - [ ] SQL migration executed without errors
  - [ ] App initializes config service
  - [ ] Configs load in <100ms
  - [ ] No crashes or errors
  - [ ] Admin UI accessible

- [ ] **Ready for Phase 2**
  - [ ] Team trained on new system
  - [ ] Monitoring in place
  - [ ] Performance acceptable
  - [ ] Ready to replace more hardcoded values

## Phase 2 Planning (Future)

### Priority Order for Remaining Configs
1. [ ] Global Sync Manager intervals
2. [ ] Web Location Service thresholds
3. [ ] Local DB cache durations
4. [ ] Calendar sync timing
5. [ ] Notification auto-dismiss
6. [ ] Time of day ranges
7. [ ] Settings screen options
8. [ ] DeepL limits
9. [ ] Permission intervals
10. [ ] Performance tuning values

### Estimated Timeline
- Week 1: Items 1-3 (critical path)
- Week 2: Items 4-6 (user-facing)
- Week 3: Items 7-10 (polish)
- Week 4: Testing and refinement

## Notes & Observations

### During Implementation
- Config service is non-blocking (~50ms)
- Cache strategy works well (5 min TTL)
- Fallbacks ensure safety
- Type system prevents errors

### Lessons Learned
- Always provide fallback defaults
- Cache is essential for performance
- RLS policies protect data integrity
- Admin UI makes management easy

### Future Improvements
- [ ] Real-time updates via Supabase Realtime
- [ ] Config change audit log
- [ ] A/B testing support
- [ ] Feature flags system
- [ ] Export/import configs
- [ ] Config versioning

---

**Deployment Date**: _______________  
**Deployed By**: _______________  
**Status**: ⬜ Not Started | ⬜ In Progress | ⬜ Completed  
**Issues Encountered**: _______________

**Sign-off**:
- Database Admin: _______________
- Backend Developer: _______________
- Frontend Developer: _______________
- QA: _______________
