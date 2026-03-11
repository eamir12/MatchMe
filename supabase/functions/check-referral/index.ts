import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

serve(async (req) => {
  // CORS headers
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "check-referral";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;

  try {
    // Initialize Supabase Client
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const supabase = createClient(supabaseUrl, supabaseKey)

    // Get client info
    const ip = req.headers.get("x-forwarded-for")?.split(',')[0] || "unknown"
    const ua = req.headers.get("user-agent") || "unknown"

    console.log(`[CHECK] Checking referral for IP: ${ip}, UA: ${ua}`)

    // Look for unclaimed visits from this IP/UA in the last 24 hours
    const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()

    const { data, error } = await supabase
      .from('referral_visits')
      .select('id, referral_code')
      .eq('ip_address', ip)
      .eq('user_agent', ua)
      .eq('claimed', false)
      .gt('created_at', oneDayAgo)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()

    if (error) {
      console.error('[CHECK] DB Error searching visits:', error)
      throw error
    }

    if (data) {
      console.log(`[CHECK] MATCH FOUND! Code: ${data.referral_code} (ID: ${data.id})`)
      
      // Mark as claimed to prevent reuse
      const { error: updateError } = await supabase
        .from('referral_visits')
        .update({ claimed: true, claimed_at: new Date().toISOString() })
        .eq('id', data.id)
      
      if (updateError) {
         console.error('[CHECK] Failed to mark visit as claimed:', updateError)
      } else {
         console.log('[CHECK] Successfully marked visit as claimed.')
      }

      success = true;
      httpStatus = 200;
      return new Response(
        JSON.stringify({ found: true, code: data.referral_code }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    console.log('[CHECK] No matching unclaimed visit found.')
    success = true;
    httpStatus = 200;
    return new Response(
      JSON.stringify({ found: false }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    errorType = error instanceof Error ? error.name : "Error";
    errorMessage = error instanceof Error ? error.message : String(error);
    httpStatus = 400;
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
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
})
