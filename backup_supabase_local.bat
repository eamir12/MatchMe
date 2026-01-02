@echo off
REM Supabase Database Backup Script for Windows
REM This script backs up your entire Supabase database to a local file
REM Requirements: pg_dump (PostgreSQL client tools) must be installed

REM ==========================================
REM CONFIGURATION
REM ==========================================

REM Get your connection string from: https://supabase.com/dashboard/project/YOUR_PROJECT/settings/database
REM It will look like: postgresql://postgres:[password]@db.YOUR_PROJECT.supabase.co:5432/postgres

REM Replace this with your actual Supabase connection string
set SUPABASE_CONNECTION_STRING=postgresql://postgres:[YOUR_PASSWORD]@db.[YOUR_PROJECT].supabase.co:5432/postgres

REM Get timestamp for filename
for /f "tokens=2 delims==" %%i in ('wmic os get localdatetime /value') do set datetime=%%i
set TIMESTAMP=%datetime:~0,8%_%datetime:~8,6%
set BACKUP_FILENAME=supabase_backup_%TIMESTAMP%

REM ==========================================
REM BACKUP PROCESS
REM ==========================================

echo Starting full Supabase database backup...

REM Create compressed binary backup
pg_dump "%SUPABASE_CONNECTION_STRING%" --no-owner --no-privileges --clean --if-exists --verbose --format=custom --compress=9 --file="%BACKUP_FILENAME%.backup"

REM Create plain SQL backup for easy viewing
pg_dump "%SUPABASE_CONNECTION_STRING%" --no-owner --no-privileges --clean --if-exists --format=plain --file="%BACKUP_FILENAME%.sql"

echo Backup completed!
echo Files created:
echo   - %BACKUP_FILENAME%.backup (compressed binary format)
echo   - %BACKUP_FILENAME%.sql (plain SQL format)

REM ==========================================
REM VERIFICATION
REM ==========================================

echo.
echo Backup verification:
if exist "%BACKUP_FILENAME%.backup" (
    for %%A in ("%BACKUP_FILENAME%.backup") do echo Compressed backup size: %%~zA bytes
) else (
    echo ERROR: Compressed backup file not found!
)

if exist "%BACKUP_FILENAME%.sql" (
    for %%A in ("%BACKUP_FILENAME%.sql") do echo SQL backup size: %%~zA bytes
) else (
    echo ERROR: SQL backup file not found!
)

REM ==========================================
REM RESTORE INSTRUCTIONS
REM ==========================================

echo.
echo To restore this backup:
echo 1. Create a new Supabase project or use an existing empty one
echo 2. Get the new connection string
echo 3. Run: pg_restore -d "NEW_CONNECTION_STRING" "%BACKUP_FILENAME%.backup"
echo    OR
echo    Run the SQL file in Supabase SQL Editor: %BACKUP_FILENAME%.sql

REM ==========================================
REM ALTERNATIVE: Schema-only backup
REM ==========================================

REM Uncomment the following lines if you only want schema (no data):
REM set SCHEMA_BACKUP=%TIMESTAMP%_schema_only.sql
REM pg_dump "%SUPABASE_CONNECTION_STRING%" --no-owner --no-privileges --clean --if-exists --schema-only --file="%SCHEMA_BACKUP%"
REM echo Schema-only backup created: %SCHEMA_BACKUP%

echo.
echo Press any key to exit...
pause > nul