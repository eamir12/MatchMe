// supabase/functions/get-event-metadata/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { DOMParser } from "https://deno.land/x/deno_dom@v0.1.36-alpha/deno-dom-wasm.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// Helper to get all visible text from the HTML body
function extractMainText(doc: any): string {
  try {
    doc.querySelectorAll('script, style, nav, footer, header').forEach((el: any) => el.remove());
    let text = doc.querySelector('body')?.textContent || "";
    return text.replace(/\s+/g, ' ').trim();
  } catch (e) {
    console.error("Error extracting text:", e.message);
    return "";
  }
}

// Helper to call the Google AI API
async function callGemini(text: string, apiKey: string) {
  
  // Use the model name you confirmed is working
  const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`;
  
  // --- THIS IS THE FIX ---
  // Updated prompt to be more flexible and return both a parsed date AND a raw string
  const prompt = `
    You are an event data parser. Extract the event name, venue/location, and start time from the following text.
    Return ONLY a valid JSON object with the keys "title", "location", "date" (ISO 8601), and "dateString" (raw text).

    - "title": The full name of the event.
    - "location": The venue or address. If not found, set to null.
    - "date": The full start date and time as a single, strict ISO 8601 string (like "2025-10-31T22:30:00.000Z"). If you cannot determine the full date AND time, set this to null.
    - "dateString": The raw text for the event's date and time (e.g., "Friday, October 31 at 10:30 PM" or "31.10 | 22:30"). If not found, set to null.
    
    Text to parse: "${text}"
  `;
  // --- END FIX ---

  const body = {
    contents: [
      { parts: [{ text: prompt }] }
    ],
    generationConfig: {
      "responseMimeType": "application/json",
    }
  };

  const res = await fetch(GEMINI_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    throw new Error(`Gemini API request failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  return JSON.parse(data.candidates[0].content.parts[0].text);
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { url } = await req.json();
    if (!url) throw new Error('No URL provided');
    console.log("Parsing URL:", url);

    const API_KEY = Deno.env.get('GOOGLE_AI_API_KEY');
    if (!API_KEY) throw new Error('API key not set in Supabase secrets');

    const res = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
      }
    });
    
    if (!res.ok) throw new Error(`Failed to fetch URL: ${res.status}`);
    
    const html = await res.text();
    const doc = new DOMParser().parseFromString(html, 'text/html');
    if (!doc) throw new Error('Failed to parse HTML');

    const pageText = extractMainText(doc);
    if (pageText.length < 50) {
      console.log("Not enough text on page to parse, sending title only.");
      const title = doc.querySelector('title')?.textContent.trim() || 'Event from Link';
      return new Response(JSON.stringify({ title: title, location: null, date: null, dateString: null }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    console.log("Sending text to Gemini for parsing...");
    const parsedData = await callGemini(pageText.substring(0, 8000), API_KEY); 

    console.log("Gemini returned:", parsedData);

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