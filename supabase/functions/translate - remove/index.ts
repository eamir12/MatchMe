// supabase/functions/translate/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

// This imports the friendly name "translate" from deno.json
import { translate } from 'translate'; 

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { text, target_lang, source_lang } = await req.json();

    if (!text || !target_lang) {
      throw new Error('Missing "text" or "target_lang" parameter.');
    }

    // This package has a simpler syntax
    const translated_text = await translate(text, {
      from: source_lang || 'auto',
      to: target_lang,
    });

    const data = {
      translated_text: translated_text,
      source_language: 'auto-detected', // This simple package doesn't return the source lang
    };

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});