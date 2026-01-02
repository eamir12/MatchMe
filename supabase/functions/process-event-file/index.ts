// supabase/functions/process-event-file/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { extractText } from "jsr:@pdf2txt/core";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const API_KEY = Deno.env.get('GOOGLE_AI_API_KEY');
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;

// --- Helper 1: Call Gemini with TEXT (for PDFs) ---
async function callGeminiWithText(text: string) {
  
  // --- THIS IS THE FIX ---
  // The new prompt is much more specific and handles multilingual text.
  const prompt = `
    You are an event data parser. The following text is from a PDF ticket and may be in English, Hebrew, or a mix of both.
    Extract the event name, venue/location, and start time.
    Return ONLY a valid JSON object with the keys "title", "location", and "date".

    - "title": The full name of the event. Look for "שם האירוע:" or the most prominent text. Example: "מסיבת סוכות".
    - "location": The venue or address. Look for addresses like "רוקח 73 תל אביב" or "HaTa'arucha Street, Tel Aviv-Yafo".
    - "date": The full start date and time as a single, strict ISO 8601 string. Look for dates like "10/10/2025" and times like "22:00" or "22:30". If you cannot determine the full date AND time, set this to null.
    
    Text to parse: "${text}"
  `;
  // --- END FIX ---

  const body = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: { "responseMimeType": "application/json" }
  };
  
  const res = await fetch(GEMINI_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Gemini Text API failed: ${res.status} ${await res.text()}`);
  const data = await res.json();
  return JSON.parse(data.candidates[0].content.parts[0].text);
}

// --- Helper 2: Call Gemini with an IMAGE (for JPG, PNG) ---
async function callGeminiWithImage(fileBuffer: ArrayBuffer, mimeType: string) {
  const prompt = `
    You are an event data parser. This image is a ticket, screenshot, or poster for an event.
    Extract the event name, venue/location, and start time from the image.
    Return ONLY a valid JSON object with the keys "title", "location", and "date".
    - "title": The full name of the event.
    - "location": The venue or address. If not found, set to null.
    - "date": The full start date and time as a single, strict ISO 8601 string (like "2025-10-31T22:30:00.000Z"). If you can't find a full date and time, set to null.
  `;
  const body = {
    contents: [
      { parts: [ { text: prompt }, { inlineData: { mimeType: mimeType, data: btoa(String.fromCharCode(...new Uint8Array(fileBuffer))) } } ] }
    ],
    generationConfig: { "responseMimeType": "application/json" }
  };
  const res = await fetch(GEMINI_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Gemini Image API failed: ${res.status} ${await res.text()}`);
  const data = await res.json();
  return JSON.parse(data.candidates[0].content.parts[0].text);
}

// --- Main Function ---
serve(async (req) => {
  console.log("--- process-event-file function invoked ---");
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const body = await req.json();
    const { filePath, bucketId } = body;
    if (!filePath || !bucketId) throw new Error("Invalid request body. 'filePath' or 'bucketId' not found.");
    
    const fileExt = filePath.split('.').pop()?.toLowerCase();
    const userId = filePath.split('/')[0];
    
    console.log(`Processing file: ${filePath}, type: ${fileExt}, user: ${userId}`);

    if (!API_KEY) throw new Error('API key not set in Supabase secrets');
    
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { data: fileData, error: downloadError } = await supabaseAdmin.storage
      .from(bucketId)
      .download(filePath);
    if (downloadError) throw new Error(`Failed to download file: ${downloadError.message}`);

    const fileBuffer = await fileData.arrayBuffer();
    let parsedData: any;

    if (fileExt === 'pdf') {
      console.log("Extracting text from PDF...");
      const rawText = await extractText(new Uint8Array(fileBuffer));
      console.log("Raw text (first 500 chars):", rawText.substring(0, 500));
      parsedData = await callGeminiWithText(rawText.substring(0, 8000));
    } else if (['png', 'jpg', 'jpeg'].includes(fileExt ?? '')) {
      console.log("Extracting data from Image (Gemini Vision)...");
      const mimeType = (fileExt === 'png') ? 'image/png' : 'image/jpeg';
      parsedData = await callGeminiWithImage(fileBuffer, mimeType);
    } else {
      throw new Error(`Unsupported file type: ${fileExt}`);
    }

    console.log("Gemini returned:", parsedData);

    const { error: saveError } = await supabaseAdmin
      .from('event_parse_results')
      .insert({
        'user_id': userId,
        'file_path': filePath,
        'parsed_data': parsedData,
      });
    if (saveError) throw new Error(`Failed to save results: ${saveError.message}`);

    await supabaseAdmin.storage.from(bucketId).remove([filePath]);
    
    return new Response(JSON.stringify(parsedData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (e) {
    console.error("Function Error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
})