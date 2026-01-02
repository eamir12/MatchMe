#!/bin/bash

# Supabase Database Backup Script
# This script backs up your entire Supabase database to a local file
# Requirements: pg_dump (PostgreSQL client tools) must be installed

# ==========================================
# CONFIGURATION
# ==========================================

# Get your connection string from: https://supabase.com/dashboard/project/YOUR_PROJECT/settings/database
# It will look like: postgresql://postgres:[password]@db.YOUR_PROJECT.supabase.co:5432/postgres

# Replace this with your actual Supabase connection string
SUPABASE_CONNECTION_STRING="postgresql://postgres:[YOUR_PASSWORD]@db.[YOUR_PROJECT].supabase.co:5432/postgres"

# Backup filename with timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="supabase_backup_${TIMESTAMP}.sql"

# ==========================================
# BACKUP OPTIONS
# ==========================================

# Option 1: Full backup (schema + data) - RECOMMENDED
echo "Starting full Supabase database backup..."
pg_dump "$SUPABASE_CONNECTION_STRING" \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists \
    --verbose \
    --format=custom \
    --compress=9 \
    --file="${BACKUP_FILENAME}.backup"

# Also create a plain SQL version for easy viewing
pg_dump "$SUPABASE_CONNECTION_STRING" \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists \
    --format=plain \
    --file="${BACKUP_FILENAME}.sql"

echo "Backup completed!"
echo "Files created:"
echo "  - ${BACKUP_FILENAME}.backup (compressed binary format)"
echo "  - ${BACKUP_FILENAME}.sql (plain SQL format)"

# ==========================================
# VERIFICATION
# ==========================================

echo ""
echo "Backup verification:"
echo "Compressed backup size: $(du -h "${BACKUP_FILENAME}.backup" | cut -f1)"
echo "SQL backup size: $(du -h "${BACKUP_FILENAME}.sql" | cut -f1)"

# ==========================================
# RESTORE INSTRUCTIONS
# ==========================================

echo ""
echo "To restore this backup:"
echo "1. Create a new Supabase project or use an existing empty one"
echo "2. Get the new connection string"
echo "3. Run: pg_restore -d 'NEW_CONNECTION_STRING' '${BACKUP_FILENAME}.backup'"
echo "   OR"
echo "   Run the SQL file in Supabase SQL Editor: ${BACKUP_FILENAME}.sql"

# ==========================================
# ALTERNATIVE: Schema-only backup
# ==========================================

# Uncomment the following lines if you only want schema (no data):
# SCHEMA_BACKUP="${TIMESTAMP}_schema_only.sql"
# pg_dump "$SUPABASE_CONNECTION_STRING" \
#     --no-owner \
#     --no-privileges \
#     --clean \
#     --if-exists \
#     --schema-only \
#     --file="$SCHEMA_BACKUP"
# echo "Schema-only backup created: $SCHEMA_BACKUP"