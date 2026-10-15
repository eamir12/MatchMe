import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { withInvocationLogging } from "../_shared/edge_function_logger.ts";
import { collectProjectLogsHealth } from "../_shared/project_logs_health.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const managementToken = (Deno.env.get("MANAGEMENT_API_TOKEN") ?? "").trim();

const svc =
  supabaseUrl && serviceRoleKey
    ? createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false },
      })
    : null;

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function authorize(req: Request): Promise<boolean> {
  if (!svc) return false;
  const header = req.headers.get("Authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;
  if (serviceRoleKey && token === serviceRoleKey) return true;
  const { data, error } = await svc.auth.getUser(token);
  if (error || !data?.user) return false;
  const { data: profile, error: profileError } = await svc
    .from("users")
    .select("is_admin")
    .eq("id", data.user.id)
    .maybeSingle();
  if (profileError) throw profileError;
  return profile?.is_admin === true;
}

serve(withInvocationLogging("project-logs-health", async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (!svc) {
    return jsonResponse({ error: "SUPABASE_SERVICE_ROLE_KEY is not configured." }, 500);
  }
  const allowed = await authorize(req);
  if (!allowed) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const payload = await collectProjectLogsHealth({
    supabaseUrl,
    managementToken,
    detail: true,
  });
  return jsonResponse(payload as unknown as Record<string, unknown>);
}));
