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
  const functionName = "invite";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;

  try {
    const url = new URL(req.url)
    const code = url.searchParams.get('code')
  
    // Initialize Supabase Client
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const supabase = supabaseKey
      ? createClient(supabaseUrl, supabaseKey)
      : null

    // Log the visit for fingerprinting
    if (code) {
      console.log(`[INVITE] Received visit for code: ${code}. IP: ${req.headers.get("x-forwarded-for")?.split(',')[0]}, UA: ${req.headers.get("user-agent")}`)
      try {
        if (supabase == null) {
          console.warn('[INVITE] SUPABASE_SERVICE_ROLE_KEY is missing; skipping referral visit logging.')
        } else {
          const ip = req.headers.get("x-forwarded-for")?.split(',')[0] || "unknown"
          const ua = req.headers.get("user-agent") || "unknown"
          
          const { error } = await supabase.from('referral_visits').insert({
            referral_code: code,
            ip_address: ip,
            user_agent: ua,
            claimed: false
          })
          
          if (error) {
             console.error('[INVITE] DB Error inserting visit:', error)
          } else {
             console.log('[INVITE] Successfully logged visit to DB.')
          }
        }
      } catch (e) {
        console.error('[INVITE] Exception logging visit:', e)
      }
    } else {
      console.log('[INVITE] Visit received but NO CODE provided.')
    }
    
    // Clean Code to prevent XSS injection
    const safeCode = (code || '').replace(/[^a-zA-Z0-9]/g, '');

    // Define your App Store URLs (Replace with real ones when available)
    const ANDROID_URL = 'https://play.google.com/store/apps/details?id=com.example.matchme'
    const IOS_URL = 'https://apps.apple.com/app/id123456789'
    const FALLBACK_WEB = 'http://localhost:5000'

    const platform = (req.headers.get("sec-ch-ua-platform") || "").toLowerCase()
    const ua = (req.headers.get("user-agent") || "").toLowerCase()
    const isIos = platform.includes("ios") || /iphone|ipad|ipod/.test(ua)
    const isAndroid = platform.includes("android") || /android/.test(ua)

    const redirectUrl = isIos
      ? IOS_URL
      : isAndroid
        ? ANDROID_URL
        : (safeCode ? `${FALLBACK_WEB}/invite?code=${safeCode}` : FALLBACK_WEB)

    success = true;
    httpStatus = 302;
    return Response.redirect(redirectUrl, 302)

  } catch (error) {
    errorType = error instanceof Error ? error.name : "Error";
    errorMessage = error instanceof Error ? error.message : String(error);
    httpStatus = 400;
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : String(error) }),
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
