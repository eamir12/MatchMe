// supabase/functions/translate-proxy/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

// DeepL API configuration
const DEEPL_BASE_URL = 'https://api-free.deepl.com/v2';
const DEEPL_API_KEY = Deno.env.get('DEEPL_API_KEY');

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    console.log('🔄 Edge Function: Called with method:', req.method);

    // Check if DeepL API key is configured
    if (!DEEPL_API_KEY) {
      console.log('🔄 Edge Function: DEEPL_API_KEY not configured');
      throw new Error('DeepL API key not configured. Please set DEEPL_API_KEY environment variable.');
    }

    const { text, target_lang, source_lang } = await req.json();
    console.log('🔄 Edge Function: Request - text:', text, 'target_lang:', target_lang, 'source_lang:', source_lang);

    if (!text || !target_lang) {
      throw new Error('Missing required parameters: text and target_lang are required.');
    }

    // Call DeepL API
    console.log('🔄 Edge Function: Calling DeepL API');
    const response = await fetch(`${DEEPL_BASE_URL}/translate`, {
      method: 'POST',
      headers: {
        'Authorization': `DeepL-Auth-Key ${DEEPL_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        text: [text], // DeepL expects an array of strings
        target_lang: target_lang.toUpperCase(),
        source_lang: source_lang && source_lang.toUpperCase() !== 'AUTO' ? source_lang.toUpperCase() : null,
        preserve_formatting: true,
      }),
    });

    console.log('🔄 Edge Function: DeepL response status:', response.status);

    if (!response.ok) {
      const errorBody = await response.text();
      throw new Error(`DeepL API failed: ${response.status} ${errorBody}`);
    }

    const data = await response.json();
    console.log('🔄 Edge Function: DeepL API response data:', data);

    if (!data.translations || data.translations.length === 0) {
      throw new Error('No translation returned from DeepL API');
    }

    // Format response to match expected format (for backward compatibility)
    const result = {
      translatedText: data.translations[0].text,
      detected_source_language: data.translations[0].detected_source_language,
    };

    console.log('🔄 Edge Function: Returning result:', result);

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });
  } catch (error) {
    console.error('Translation error:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});