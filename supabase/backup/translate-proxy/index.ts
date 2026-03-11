// supabase/functions/translate-proxy/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// DeepL API configuration
const DEEPL_BASE_URL = 'https://api-free.deepl.com/v2';
const DEEPL_API_KEY = Deno.env.get('DEEPL_API_KEY');
const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const supabase = createClient(supabaseUrl, supabaseKey);

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    console.log('🔄 Translate-Proxy: Called');

    // Check if DeepL API key is configured
    if (!DEEPL_API_KEY) {
      console.log('🔄 Translate-Proxy: DEEPL_API_KEY not configured');
      throw new Error('DeepL API key not configured. Please set DEEPL_API_KEY environment variable.');
    }

    const body = await req.json();
    
    // Handle webhook payload format (from database webhook)
    let text: string;
    let target_lang: string;
    let source_lang: string = "auto";
    let messageId: string | null = null;

    if (body.record && body.record.match_id) {
      // This is a webhook payload from chat_messages insert
      console.log('🔄 Translate-Proxy: Processing webhook payload');
      
      const record = body.record;
      text = record.content_original;
      messageId = record.id;

      if (!text || text.trim().length < 2) {
        console.log('🔄 Translate-Proxy: Message too short, skipping');
        return new Response(
          JSON.stringify({ status: "message_too_short" }),
          { headers: corsHeaders, status: 200 }
        );
      }

      // Skip if already translated
      if (record.content_translated) {
        console.log('🔄 Translate-Proxy: Already translated, skipping');
        return new Response(
          JSON.stringify({ status: "already_translated" }),
          { headers: corsHeaders, status: 200 }
        );
      }

      // Get chat translation settings - check if ANY user has translation enabled
      const { data: chats, error: chatError } = await supabase
        .from("chats")
        .select("translation_enabled, translation_language, user_id")
        .eq("match_id", record.match_id);

      console.log(`🔄 Translate-Proxy: Chat query - error: ${JSON.stringify(chatError)}, chats: ${JSON.stringify(chats)}`);

      if (chatError || !chats || chats.length === 0) {
        console.log(`🔄 Translate-Proxy: No chat found for match_id: ${record.match_id}`);
        return new Response(
          JSON.stringify({ status: "chat_not_found" }),
          { headers: corsHeaders, status: 200 }
        );
      }

      // Find the first chat that has translation enabled
      const chat = chats.find(c => c.translation_enabled && c.translation_language);
      
      if (!chat) {
        console.log(`🔄 Translate-Proxy: No user has translation enabled for match_id: ${record.match_id}`);
        return new Response(
          JSON.stringify({ status: "translation_disabled" }),
          { headers: corsHeaders, status: 200 }
        );
      }

      console.log(`🔄 Translate-Proxy: Chat data - enabled: ${chat.translation_enabled}, language: ${chat.translation_language}`);

      target_lang = chat.translation_language;
    } else {
      // This is a direct API call
      console.log('🔄 Translate-Proxy: Processing direct API call');
      ({ text, target_lang, source_lang } = body);
      source_lang = source_lang || "auto";
    }

    console.log(`🔄 Translate-Proxy: Translating "${text}" to ${target_lang}`);

    if (!text || !target_lang) {
      throw new Error('Missing required parameters: text and target_lang are required.');
    }

    // Call DeepL API
    console.log('🔄 Translate-Proxy: Calling DeepL API');
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

    console.log('🔄 Translate-Proxy: DeepL response status:', response.status);

    if (!response.ok) {
      const errorBody = await response.text();
      throw new Error(`DeepL API failed: ${response.status} ${errorBody}`);
    }

    const data = await response.json();
    console.log('🔄 Translate-Proxy: DeepL API response data:', data);

    if (!data.translations || data.translations.length === 0) {
      throw new Error('No translation returned from DeepL API');
    }

    const translatedText = data.translations[0].text;
    console.log(`🔄 Translate-Proxy: Translated: "${translatedText}"`);

    // If this was a webhook call, update the message in the database
    if (messageId) {
      console.log(`🔄 Translate-Proxy: Updating message ${messageId}`);
      const { error: updateError } = await supabase
        .from("chat_messages")
        .update({ content_translated: translatedText })
        .eq("id", messageId);

      if (updateError) {
        console.error("🔄 Translate-Proxy: Error updating message:", updateError);
        return new Response(
          JSON.stringify({ status: "update_failed", error: updateError.message }),
          { headers: corsHeaders, status: 200 }
        );
      }

      return new Response(
        JSON.stringify({
          status: "success",
          message_id: messageId,
          translated_text: translatedText,
        }),
        { headers: corsHeaders, status: 200 }
      );
    }

    // For direct API calls, just return the translation
    const result = {
      translatedText,
      detected_source_language: data.translations[0].detected_source_language,
    };

    console.log('🔄 Translate-Proxy: Returning result:', result);

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });
  } catch (error) {
    console.error('🔄 Translate-Proxy: Error:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: corsHeaders,
      status: 400,
    });
  }
});