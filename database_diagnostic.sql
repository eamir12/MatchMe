-- Database Diagnostic Script
-- Run this in Supabase SQL Editor to check functions, RLS, and policies

-- 1. List all functions in public schema
SELECT
    proname AS function_name,
    pg_get_function_identity_arguments(oid) AS arguments,
    pg_get_function_result(oid) AS return_type,
    obj_description(oid, 'pg_proc') AS description
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
ORDER BY proname;

-- 2. Check RLS status on key tables
SELECT
    schemaname,
    tablename,
    rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
AND tablename IN ('users', 'user_profiles', 'matches', 'chat_messages', 'events', 'event_attendees')
ORDER BY tablename;

-- 3. List all RLS policies
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- 4. Check if specific functions exist
SELECT
    CASE WHEN EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'get_recent_chats'
        AND pronamespace = 'public'::regnamespace
    ) THEN 'get_recent_chats exists' ELSE 'get_recent_chats does not exist' END AS get_recent_chats_status,

    CASE WHEN EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'mark_messages_as_read'
        AND pronamespace = 'public'::regnamespace
    ) THEN 'mark_messages_as_read exists' ELSE 'mark_messages_as_read does not exist' END AS mark_messages_as_read_status;

-- 5. Check chat_messages table structure
SELECT
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema = 'public'
AND table_name = 'chat_messages'
ORDER BY ordinal_position;