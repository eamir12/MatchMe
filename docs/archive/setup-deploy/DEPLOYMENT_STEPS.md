# Deployment Steps - Unified Ad System

## Prerequisites
- Supabase project set up
- Admin app and main app building successfully
- Database access with admin privileges

---

## Step 1: Apply Database Migration

### Option A: Using Supabase CLI
```bash
# Navigate to project root
cd C:\App\MatchMeGPT5.21\MatchMe4

# Apply migration
supabase migration up
```

### Option B: Manual SQL Execution
1. Open Supabase Dashboard
2. Go to SQL Editor
3. Create new query
4. Copy contents of `supabase/migrations/20260423000000_unified_ad_system_config.sql`
5. Execute the query
6. Verify all tables created successfully

### Verify Migration
```sql
-- Check tables exist
SELECT table_name FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name LIKE 'ad_system%';

-- Should return:
-- ad_system_config
-- ad_system_placements
-- ad_system_tiers
-- ad_system_schedules
```

---

## Step 2: Verify Database Setup

### Check Default Configurations
```sql
SELECT system_type, is_enabled FROM public.ad_system_config;

-- Should return:
-- internal | false
-- external | false
```

### Check RLS Policies
```sql
SELECT schemaname, tablename, policyname 
FROM pg_policies 
WHERE tablename LIKE 'ad_system%';

-- Should show admin-only policies for all tables
```

### Check Indexes
```sql
SELECT indexname FROM pg_indexes 
WHERE tablename LIKE 'ad_system%';

-- Should show indexes for performance
```

---

## Step 3: Build and Deploy Admin App

### Build Admin App
```bash
cd matchme_admin

# Get dependencies
flutter pub get

# Build APK (for testing)
flutter build apk --debug

# Or build for release
flutter build apk --release
```

### Deploy Admin App
1. Upload APK to your distribution platform
2. Or run directly on device:
   ```bash
   flutter run -d <device_id>
   ```

### Verify Admin Dashboard
1. Open admin app
2. Navigate to "Sponsored Ads" section
3. Click "Ad System Settings"
4. Verify dashboard loads without errors
5. Test master switch toggle
6. Test system toggles
7. Test save functionality

---

## Step 4: Build and Deploy Main App

### Build Main App
```bash
cd ..

# Get dependencies
flutter pub get

# Build APK (for testing)
flutter build apk --debug

# Or build for release
flutter build apk --release
```

### Deploy Main App
1. Upload APK to your distribution platform
2. Or run directly on device:
   ```bash
   flutter run -d <device_id>
   ```

### Verify Main App
1. Open main app
2. Navigate to home screen
3. Verify no ads show (both systems disabled by default)
4. Open admin app and enable internal ads
5. Return to main app
6. Verify ads appear on home screen

---

## Step 5: Test Configuration Flow

### Test 1: Enable Internal Ads
1. Open admin app
2. Go to Ad System Settings
3. Toggle "Advertising System" ON
4. Toggle "Enable Internal Ads" ON
5. Ensure "Enable External Ads" is OFF
6. Enable "Home Inline" placement
7. Enable "Free" tier
8. Click "Save Settings"
9. Open main app
10. Navigate to home screen
11. Verify internal ads appear

### Test 2: Switch to External Ads
1. Open admin app
2. Go to Ad System Settings
3. Toggle "Enable Internal Ads" OFF
4. Toggle "Enable External Ads" ON
5. Enable "Home Inline" placement
6. Enable "Free" tier
7. Click "Save Settings"
8. Open main app
9. Navigate to home screen
10. Verify external ads appear (or placeholder if no real ads configured)

### Test 3: Disable All Ads
1. Open admin app
2. Go to Ad System Settings
3. Toggle "Advertising System" OFF
4. Click "Save Settings"
5. Open main app
6. Navigate to home screen
7. Verify no ads appear

### Test 4: Placement Configuration
1. Open admin app
2. Go to Ad System Settings
3. Enable Internal Ads
4. Toggle "Home Inline" ON, "Matches Inline" OFF
5. Click "Save Settings"
6. Open main app
7. Verify ads on home screen
8. Navigate to matches screen
9. Verify no ads on matches screen

### Test 5: Tier Configuration
1. Open admin app
2. Go to Ad System Settings
3. Enable Internal Ads
4. Toggle "Free" ON, "Premium" OFF
5. Click "Save Settings"
6. Open main app as free user
7. Verify ads appear
8. (If possible) Switch to premium user
9. Verify ads don't appear

### Test 6: Schedule Configuration
1. Open admin app
2. Go to Ad System Settings
3. Enable Internal Ads
4. Toggle "Schedule" ON
5. Set Start Time to current time + 1 hour
6. Set End Time to current time + 2 hours
7. Click "Save Settings"
8. Open main app
9. Verify no ads appear (outside schedule)
10. Wait for schedule to start
11. Verify ads appear

### Test 7: Rate Limiting
1. Open admin app
2. Go to Ad System Settings
3. Enable Internal Ads
4. Set "Max Impressions Per Session" to 1
5. Set "Min Minutes Between Impressions" to 60
6. Click "Save Settings"
7. Open main app
8. Navigate to home screen
9. Verify first ad appears
10. Scroll to trigger another ad
11. Verify second ad doesn't appear (rate limited)

