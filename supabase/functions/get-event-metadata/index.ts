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

// Helper to parse dateString into ISO format
function parseDateString(dateStr: string): string | null {
  if (!dateStr) return null;
  console.log('Parsing dateString:', dateStr);

  // Remove Hebrew day names and extra words
  dateStr = dateStr.replace(/יום\s+\S+[,\s]*/g, '').replace(/[|]/g, ' ').trim();

  // Try to extract date and time pattern like '16.12 11:00' or '16/12 11:00'
  const dateTimeMatch = dateStr.match(/(\d{1,2})[\.\/](\d{1,2})\s+(\d{1,2}):(\d{2})/);
  if (dateTimeMatch) {
    let day = dateTimeMatch[1].padStart(2, '0');
    let month = dateTimeMatch[2].padStart(2, '0');
    let hours = dateTimeMatch[3].padStart(2, '0');
    let minutes = dateTimeMatch[4].padStart(2, '0');
    let year = null;

    // Try to find year in string
    const yearMatch = dateStr.match(/(\d{4})/);
    if (yearMatch) {
      year = yearMatch[1];
    } else {
      // If year not found, infer year: use current year, but if date has already passed, use next year
      const now = new Date();
      year = now.getFullYear().toString();
      const testDate = new Date(`${year}-${month}-${day}T${hours}:${minutes}:00`);
      if (testDate < now) {
        year = (now.getFullYear() + 1).toString();
      }
    }
    try {
      const isoDate = `${year}-${month}-${day}T${hours}:${minutes}:00`;
      const parsedDate = new Date(isoDate);
      if (!isNaN(parsedDate.getTime())) {
        console.log('  Parsed as:', parsedDate.toISOString());
        return parsedDate.toISOString();
      }
    } catch (e) {
      console.log('  Failed to parse:', e);
    }
  }

  // Fallback: original pattern (DD.MM.YY or DD/MM/YYYY)
  const dateMatch = dateStr.match(/(\d{1,2})[\.\/](\d{1,2})[\.\/](\d{2,4})/);
  if (dateMatch) {
    let day = dateMatch[1].padStart(2, '0');
    let month = dateMatch[2].padStart(2, '0');
    let year = dateMatch[3];
    if (year.length === 2) {
      const yy = parseInt(year);
      year = yy <= 35 ? `20${year}` : `19${year}`;
      console.log(`  Converted 2-digit year ${dateMatch[3]} to ${year}`);
    }
    // Try to extract time
    const timeMatch = dateStr.match(/(\d{1,2}):(\d{2})/);
    let hours = '00';
    let minutes = '00';
    if (timeMatch) {
      hours = timeMatch[1].padStart(2, '0');
      minutes = timeMatch[2];
      console.log(`  Found time ${hours}:${minutes}`);
    }
    try {
      const isoDate = `${year}-${month}-${day}T${hours}:${minutes}:00`;
      const parsedDate = new Date(isoDate);
      if (!isNaN(parsedDate.getTime())) {
        console.log('  Parsed as:', parsedDate.toISOString());
        return parsedDate.toISOString();
      }
    } catch (e) {
      console.log('  Failed to parse:', e);
    }
  }
  return null;
}

// Helper to call the Google AI API
async function callGemini(text: string, apiKey: string) {
  const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`;
  
  const prompt = `
    You are an expert event data parser. Your task is to extract the event name, venue/location, and a raw date/time string from the given text.
    Return ONLY a valid JSON object with the keys "title", "location", and "dateString".
    
    - "title": The full name of the event. Be concise.
      Example 1: "HalloQueen w/ The Electric Landladies at Tractor Tavern..." should be "HalloQueen w/ The Electric Landladies".
      Example 2: "מסיבת סוכות" should be "מסיבת סוכות".
    
    - "location": The venue or address.
      Example 1: "Tractor Tavern in Seattle, WA" should be "Tractor Tavern, Seattle, WA".
      Example 2: "אוזן, קינג ג'ורג' 48 תל אביב" should be "אוזן, קינג ג'ורג' 48 תל אביב".
      If not found, set to null.
    
    - "dateString": The raw text for the event's date and time.
      Example 1: "Friday, October 31"
      Example 2: "שישי 31.10 | פתיחת דלתות 22:30"
      If not found, set to null.

    Do not try to parse the date into an ISO string. Only extract the raw text.
    
    Text to parse: "${text}"
  `;

  const body = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      "responseMimeType": "application/json",
    }
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

// --- Main Function ---
serve(async (req) => {
  console.log("--- get-event-metadata function invoked ---");
  
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  
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
      return new Response(JSON.stringify({ title: title, location: null, dateString: null, date: null }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    console.log("Sending text to Gemini for parsing...");
    const parsedData = await callGemini(pageText.substring(0, 8000), API_KEY);
    console.log("Gemini returned:", parsedData);
    
    // Add ISO date parsing
    const isoDate = parseDateString(parsedData.dateString);
    const result = {
      title: parsedData.title,
      location: parsedData.location,
      dateString: parsedData.dateString,
      date: isoDate
    };
    
    console.log('Final result:', result);

    return new Response(JSON.stringify(result), {
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