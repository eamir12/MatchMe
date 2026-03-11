#!/bin/bash
# Quick test script for app_config system
# Run this after deploying the SQL migration

echo "🧪 Testing App Config System..."
echo ""

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo "❌ psql not found. Please install PostgreSQL client tools."
    echo "Or run these commands directly in Supabase SQL Editor"
    exit 1
fi

echo "📋 Note: You can also run these tests in Supabase SQL Editor"
echo ""

# You'll need to set these environment variables or pass them as arguments
# SUPABASE_DB_HOST, SUPABASE_DB_USER, SUPABASE_DB_PASSWORD, SUPABASE_DB_NAME

read -p "Enter Supabase DB host (or press Enter to use psql connection string): " DB_HOST

if [ -z "$DB_HOST" ]; then
    echo ""
    echo "Please run the following commands in your Supabase SQL Editor:"
    echo ""
    cat << 'EOF'
-- Test 1: Verify table exists and has data
SELECT 
    COUNT(*) as total_configs,
    COUNT(CASE WHEN is_user_configurable THEN 1 END) as user_configurable,
    COUNT(DISTINCT category) as categories
FROM app_config;

-- Expected: total_configs >= 60, user_configurable >= 5, categories = 9

-- Test 2: Verify all categories present
SELECT category, COUNT(*) as count
FROM app_config
GROUP BY category
ORDER BY category;

-- Expected categories: cache, calendar, gps, notification, performance, profile, sync, translation, ui

-- Test 3: Test a specific config read
SELECT config_value FROM app_config WHERE config_key = 'gps.battery_low_threshold_percent';

-- Expected: 15

-- Test 4: Test RLS - this should work for any user
SELECT config_key, config_value FROM app_config LIMIT 3;

-- Expected: 3 rows returned

-- Test 5: Verify constraints
SELECT 
    config_key,
    config_value,
    min_value,
    max_value
FROM app_config
WHERE min_value IS NOT NULL OR max_value IS NOT NULL
LIMIT 5;

-- Expected: Rows with min/max values defined

-- Test 6: Check if you're admin (needed for updates)
SELECT 
    id,
    email,
    is_admin
FROM users
WHERE id = auth.uid();

-- If is_admin = true, you can modify configs
-- If false or null, UPDATE will fail (expected behavior)

-- Test 7: Try updating a config (only works if admin)
-- Uncomment to test:
-- UPDATE app_config 
-- SET config_value = '20'
-- WHERE config_key = 'gps.battery_low_threshold_percent';

-- Test 8: Verify the update worked
-- SELECT config_value FROM app_config WHERE config_key = 'gps.battery_low_threshold_percent';
-- Expected: 20 (if you ran the update)

-- Test 9: Rollback the test update
-- UPDATE app_config 
-- SET config_value = '15'
-- WHERE config_key = 'gps.battery_low_threshold_percent';

EOF
    echo ""
    exit 0
fi

# If user provided host, attempt to run tests
# This is a basic example - adjust connection parameters as needed
echo "Running tests against $DB_HOST..."

# Test commands would go here
# psql -h $DB_HOST -U postgres -d postgres -c "SELECT COUNT(*) FROM app_config;"

echo "✅ See commands above to run in Supabase SQL Editor"
