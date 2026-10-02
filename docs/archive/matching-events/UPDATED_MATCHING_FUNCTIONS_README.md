# Updated Matching Functions with Preferences - Deployment Guide

## Overview
This update adds gender and age preference checking to both the event matching and continuous user matching functions. The functions now respect user preferences when creating matches, with support for strict enforcement.

## Files Updated
- `update_matching_functions_with_preferences.sql` - Main migration script
- `test_updated_matching_functions.sql` - Validation test script

## Key Changes

### 1. Function Updates
- **perform_event_matching(p_event_id UUID)**: Now checks gender and age preferences before creating event-based matches
- **perform_continuous_user_matching()**: Now checks gender and age preferences before creating proximity-based matches

### 2. Preference Logic
- **Gender Preferences**: JSONB object with intent-specific gender preferences (e.g., `{"dating": ["male", "female"], "friendship": ["male"]}`)
- **Age Preferences**: JSONB object with intent-specific age ranges (e.g., `{"dating": [25, 35], "friendship": [20, 40]}`)
- **Strict Enforcement**: Boolean flag that requires ALL intents to match preferences vs ANY intent

### 3. Supabase Compatibility
- Functions use `SECURITY DEFINER` with `SET search_path = public` in headers
- Proper permission grants for authenticated and anonymous users
- PostgreSQL-compatible syntax throughout

## Database Schema Requirements

The `users` table must have these columns:
```sql
ALTER TABLE users ADD COLUMN IF NOT EXISTS gender_preferences JSONB;
ALTER TABLE users ADD COLUMN IF NOT EXISTS age_preferences JSONB;
ALTER TABLE users ADD COLUMN IF NOT EXISTS strict_gender_age_enforcement BOOLEAN DEFAULT FALSE;
```

## Deployment Steps

### 1. Run Migration Script
In Supabase SQL Editor, execute:
```sql
-- Run the migration script
\i update_matching_functions_with_preferences.sql
```

### 2. Validate Deployment
Run the test script:
```sql
\i test_updated_matching_functions.sql
```

### 3. Check Results
The test script will:
- Verify functions exist and are accessible
- Test error handling with invalid parameters
- Validate database schema
- Show preference data statistics

## Function Behavior

### Event Matching
- Processes all attendees of an event
- Checks preferences between each pair
- Creates matches only when preferences are compatible
- Uses shared interests as additional matching criteria

### Continuous User Matching
- Processes users with recent location updates
- Finds nearby users within match radius
- Checks preferences for each shared intent
- Creates proximity-based matches when compatible

## Preference Checking Logic

For each potential match:
1. Check if either user has strict enforcement enabled
2. For each shared intent:
   - Check gender preferences (if set)
   - Check age preferences (if set)
3. If strict enforcement: ALL intents must match
4. If not strict: ANY intent can match
5. Skip match creation if preferences incompatible

## Troubleshooting

### Common Issues
- **Function not found**: Ensure migration script ran successfully
- **Permission denied**: Check that grants were applied
- **Syntax errors**: Verify PostgreSQL version compatibility

### Validation Queries
```sql
-- Check function exists
SELECT proname FROM pg_proc WHERE proname = 'perform_event_matching';

-- Check permissions
SELECT * FROM information_schema.role_routine_grants
WHERE routine_name IN ('perform_event_matching', 'perform_continuous_user_matching');
```

## Rollback
If needed, the original functions can be restored from backup files:
- `create_perform_event_matching_function.sql`
- `create_continuous_user_matching_function.sql`

## Testing
After deployment, test with:
1. Users setting different preference combinations
2. Running matching functions manually
3. Verifying matches respect preferences
4. Checking logs for preference filtering messages