# Supabase Database Backup Guide

This guide explains how to backup your entire Supabase database to local files.

## Prerequisites

1. **PostgreSQL Client Tools**: You need `pg_dump` installed on your local machine
   - **Windows**: Download from https://www.postgresql.org/download/windows/
   - **macOS**: `brew install postgresql`
   - **Linux**: `sudo apt install postgresql-client` (Ubuntu/Debian)

2. **Supabase Connection String**: Get this from your Supabase dashboard
   - Go to: https://supabase.com/dashboard/project/YOUR_PROJECT/settings/database
   - Copy the "Connection string" (it looks like: `postgresql://postgres:[password]@db.YOUR_PROJECT.supabase.co:5432/postgres`)

## Backup Scripts

I've created two backup scripts for different operating systems:

### Windows (`backup_supabase_local.bat`)
- Double-click to run (after editing the connection string)
- Creates timestamped backup files in the current directory

### Linux/macOS (`backup_supabase_local.sh`)
- Make executable: `chmod +x backup_supabase_local.sh`
- Run with: `./backup_supabase_local.sh`

## Setup Instructions

1. **Edit the connection string** in your chosen script:
   ```bash
   # Replace this line:
   SUPABASE_CONNECTION_STRING="postgresql://postgres:[YOUR_PASSWORD]@db.[YOUR_PROJECT].supabase.co:5432/postgres"

   # With your actual connection string from Supabase dashboard
   ```

2. **Run the script** from your project directory

## What Gets Backed Up

The script creates two backup files:

1. **`supabase_backup_YYYYMMDD_HHMMSS.backup`**
   - Compressed binary format
   - Smaller file size
   - Faster to restore
   - Use with `pg_restore`

2. **`supabase_backup_YYYYMMDD_HHMMSS.sql`**
   - Plain SQL text format
   - Human-readable
   - Can be viewed in any text editor
   - Can be run directly in Supabase SQL Editor

## Backup Contents

- ✅ All table schemas
- ✅ All data
- ✅ All indexes
- ✅ All RLS policies
- ✅ All functions and triggers
- ✅ All views
- ❌ Users/roles (not needed for Supabase)
- ❌ Privileges (handled by Supabase)

## Restore Instructions

### Option 1: Using pg_restore (Recommended)
```bash
pg_restore -d "YOUR_NEW_CONNECTION_STRING" supabase_backup_YYYYMMDD_HHMMSS.backup
```

### Option 2: Using Supabase SQL Editor
1. Open the `.sql` backup file in a text editor
2. Copy and paste the contents into Supabase SQL Editor
3. Run the script

### Option 3: Using Supabase Dashboard
1. Go to Settings → Database → Backups
2. Use the restore functionality

## Alternative Backup Methods

### Supabase Dashboard (Easiest)
- Settings → Database → Backups
- Create manual backup
- Download as ZIP file

### Supabase CLI
```bash
# Install CLI: npm install -g supabase
supabase db dump --db-url "YOUR_CONNECTION_STRING" > backup.sql
```

## Troubleshooting

### "pg_dump command not found"
- Install PostgreSQL client tools (see Prerequisites)

### "Connection refused" or authentication errors
- Double-check your connection string
- Make sure your IP is allowlisted in Supabase (Settings → Database → Allowlisted IPs)

### Large backup files
- The compressed `.backup` file is smaller than `.sql`
- Consider schema-only backup if you don't need data:
  - Uncomment the schema-only section in the script

## Security Notes

- Never commit backup files to version control
- Store backups securely (encrypted if possible)
- The connection string contains your database password - keep it secure

## File Locations

After running the backup script, you'll find the backup files in your project root directory alongside the script files.</content>
</xai:function_call">The backup scripts are now ready! Here's what I've created for you:

## Backup Scripts Created:

1. **`backup_supabase_local.bat`** - Windows batch file
2. **`backup_supabase_local.sh`** - Linux/macOS shell script  
3. **`BACKUP_README.md`** - Complete setup and usage guide

## Quick Start:

1. **Get your Supabase connection string** from: https://supabase.com/dashboard/project/YOUR_PROJECT/settings/database

2. **Edit the script** - Replace the placeholder connection string with your actual one

3. **Install pg_dump** if you don't have it:
   - Windows: Download PostgreSQL from https://www.postgresql.org/download/windows/
   - macOS: `brew install postgresql`
   - Linux: `sudo apt install postgresql-client`

4. **Run the appropriate script** for your OS

## What You'll Get:

- **`supabase_backup_YYYYMMDD_HHMMSS.backup`** - Compressed binary backup (smaller, faster to restore)
- **`supabase_backup_YYYYMMDD_HHMMSS.sql`** - Plain SQL text (human-readable, can run in Supabase SQL Editor)

## After Backup:

Once you have your backup, you can safely run the `supabase_performance_fixes.sql` script to apply all the performance optimizations.

The backup includes everything: schemas, data, policies, indexes, functions - your complete database state. You can restore it to a new Supabase project if needed.