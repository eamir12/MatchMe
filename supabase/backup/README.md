# Supabase Database Backup - December 25, 2025

This directory contains backups of your Supabase database created using the Supabase CLI.

## Backup Files

### full_backup.sql (60,329 bytes)
- **Type**: Complete database dump
- **Contents**: Schema (tables, functions, triggers, etc.) + data
- **INSERT statements**: 34
- **CREATE statements**: 136
- **Use case**: Complete restoration of your database

### data_only_backup.sql (395,071 bytes)
- **Type**: Data-only dump
- **Contents**: Primarily data records (with some schema setup)
- **INSERT statements**: 21
- **Note**: Contains warnings about circular foreign key constraints
- **Use case**: Restoring data to an existing schema

## How to Restore

### Option 1: Using Supabase CLI (Recommended)
```bash
# To restore the full backup (schema + data)
supabase db reset --linked
# Then apply the backup file through your migration system

# Or use psql directly
psql "your-connection-string" < full_backup.sql
```

### Option 2: Using psql directly
```bash
psql "postgresql://[username]:[password]@[host]:[port]/[database]" < full_backup.sql
```

## Important Notes

1. **Circular Foreign Keys**: The data_only_backup.sql contains warnings about circular foreign key constraints on the `intents` and `interests` tables. You may need to use `--disable-triggers` when restoring.

2. **Free Tier Limitations**: As a free tier user, you cannot use Supabase's built-in backup/restore features. These local files are your backup.

3. **Security**: Keep these backup files secure as they contain your database structure and data.

4. **Version**: These backups were created from your Supabase database on December 25, 2025.

## Verification

To verify the backup integrity, you can:
1. Check file sizes (should match above)
2. Look for expected tables/functions in the SQL files
3. Test restore on a local Supabase instance first

## Contact

If you need help restoring these backups, refer to the Supabase documentation or seek assistance from the Supabase community.