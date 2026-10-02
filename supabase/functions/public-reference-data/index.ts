import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

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

// MatchMe ships exactly three languages: en, es, he. Anything else resolves
// to English rather than returning an empty translations set for a locale the
// app does not support. Keep in sync with the AppLanguage entries in
// lib/providers/locale_provider.dart.
function normalizeLocale(input: unknown): string {
  const value = typeof input === "string" ? input.trim().toLowerCase() : "";
  if (value.startsWith("he")) return "he";
  if (value.startsWith("es")) return "es";
  return "en";
}

function normalizeCurrency(input: unknown): string {
  const value = typeof input === "string" ? input.trim().toUpperCase() : "";
  return /^[A-Z]{3}$/.test(value) ? value : "USD";
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "public-reference-data";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;

  try {
    if (svc == null) {
      httpStatus = 500;
      success = false;
      return jsonResponse(
        { error: "SUPABASE_SERVICE_ROLE_KEY is not configured." },
        500,
      );
    }

    const body = await req.json().catch(() => ({}));
    const resource =
      typeof body?.resource === "string" ? body.resource.trim() : "";

    switch (resource) {
      case "app_config": {
        const { data, error } = await svc
          .from("app_config")
          .select("config_key, config_value")
          .order("config_key", { ascending: true });
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ config: data ?? [] });
      }

      case "supported_languages": {
        const { data, error } = await svc
          .from("app_languages")
          .select("language_code, display_name, text_direction")
          .order("display_name", { ascending: true });
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ languages: data ?? [] });
      }

      case "translations": {
        const locale = normalizeLocale(body?.locale);
        const { data, error } = await svc
          .from("translations")
          .select("key, value")
          .eq("locale", locale);
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ locale, translations: data ?? [] });
      }

      case "intents": {
        const { data, error } = await svc
          .from("intents")
          .select(
            "id, key, translation_key, parent_id, sort_order, is_social, is_business",
          )
          .order("sort_order", { ascending: true });
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ intents: data ?? [] });
      }

      case "interests": {
        const { data, error } = await svc
          .from("interests")
          .select(
            "id, key, translation_key, parent_id, sort_order, is_social, is_business",
          )
          .order("sort_order", { ascending: true });
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ interests: data ?? [] });
      }

      case "gender_options": {
        const { data, error } = await svc
          .from("app_gender_options")
          .select("gender_key, display_name_key, sort_order")
          .order("sort_order", { ascending: true });
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ gender_options: data ?? [] });
      }

      case "currency_rates": {
        const baseCurrency = normalizeCurrency(body?.base_currency);
        const { data, error } = await svc
          .from("currency_exchange_rates")
          .select("base_currency, quote_currency, rate, fetched_at")
          .eq("base_currency", baseCurrency);
        if (error) throw error;
        success = true;
        httpStatus = 200;
        return jsonResponse({ base_currency: baseCurrency, rates: data ?? [] });
      }

      default: {
        httpStatus = 400;
        success = false;
        return jsonResponse({ error: "Unsupported resource." }, 400);
      }
    }
  } catch (error) {
    errorType = error instanceof Error ? error.name : "Error";
    if (error instanceof Error) {
      errorMessage = error.message;
    } else {
      try {
        errorMessage = JSON.stringify(error);
      } catch {
        errorMessage = String(error);
      }
    }
    httpStatus = 500;
    success = false;
    return jsonResponse({ error: errorMessage ?? "Unknown error" }, 500);
  } finally {
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success,
      httpStatus,
      errorType,
      errorMessage,
      aiUsed: false,
      meta: { method: req.method },
    });
  }
});
