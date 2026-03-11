@echo off
REM Quick test guide for app_config system (Windows)
REM Run these commands in Supabase SQL Editor

echo.
echo ========================================
echo   App Config System - Test Guide
echo ========================================
echo.
echo Please run the following SQL commands in your Supabase SQL Editor:
echo.
echo ----------------------------------------
echo Test 1: Verify table exists
echo ----------------------------------------
echo.
echo SELECT 
echo     COUNT(*) as total_configs,
echo     COUNT(CASE WHEN is_user_configurable THEN 1 END) as user_configurable,
echo     COUNT(DISTINCT category) as categories
echo FROM app_config;
echo.
echo Expected: total_configs ^>= 60
echo.
pause

echo.
echo ----------------------------------------
echo Test 2: List all categories
echo ----------------------------------------
echo.
echo SELECT category, COUNT(*) as count
echo FROM app_config
echo GROUP BY category
echo ORDER BY category;
echo.
echo Expected: 9 categories (cache, calendar, gps, etc.)
echo.
pause

echo.
echo ----------------------------------------
echo Test 3: Read GPS battery threshold
echo ----------------------------------------
echo.
echo SELECT config_value 
echo FROM app_config 
echo WHERE config_key = 'gps.battery_low_threshold_percent';
echo.
echo Expected: 15
echo.
pause

echo.
echo ----------------------------------------
echo Test 4: Check your admin status
echo ----------------------------------------
echo.
echo SELECT id, email, is_admin
echo FROM users
echo WHERE id = auth.uid();
echo.
echo Note: is_admin must be true to modify configs
echo.
pause

echo.
echo ----------------------------------------
echo Test 5: Show user-configurable settings
echo ----------------------------------------
echo.
echo SELECT config_key, config_value, category
echo FROM app_config
echo WHERE is_user_configurable = true
echo ORDER BY category;
echo.
pause

echo.
echo ========================================
echo   Optional: Test Config Update
echo ========================================
echo.
echo To test updating a config (admin only):
echo.
echo UPDATE app_config 
echo SET config_value = '20'
echo WHERE config_key = 'gps.battery_low_threshold_percent';
echo.
echo Then verify:
echo.
echo SELECT config_value 
echo FROM app_config 
echo WHERE config_key = 'gps.battery_low_threshold_percent';
echo.
echo And rollback:
echo.
echo UPDATE app_config 
echo SET config_value = '15'
echo WHERE config_key = 'gps.battery_low_threshold_percent';
echo.
pause

echo.
echo ========================================
echo   Complete Test SQL Script
echo ========================================
echo.
echo Opening test_app_config.sql for full tests...
echo.
echo You can find all test queries in: test_app_config.sql
echo.

if exist test_app_config.sql (
    notepad test_app_config.sql
) else (
    echo File not found: test_app_config.sql
)

echo.
echo ========================================
echo   Quick Flutter App Test
echo ========================================
echo.
echo To test in your Flutter app:
echo.
echo 1. Run: flutter clean
echo 2. Run: flutter pub get
echo 3. Run: flutter run
echo 4. Check logs for: [AppConfig] messages
echo 5. Verify: "Loaded XX configuration entries"
echo.
pause

echo.
echo ========================================
echo   Deployment Checklist
echo ========================================
echo.
echo See DEPLOYMENT_CHECKLIST.md for complete deployment steps
echo.
echo Quick steps:
echo 1. Run create_app_config_table.sql in Supabase
echo 2. Verify with test_app_config.sql queries
echo 3. Test Flutter app initialization
echo 4. Access admin UI (if user is admin)
echo.
echo ✅ All done! Check documentation for next steps.
echo.
pause