---

## Step 6: Production Deployment

### Pre-Deployment Checklist
- [ ] All tests pass
- [ ] No console errors
- [ ] Settings persist after app restart
- [ ] Admin changes reflect immediately
- [ ] Database backups created
- [ ] RLS policies verified
- [ ] Performance acceptable
- [ ] Documentation reviewed

### Deployment Steps
1. Create database backup
2. Apply migration to production database
3. Build production APKs
4. Upload to app stores
5. Monitor for issues
6. Collect user feedback

### Post-Deployment Monitoring
- Monitor database performance
- Check for RLS policy violations
- Monitor ad impressions and clicks
- Check for user complaints
- Review error logs

---

## Step 7: Configure Ad Networks (Optional)

### For External Ads

#### AdMob Setup
1. Create AdMob account at https://admob.google.com
2. Create app in AdMob
3. Create ad units for each placement
4. Get ad unit IDs
5. Update `ad_networks` table with AdMob configuration
6. Update `ad_units` table with placement mappings

#### Facebook Ads Setup
1. Create Facebook Ads account
2. Create app in Facebook
3. Create ad placements
4. Get placement IDs
5. Update `ad_networks` table with Facebook configuration
6. Update `ad_units` table with placement mappings

### Update Database
```sql
-- Insert AdMob network
INSERT INTO public.ad_networks (provider, display_name, is_enabled, config)
VALUES (
  'admob',
  'Google AdMob',
  false,
  '{"app_id": "your_app_id"}'::jsonb
);

-- Insert ad units
INSERT INTO public.ad_units (network_id, placement, platform, ad_unit_id, ad_format)
VALUES (
  (SELECT id FROM public.ad_networks WHERE provider = 'admob'),
  'home_inline',
  'android',
  'ca-app-pub-xxxxxxxxxxxxxxxx/yyyyyyyyyy',
  'banner'
);
```

---

## Troubleshooting Deployment

### Migration Fails
- Check Supabase connection
- Verify SQL syntax
- Check for existing tables
- Review error message
- Try manual execution

### Admin Dashboard Doesn't Load
- Check imports in main.dart
- Verify file exists
- Check for syntax errors
- Review console errors
- Rebuild admin app

### Ads Don't Show in Main App
- Check master switch is ON
- Check system is enabled
- Check placement is enabled
- Check tier is enabled
- Check schedule (if enabled)
- Check rate limiting
- Review console logs

### Settings Don't Save
- Check admin user status
- Verify Supabase connection
- Check RLS policies
- Review error messages
- Check database permissions

### Performance Issues
- Check database indexes
- Monitor query performance
- Check for N+1 queries
- Review database logs
- Consider caching

---

## Rollback Plan

### If Issues Occur

#### Option 1: Disable Advertising
```sql
UPDATE public.app_config 
SET value = false 
WHERE key = 'ads.enabled';
```

#### Option 2: Disable System
```sql
UPDATE public.ad_system_config 
SET is_enabled = false 
WHERE system_type IN ('internal', 'external');
```

#### Option 3: Restore from Backup
1. Stop all services
2. Restore database from backup
3. Redeploy previous app version
4. Verify functionality
5. Investigate issue

---

## Verification Checklist

After deployment, verify:

- [ ] Database migration applied successfully
- [ ] All tables created with correct schema
- [ ] RLS policies in place
- [ ] Indexes created
- [ ] Default configurations initialized
- [ ] Admin app builds without errors
- [ ] Admin dashboard loads
- [ ] Master switch works
- [ ] System toggles work
- [ ] Placements configurable
- [ ] Tiers configurable
- [ ] Schedule configurable
- [ ] Rate limiting configurable
- [ ] Save functionality works
- [ ] Main app builds without errors
- [ ] AdSlot widget queries new tables
- [ ] Ads display correctly
- [ ] Settings persist
- [ ] Changes take effect immediately
- [ ] No console errors
- [ ] Performance acceptable

---

## Support

### During Deployment
- Monitor logs closely
- Have rollback plan ready
- Test thoroughly before production
- Have backup database ready

### After Deployment
- Monitor for issues
- Collect user feedback
- Review error logs
- Optimize performance
- Plan future enhancements

---

## Timeline

### Estimated Deployment Time
- Database migration: 5-10 minutes
- Admin app build: 10-15 minutes
- Main app build: 15-20 minutes
- Testing: 30-60 minutes
- Deployment: 10-20 minutes
- **Total: 1-2 hours**

### Recommended Schedule
- Deploy during low-traffic period
- Have team available for monitoring
- Plan for 2-3 hours total
- Have rollback plan ready
- Communicate with users

---

## Success Criteria

Deployment is successful when:
1. ✅ Database migration applied
2. ✅ Admin dashboard accessible
3. ✅ Settings save correctly
4. ✅ Main app displays ads correctly
5. ✅ Changes take effect immediately
6. ✅ No console errors
7. ✅ Performance acceptable
8. ✅ All tests pass
9. ✅ Users report no issues
10. ✅ Monitoring shows normal operation
