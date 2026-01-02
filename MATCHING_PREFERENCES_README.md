# Gender and Age Preferences in Matching Functions

## Overview

The event and proximity matching functions have been updated to respect users' gender and age preferences. This ensures that matches are only created between users who meet each other's preference criteria.

## How It Works

### Data Structure

Gender and age preferences are stored in the `users` table as JSONB columns:

- `gender_preferences`: Map of intent → array of preferred gender keys
  ```json
  {
    "dating": ["male", "female"],
    "friendship": ["male"]
  }
  ```

- `age_preferences`: Map of intent → [min_age, max_age]
  ```json
  {
    "dating": [25, 35],
    "friendship": [20, 40]
  }
  ```

- `strict_gender_age_enforcement`: Boolean flag for strict vs. flexible preference enforcement

### Event Matching (`perform_event_matching`)

For users attending the same event:

1. **Gender Check**: If either user has strict enforcement enabled, checks if their gender preferences include the other user's gender for any shared intent
2. **Age Check**: If either user has strict enforcement enabled, checks if their age preferences include the other user's age for any shared intent
3. **Match Creation**: Only creates matches if preferences are compatible (or if strict enforcement is disabled)

### Proximity Matching (`perform_continuous_user_matching`)

For users in proximity with shared intents:

1. **Per-Intent Checking**: For each shared intent between users, checks both gender and age preferences
2. **Strict Enforcement**: If either user has strict enforcement enabled and preferences don't match for ANY shared intent, no match is created
3. **Flexible Enforcement**: If strict enforcement is disabled, matches can still be created even if some preferences don't align

## Usage

### Running the Migration

Execute the migration script to update your database functions:

```sql
-- Run this in your Supabase SQL editor or via psql
\i update_matching_functions_with_preferences.sql
```

### Testing

You can test the functions by:

1. **Event Matching**: Create event attendees and call `perform_event_matching(event_id)`
2. **Proximity Matching**: Call `perform_continuous_user_matching()` to process proximity matches

### Monitoring

Check the function logs for preference-related decisions:

```
NOTICE: Preferences don't match with strict enforcement, skipping
NOTICE: Creating match between user1 and user2
```

## Configuration

### User Preferences

Users can set preferences through the app's settings screen:

- **Gender Preferences**: Select preferred genders for each intent
- **Age Range**: Set minimum and maximum age preferences for each intent
- **Strict Enforcement**: Toggle to require exact preference matches

### Default Behavior

- If no preferences are set, all matches are allowed
- If preferences exist but strict enforcement is disabled, matches are still created
- If strict enforcement is enabled, only preference-compatible matches are created

### Database Schema Requirements

Ensure your `users` table has these columns:

```sql
ALTER TABLE users ADD COLUMN IF NOT EXISTS gender_preferences JSONB DEFAULT '{}';
ALTER TABLE users ADD COLUMN IF NOT EXISTS age_preferences JSONB DEFAULT '{}';
ALTER TABLE users ADD COLUMN IF NOT EXISTS strict_gender_age_enforcement BOOLEAN DEFAULT FALSE;
```

## Implementation Details

### SQL Syntax Fixes

The original implementation used PostgreSQL `FOR` loops with `SELECT` statements, which caused syntax errors. The corrected version uses `EXISTS` queries with `jsonb_object_keys()` for better performance and correctness:

**Before (Error-prone):**
```sql
FOR intent_key IN SELECT jsonb_object_keys(user_preferences) LOOP
    -- Check preferences
END LOOP;
```

**After (Correct):**
```sql
IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(user_preferences) AS intent_key
    WHERE user_preferences->intent_key ? target_value
) THEN
    -- Match found
END IF;
```

**FOREACH Loop Variables:**
PostgreSQL requires FOREACH loop variables to be declared in the function's DECLARE section:

```sql
DECLARE
    intent TEXT;  -- Must declare loop variable
BEGIN
    FOREACH intent IN ARRAY shared_intents LOOP
        -- Use intent variable
    END LOOP;
END;
```

### Performance Considerations

- Preference checking adds some computational overhead
- The functions are optimized to skip unnecessary checks when possible
- Consider indexing on the preference columns if you have many users

## Testing

### Validation Script

Run the test script to validate function syntax:

```sql
\i test_matching_functions.sql
```

### Manual Testing

1. **Event Matching**: Create event attendees and call `perform_event_matching(event_id)`
2. **Proximity Matching**: Call `perform_continuous_user_matching()` to process proximity matches

## Troubleshooting

### Common Issues

1. **No matches being created**: Check if users have strict enforcement enabled with incompatible preferences
2. **Unexpected matches**: Verify that preference data is correctly stored in the database
3. **Age calculation errors**: Ensure `date_of_birth` is properly set and not null

### Debugging

Add temporary logging to see preference checks:

```sql
-- In perform_continuous_user_matching, add debug logging
RAISE NOTICE 'User % preferences: gender=%, age=%, strict=%',
    user_record.user_id,
    current_user_profile.gender_preferences,
    current_user_profile.age_preferences,
    current_user_profile.strict_gender_age_enforcement;
```