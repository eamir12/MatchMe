// supabase/functions/translate-proxy/index.ts
// @ts-nocheck
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

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

// Helper: Build enhanced translation context using DeepL's context and custom_instructions
// Returns { context, customInstructions, formality }
export async function buildDeepLEnhancements(
  client: any, 
  record: any, 
  text: string,
  recipientId: string
): Promise<{ context?: string; customInstructions?: string[]; formality?: string }> {
  try {
    if (!record || !record.sender_id || !recipientId) {
      return { formality: 'prefer_less' }; // Default to informal for chats
    }

    // Get sender and recipient gender info
    const { data: senderData } = await client
      .from('users')
      .select('gender')
      .eq('id', record.sender_id)
      .maybeSingle();

    const { data: recipientData } = await client
      .from('users')
      .select('gender')
      .eq('id', recipientId)
      .maybeSingle();

    const senderGender = senderData?.gender;
    const recipientGender = recipientData?.gender;

    // Build context string (natural language, helps with ambiguous short texts)
    const contextParts: string[] = [];
    contextParts.push('This is a casual chat message between two people.');
    if (senderGender) contextParts.push(`The sender is ${senderGender}.`);
    if (recipientGender) contextParts.push(`The recipient is ${recipientGender}.`);
    
    const context = contextParts.length > 1 ? contextParts.join(' ') : undefined;

    // Build custom instructions (precise hints for translation engine)
    const customInstructions: string[] = [];
    
    // Gender-specific instruction
    if (senderGender && recipientGender) {
      customInstructions.push(
        `Use ${senderGender} grammatical forms for the speaker and ${recipientGender} forms when addressing the recipient.`
      );
    } else if (senderGender) {
      customInstructions.push(`The speaker is ${senderGender}. Use appropriate grammatical forms.`);
    } else if (recipientGender) {
      customInstructions.push(`The recipient is ${recipientGender}. Use appropriate grammatical forms when addressing them.`);
    }

    // Detect numbers for plural handling
    const numbers = text.match(/\b(\d{1,3})\b/g);
    if (numbers && numbers.length > 0) {
      customInstructions.push('Pay attention to singular/plural forms based on the numbers in the text.');
    }

    // Always use informal tone for chat messages
    return {
      context: context,
      customInstructions: customInstructions.length > 0 ? customInstructions : undefined,
      formality: 'prefer_less' // Informal tone for chat
    };
  } catch (err) {
    console.warn('buildDeepLEnhancements error', err);
    return { formality: 'prefer_less' };
  }
}


serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "translate-proxy";
  let aiUsed = false;
  const aiProvider = "deepl";
  let aiModel: string | null = null;
  let aiTask: string | null = null;
  let requestUserId: string | null = null;

  const respond = async (
    payload: Record<string, unknown>,
    opts?: {
      httpStatus?: number;
      success?: boolean;
      errorType?: string | null;
      errorMessage?: string | null;
      userId?: string | null;
      meta?: Record<string, unknown>;
    },
  ) => {
    const httpStatus = opts?.httpStatus ?? 200;
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success: opts?.success ?? true,
      httpStatus,
      errorType: opts?.errorType ?? null,
      errorMessage: opts?.errorMessage ?? null,
      userId: opts?.userId ?? requestUserId,
      aiUsed,
      aiProvider: aiUsed ? aiProvider : null,
      aiModel,
      aiTask,
      meta: opts?.meta ?? {},
    });
    return new Response(JSON.stringify(payload), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: httpStatus,
    });
  };

  try {
    console.log('🔄 Translate-Proxy: Called');
    console.log('🔄 Translate-Proxy: Request headers:', JSON.stringify({
      contentType: req.headers.get('content-type'),
      authorization: req.headers.get('authorization') ? 'present' : 'missing',
    }));
    
    // Check if DeepL API key is configured
    if (!DEEPL_API_KEY) {
      console.log('🔄 Translate-Proxy: DEEPL_API_KEY not configured');
      throw new Error('DeepL API key not configured. Please set DEEPL_API_KEY environment variable.');
    }

    const body = await req.json();
    console.log('🔄 Translate-Proxy: Full request body keys:', JSON.stringify(Object.keys(body)));
    console.log('🔄 Translate-Proxy: Request body preview:', JSON.stringify({
      hasRecord: !!body.record,
      hasMatchId: !!body.match_id,
      hasText: !!body.text,
      hasTargetLanguage: !!body.target_language,
      recordKeys: body.record ? Object.keys(body.record) : null,
    }));
    
    // Check if this is a batch translation request
    if (body.match_id && body.target_language && !body.record) {
      console.log('🔄 Translate-Proxy: 🚀 SOURCE DETECTED: BATCH TRANSLATION (app-initiated)');
      console.log('🔄 Translate-Proxy: Batch request details:', JSON.stringify({
        match_id: body.match_id,
        target_language: body.target_language,
        retranslate_all: body.retranslate_all,
        exclude_sender_id: body.exclude_sender_id,
        source_language: body.source_language,
      }));
      const retranslateAll = body.retranslate_all ?? false; // Default to false (only translate untranslated)
      const excludeSenderId = body.exclude_sender_id ?? null; // Optional: only translate messages NOT from this user
      const sourceLanguage = body.source_language ?? null; // Optional: specify source language for better translation
      aiUsed = true;
      aiModel = "quality_optimized";
      aiTask = "batch_translation";
      const res = await handleBatchTranslation(body.match_id, body.target_language, retranslateAll, excludeSenderId, sourceLanguage);
      await logEdgeFunctionInvocation({
        requestId,
        functionName,
        durationMs: Date.now() - startedAt,
        success: res.status < 400,
        httpStatus: res.status,
        userId: requestUserId,
        aiUsed,
        aiProvider,
        aiModel,
        aiTask,
        meta: {
          matchId: body.match_id,
          targetLanguage: body.target_language,
          retranslateAll,
          excludeSenderId,
          sourceLanguage,
        },
      });
      return res;
    }
    
    // Handle webhook payload format (from database webhook)
    let text: string;
    let target_lang: string;
    let source_lang: string = "auto";
    let messageId: string | null = null;
    // hoist record so it can be used later when building context
    let record: any = null;
    let recipientChat: any = null; // Store recipient chat for context building

    // DETECT SOURCE: Webhook vs Direct API call vs Batch
    if (body.record && body.record.match_id) {
      // This is a webhook payload from chat_messages insert
      console.log('🔄 Translate-Proxy: 🚀 SOURCE DETECTED: DATABASE WEBHOOK (body.record.match_id exists)');
      console.log('🔄 Translate-Proxy: Webhook record content:', JSON.stringify({
        id: body.record.id,
        match_id: body.record.match_id,
        sender_id: body.record.sender_id,
        content_original: body.record.content_original?.substring(0, 50),
        content_translated: body.record.content_translated ? 'already_set' : 'null',
      }));
      
      record = body.record;
      text = record.content_original;
      messageId = record.id;
      requestUserId = record.sender_id ?? null;

      if (!text || text.trim().length < 2) {
        console.log('🔄 Translate-Proxy: Message too short, skipping');
        return await respond(
          { status: "message_too_short" },
          {
            success: true,
            userId: requestUserId,
            meta: { matchId: record.match_id, messageId },
          },
        );
      }

      // Skip if already translated
      if (record.content_translated) {
        console.log('🔄 Translate-Proxy: Already translated, skipping');
        return await respond(
          { status: "already_translated" },
          {
            success: true,
            userId: requestUserId,
            meta: { matchId: record.match_id, messageId },
          },
        );
      }

      console.log(`🔄 Translate-Proxy: Looking for recipient chat for match_id: ${record.match_id}, sender: ${record.sender_id}`);

      // Get all chats for this match - there should be 2 (one for each user)
      const { data: chats, error: chatError } = await supabase
        .from("chats")
        .select("translation_enabled, translation_language, user_id, other_user_id")
        .eq("match_id", record.match_id);

      console.log(`🔄 Translate-Proxy: Chats query result - error: ${JSON.stringify(chatError)}, chats: ${JSON.stringify(chats)}`);

      if (chatError || !chats || chats.length === 0) {
        console.log(`🔄 Translate-Proxy: No chats found for match_id: ${record.match_id}`);
        return await respond(
          { status: "chat_not_found" },
          {
            success: true,
            userId: requestUserId,
            meta: { matchId: record.match_id, messageId },
          },
        );
      }

      // Find the RECIPIENT's chat row (where user_id is NOT the sender)
      recipientChat = chats.find(c => c.user_id !== record.sender_id);
      
      if (!recipientChat) {
        console.log(`🔄 Translate-Proxy: Could not determine recipient from chats`);
        return await respond(
          { status: "recipient_not_found" },
          {
            success: true,
            userId: requestUserId,
            meta: { matchId: record.match_id, messageId },
          },
        );
      }

      console.log(`🔄 Translate-Proxy: Sender: ${record.sender_id}, Recipient: ${recipientChat.user_id}`);

      // Check if recipient has translation enabled
      if (!recipientChat.translation_enabled || !recipientChat.translation_language) {
        console.log(`🔄 Translate-Proxy: Recipient has translation disabled or no language set`);
        return await respond(
          { status: "translation_disabled" },
          {
            success: true,
            userId: requestUserId,
            meta: { matchId: record.match_id, messageId, recipientId: recipientChat.user_id },
          },
        );
      }

      console.log(`🔄 Translate-Proxy: Recipient chat - enabled: ${recipientChat.translation_enabled}, language: ${recipientChat.translation_language}`);

      target_lang = recipientChat.translation_language;
    } else {
      // This is a direct API call (from app or trigger)
      console.log('🔄 Translate-Proxy: 🚀 SOURCE DETECTED: DIRECT API CALL');
      console.log('🔄 Translate-Proxy: Direct call details:', JSON.stringify({
        hasText: !!body.text,
        hasTargetLang: !!body.target_lang,
        textPreview: body.text?.substring(0, 30),
        target_lang: body.target_lang,
        source_lang: body.source_lang,
      }));
      ({ text, target_lang, source_lang } = body);
      source_lang = source_lang || "auto";
    }

    console.log(`🔄 Translate-Proxy: Translating "${text}" to ${target_lang}`);

    if (!text || !target_lang) {
      throw new Error('Missing required parameters: text and target_lang are required.');
    }

    // Build enhanced DeepL parameters (context, custom instructions, formality)
    let deeplEnhancements: { context?: string; customInstructions?: string[]; formality?: string } = { formality: 'prefer_less' };

    if (messageId && record && recipientChat) {
      // Get recipient ID from the recipientChat we already fetched
      const recipientId = recipientChat.user_id;
      deeplEnhancements = await buildDeepLEnhancements(supabase, record, text, recipientId);
      console.log(`🔄 Translate-Proxy: Built DeepL enhancements:`, JSON.stringify(deeplEnhancements));
    } else if (body?.context) {
      // Allow explicit context override from request
      deeplEnhancements.context = body.context;
      console.log(`🔄 Translate-Proxy: Using explicit context from request: ${body.context}`);
    }

    // Languages that support custom_instructions: de, en, es, fr, it, ja, ko, zh (and variants)
    const customInstructionsSupportedLangs = ['DE', 'EN', 'EN-US', 'EN-GB', 'ES', 'FR', 'IT', 'JA', 'KO', 'ZH', 'ZH-HANS', 'ZH-HANT'];
    const targetLangUpper = target_lang.toUpperCase();
    const supportsCustomInstructions = customInstructionsSupportedLangs.includes(targetLangUpper);

    console.log(`🔄 Translate-Proxy: Target language ${targetLangUpper} ${supportsCustomInstructions ? 'supports' : 'does not support'} custom_instructions`);

    // Call DeepL API
    console.log('🔄 Translate-Proxy: Calling DeepL API with quality-optimized model');

    aiUsed = true;
    aiModel = 'quality_optimized';
    aiTask = messageId ? 'chat_message_translation' : 'direct_translation';

    const deepLRequestBody: any = {
      text: [text], // DeepL expects an array of strings
      target_lang: targetLangUpper,
      source_lang: source_lang && source_lang.toUpperCase() !== 'AUTO' ? source_lang.toUpperCase() : null,
      preserve_formatting: true,
      model_type: 'quality_optimized', // Use best quality model for chat translations
    };

    // Add optional parameters
    if (deeplEnhancements.context) {
      deepLRequestBody.context = deeplEnhancements.context;
    }
    // Only add custom_instructions for supported languages
    if (supportsCustomInstructions && deeplEnhancements.customInstructions && deeplEnhancements.customInstructions.length > 0) {
      deepLRequestBody.custom_instructions = deeplEnhancements.customInstructions;
    }
    if (deeplEnhancements.formality) {
      deepLRequestBody.formality = deeplEnhancements.formality;
    }

    console.log('🔄 Translate-Proxy: DeepL request preview:', JSON.stringify({
      target_lang: deepLRequestBody.target_lang,
      model_type: deepLRequestBody.model_type,
      context: deepLRequestBody.context,
      custom_instructions: deepLRequestBody.custom_instructions,
      formality: deepLRequestBody.formality,
      preserve_formatting: deepLRequestBody.preserve_formatting
    }));

    const response = await fetch(`${DEEPL_BASE_URL}/translate`, {
      method: 'POST',
      headers: {
        'Authorization': `DeepL-Auth-Key ${DEEPL_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(deepLRequestBody),
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
    const detectedSourceLang = data.translations[0].detected_source_language?.toLowerCase();
    console.log(`🔄 Translate-Proxy: Translated: "${translatedText}" from ${detectedSourceLang} to ${target_lang}`);

    // If this was a webhook call, update the message in the database
    if (messageId) {
      console.log(`🔄 Translate-Proxy: Updating message ${messageId} with translation and language metadata`);
      const { error: updateError } = await supabase
        .from("chat_messages")
        .update({ 
          content_translated: translatedText,
          detected_source_language: detectedSourceLang,
          translated_target_language: target_lang.toLowerCase()
        })
        .eq("id", messageId);

      if (updateError) {
        console.error("🔄 Translate-Proxy: Error updating message:", updateError);
        return await respond(
          { status: "update_failed", error: updateError.message },
          {
            success: false,
            httpStatus: 200,
            errorType: "db_write_failed",
            errorMessage: updateError.message,
            userId: requestUserId,
            meta: { messageId, matchId: record?.match_id },
          },
        );
      }

      return await respond(
        {
          status: "success",
          message_id: messageId,
          translated_text: translatedText,
        },
        {
          success: true,
          userId: requestUserId,
          meta: { messageId, matchId: record?.match_id, targetLang: target_lang },
        },
      );
    }

    // For direct API calls, just return the translation
    const result = {
      translated_text: translatedText,
      detected_source_language: data.translations[0].detected_source_language,
      translated_target_language: target_lang.toLowerCase(),
    };

    console.log('🔄 Translate-Proxy: Returning result:', result);

    return await respond(
      result,
      {
        success: true,
        userId: requestUserId,
        meta: { targetLang: target_lang, sourceLang: source_lang },
      },
    );
  } catch (error) {
    console.error('🔄 Translate-Proxy: Error:', error);
    return await respond(
      { error: error.message },
      {
        httpStatus: 400,
        success: false,
        errorType: "exception",
        errorMessage: error instanceof Error ? error.message : String(error),
        userId: requestUserId,
      },
    );
  }
});

// Helper function to handle batch translation of old messages
async function handleBatchTranslation(
  matchId: string, 
  targetLanguage: string, 
  retranslateAll: boolean = false,
  excludeSenderId: string | null = null,
  sourceLanguage: string | null = null
): Promise<Response> {
  try {
    const mode = retranslateAll ? 'RETRANSLATE ALL' : 'TRANSLATE UNTRANSLATED';
    const filterInfo = excludeSenderId ? ` (excluding sender ${excludeSenderId})` : '';
    const sourceInfo = sourceLanguage ? ` from ${sourceLanguage}` : '';
    console.log(`🔄 [BATCH] Starting batch translation for match ${matchId} to ${targetLanguage}${sourceInfo} (mode: ${mode}${filterInfo})`);;

    // Build the query based on mode
    let query = supabase
      .from("chat_messages")
      .select("id, content_original, sender_id, match_id")
      .eq("match_id", matchId);

    // If excludeSenderId provided, only translate messages from OTHER users (incoming messages)
    if (excludeSenderId) {
      query = query.neq("sender_id", excludeSenderId);
      console.log(`🔄 [BATCH] Filtering to only translate incoming messages (not from ${excludeSenderId})`);
    }

    // If NOT retranslating all, only get messages without translations
    if (!retranslateAll) {
      query = query.or(`content_translated.is.null,content_translated.eq.''`);
    }

    const { data: messages, error: fetchError } = await query;

    if (fetchError) {
      console.error("[BATCH] Error fetching messages:", fetchError);
      return new Response(
        JSON.stringify({ error: "Failed to fetch messages", details: fetchError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!messages || messages.length === 0) {
      const reason = retranslateAll ? 'No messages found for this match' : 'No untranslated messages found';
      console.log(`[BATCH] ${reason}`);
      return new Response(
        JSON.stringify({ success: true, translated: 0 }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const messageType = retranslateAll ? 'messages to retranslate' : 'untranslated messages';
    console.log(`🔄 [BATCH] Found ${messages.length} ${messageType}`);

    // For batch translation, we need to get the recipient chat to build context
    // Find the chat where user_id is NOT the sender (the recipient)
    const { data: chats, error: chatError } = await supabase
      .from("chats")
      .select("translation_enabled, translation_language, user_id, other_user_id")
      .eq("match_id", matchId);

    if (chatError || !chats || chats.length === 0) {
      console.error("[BATCH] Could not fetch chats for context:", chatError);
      return new Response(
        JSON.stringify({ error: "Failed to fetch chat info for context" }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Determine the recipient - the user who is NOT sending the messages
    // For batch translation with excludeSenderId, we translate messages FROM others TO the current user
    // So the recipient is the current user (excludeSenderId)
    const recipientId = excludeSenderId;
    const senderIdForContext = messages[0]?.sender_id; // Use first message's sender as reference

    // Build DeepL enhancements using the recipient (current user)
    let deeplEnhancements: { context?: string; customInstructions?: string[]; formality?: string } = { formality: 'prefer_less' };
    
    if (recipientId && senderIdForContext) {
      // Create a mock record for buildDeepLEnhancements
      const mockRecord = { sender_id: senderIdForContext };
      deeplEnhancements = await buildDeepLEnhancements(supabase, mockRecord, "", recipientId);
      console.log(`🔄 [BATCH] Built DeepL enhancements for context:`, JSON.stringify(deeplEnhancements));
    }

    // Languages that support custom_instructions: de, en, es, fr, it, ja, ko, zh (and variants)
    const customInstructionsSupportedLangs = ['DE', 'EN', 'EN-US', 'EN-GB', 'ES', 'FR', 'IT', 'JA', 'KO', 'ZH', 'ZH-HANS', 'ZH-HANT'];
    const targetLangUpper = targetLanguage.toUpperCase();
    const supportsCustomInstructions = customInstructionsSupportedLangs.includes(targetLangUpper);

    console.log(`🔄 [BATCH] Target language ${targetLangUpper} ${supportsCustomInstructions ? 'supports' : 'does not support'} custom_instructions`);

    let translatedCount = 0;
    let failureCount = 0;

    // Translate each message
    for (const message of messages) {
      try {
        const originalText = message.content_original;

        if (!originalText || originalText.trim().length < 2) {
          continue;
        }

        // Build DeepL request body with context
        const deepLRequestBody: any = {
          text: [originalText],
          target_lang: targetLangUpper,
          source_lang: sourceLanguage ? sourceLanguage.toUpperCase() : null,
          preserve_formatting: true,
          model_type: 'quality_optimized',
          formality: 'prefer_less',
        };

        // Add context and custom instructions if available
        if (deeplEnhancements.context) {
          deepLRequestBody.context = deeplEnhancements.context;
        }
        if (supportsCustomInstructions && deeplEnhancements.customInstructions && deeplEnhancements.customInstructions.length > 0) {
          deepLRequestBody.custom_instructions = deeplEnhancements.customInstructions;
        }

        console.log(`🔄 [BATCH] Translating message ${message.id} with context:`, JSON.stringify({
          context: deepLRequestBody.context,
          custom_instructions: deepLRequestBody.custom_instructions,
        }));

        const deepLResponse = await fetch(`${DEEPL_BASE_URL}/translate`, {
          method: 'POST',
          headers: {
            'Authorization': `DeepL-Auth-Key ${DEEPL_API_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(deepLRequestBody),
        });

        if (!deepLResponse.ok) {
          console.warn(`[BATCH] DeepL failed for message ${message.id}: ${deepLResponse.status}`);
          failureCount++;
          continue;
        }

        const deepLData = await deepLResponse.json();
        const translatedText = deepLData.translations?.[0]?.text;
        const detectedSourceLang = deepLData.translations?.[0]?.detected_source_language?.toLowerCase();

        if (translatedText && translatedText.trim()) {
          // Update the message with translation and language metadata
          const { error: updateError } = await supabase
            .from("chat_messages")
            .update({ 
              content_translated: translatedText.trim(),
              detected_source_language: detectedSourceLang,
              translated_target_language: targetLanguage.toLowerCase()
            })
            .eq("id", message.id);

          if (updateError) {
            console.error(`[BATCH] Failed to update message ${message.id}:`, updateError);
            failureCount++;
          } else {
            translatedCount++;
            console.log(`[BATCH] ✓ Translated message ${message.id} to ${targetLanguage}`);
          }
        } else {
          failureCount++;
        }
      } catch (err) {
        console.error(`[BATCH] Error translating message ${message.id}:`, err);
        failureCount++;
      }
    }

    console.log(`🔄 [BATCH] Completed: ${translatedCount} translated, ${failureCount} failed`);

    return new Response(
      JSON.stringify({
        success: true,
        translated: translatedCount,
        failed: failureCount,
        total_processed: messages.length,
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error("[BATCH] Fatal error:", error);
    return new Response(
      JSON.stringify({ error: "Batch translation failed", message: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}
