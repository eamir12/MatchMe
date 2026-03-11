BEGIN;

CREATE TABLE IF NOT EXISTS public.edge_function_invocations (
  id BIGSERIAL PRIMARY KEY,
  request_id uuid NOT NULL,
  function_name text NOT NULL,
  invoked_at timestamptz NOT NULL DEFAULT now(),
  duration_ms integer,
  success boolean NOT NULL,
  http_status integer,
  error_type text,
  error_message text,
  user_id uuid,
  ai_used boolean NOT NULL DEFAULT false,
  ai_provider text,
  ai_model text,
  ai_task text,
  meta jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS edge_function_invocations_invoked_at_idx
  ON public.edge_function_invocations (invoked_at DESC);

CREATE INDEX IF NOT EXISTS edge_function_invocations_function_name_idx
  ON public.edge_function_invocations (function_name);

CREATE INDEX IF NOT EXISTS edge_function_invocations_success_idx
  ON public.edge_function_invocations (success);

CREATE INDEX IF NOT EXISTS edge_function_invocations_ai_idx
  ON public.edge_function_invocations (ai_used, ai_provider, ai_model, ai_task);

ALTER TABLE public.edge_function_invocations ENABLE ROW LEVEL SECURITY;

COMMIT;
