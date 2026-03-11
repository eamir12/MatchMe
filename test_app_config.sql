-- Quick verification and test queries for app_config table

-- 1. Verify table exists and has data
SELECT 
    COUNT(*) as total_configs,
    COUNT(CASE WHEN is_user_configurable THEN 1 END) as user_configurable,
    COUNT(DISTINCT category) as categories
FROM app_config;

-- 2. List all categories with counts
SELECT 
    category,
    COUNT(*) as config_count
FROM app_config
GROUP BY category
ORDER BY category;

-- 3. Show all GPS configs
SELECT 
    config_key,
    config_value,
    config_type,
    is_user_configurable,
    description
FROM app_config
WHERE category = 'gps'
ORDER BY config_key;

-- 4. Show user-configurable settings
SELECT 
    config_key,
    config_value,
    category,
    description
FROM app_config
WHERE is_user_configurable = true
ORDER BY category, config_key;

-- 5. Test reading a specific config (as the app would)
SELECT config_value 
FROM app_config 
WHERE config_key = 'gps.battery_low_threshold_percent';

-- 6. Test updating a config (admin only)
-- UPDATE app_config 
-- SET config_value = '20'
-- WHERE config_key = 'gps.battery_low_threshold_percent';

-- 7. Show configs with validation constraints
SELECT 
    config_key,
    config_value,
    min_value,
    max_value,
    allowed_values
FROM app_config
WHERE min_value IS NOT NULL OR max_value IS NOT NULL OR allowed_values IS NOT NULL
ORDER BY category, config_key;

-- 8. Check RLS policies
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM pg_policies
WHERE tablename = 'app_config';

-- 9. Show recently updated configs
SELECT 
    config_key,
    config_value,
    category,
    updated_at
FROM app_config
ORDER BY updated_at DESC
LIMIT 10;

-- 10. Export all configs as JSON (for backup)
SELECT json_agg(
    json_build_object(
        'key', config_key,
        'value', config_value,
        'type', config_type,
        'category', category,
        'description', description,
        'user_configurable', is_user_configurable,
        'min_value', min_value,
        'max_value', max_value,
        'allowed_values', allowed_values
    )
) as all_configs
FROM app_config;

-- 11. Find configs by keyword search
-- Example: Find all configs related to 'battery'
SELECT 
    config_key,
    config_value,
    description
FROM app_config
WHERE 
    config_key ILIKE '%battery%' 
    OR description ILIKE '%battery%'
ORDER BY config_key;

-- 12. Show sync-related timings
SELECT 
    config_key,
    config_value,
    description
FROM app_config
WHERE category IN ('sync', 'cache', 'ui')
    AND config_type = 'duration_seconds'
ORDER BY CAST(config_value AS INTEGER);

-- 13. Validation check - find configs with invalid ranges
SELECT 
    config_key,
    config_value,
    min_value,
    max_value,
    CASE 
        WHEN min_value IS NOT NULL AND CAST(config_value AS NUMERIC) < min_value THEN 'Below minimum'
        WHEN max_value IS NOT NULL AND CAST(config_value AS NUMERIC) > max_value THEN 'Above maximum'
        ELSE 'OK'
    END as validation_status
FROM app_config
WHERE 
    config_type IN ('number', 'duration_seconds', 'percentage')
    AND (min_value IS NOT NULL OR max_value IS NOT NULL)
HAVING validation_status != 'OK';

-- 14. Show all notification settings
SELECT 
    config_key,
    config_value,
    description
FROM app_config
WHERE category = 'notification'
ORDER BY config_key;

-- 15. Test admin access (should succeed if user is admin)
-- SELECT current_setting('request.jwt.claims', true)::json->>'sub' as user_id;
-- This shows your current user ID - must be admin to modify configs
