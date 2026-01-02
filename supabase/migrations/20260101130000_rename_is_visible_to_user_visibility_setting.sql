-- Migration: Rename is_visible to user_visibility_setting and add system_visibility_status check/default
-- NOTE: Avoid explicit BEGIN/COMMIT - migration runner wraps each migration in a transaction

-- 1) Rename column if it exists
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'is_visible'
  ) THEN
    ALTER TABLE public.users RENAME COLUMN is_visible TO user_visibility_setting;
  END IF;
END$$;

-- 2) Add system_visibility_status column if it doesn't exist
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS system_visibility_status TEXT DEFAULT 'visible';

-- 3) Add check constraint for allowed values
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'system_visibility_status_check') THEN
    ALTER TABLE public.users
      ADD CONSTRAINT system_visibility_status_check
      CHECK (system_visibility_status IN ('visible','invisible','invisible_rules','offline','gps_problem','network_offline'));
  END IF;
END$$;
