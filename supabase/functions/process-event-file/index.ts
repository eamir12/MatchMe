// @ts-nocheck
import { createClient } from "npm:@supabase/supabase-js@2.28.0";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { buildGeminiUrl, resolveVisionModels } from "../_shared/gemini_config.ts";

console.info('process-event-file function starting');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

if (!SUPABASE_URL || !SERVICE_ROLE) {
  console.error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
}

const svc = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Helper to fetch localized translation from the translations table.
// MatchMe ships en / es / he only; anything else resolves to English.
function normalizeSupportedLocale(raw: unknown): string {
  const s = String(raw ?? '').trim().toLowerCase();
  if (s.startsWith('he')) return 'he';
  if (s.startsWith('es')) return 'es';
  return 'en';
}

async function getTranslation(key: string, locale: string = 'en'): Promise<string> {
  locale = normalizeSupportedLocale(locale);
  try {
    const result = await svc
      .from('translations')
      .select('value')
      .eq('key', key)
      .eq('locale', locale)
      .single();
    
    if (result.data && result.data.value) {
      return result.data.value;
    }
  } catch (e) {
    console.log(`Translation not found for key: ${key}, locale: ${locale}`, e.message);
  }
  
  // Fallback: English fallback text
  const fallbacks: { [key: string]: string } = {
    'eventExtractionNotEventContent': 'The provided file or link does not contain event information. Please share an event ticket, flyer, or event page.',
    'eventExtractionInvalidFormat': 'Unable to extract event details. Please try uploading a clearer image or different event source.',
    'eventExtractionMissingRequiredData': 'Could not find event date or title. Please provide a document with clear event information.',
  };
  
  return fallbacks[key] || 'Invalid document format. Please provide valid event information.';
}

// Helper to check if content is event-related based on Gemini response
function isEventRelated(parsedData: any): { valid: boolean; reason?: string } {
  // Check if we have event-related data
  if (!parsedData) {
    return { valid: false, reason: 'eventExtractionNotEventContent' };
  }
  
  // At least title or date should be present for valid event
  const hasTitle = parsedData.title && parsedData.title.trim().length > 0 && parsedData.title !== 'N/A';
  const hasDate = parsedData.dateISO || parsedData.dateString;
  
  if (!hasTitle && !hasDate) {
    return { valid: false, reason: 'eventExtractionMissingRequiredData' };
  }
  
  // Check if the response indicates non-event content (Gemini will set special markers)
  if (parsedData.isEventContent === false) {
    return { valid: false, reason: 'eventExtractionNotEventContent' };
  }
  
  return { valid: true };
}

function sanitizeEventText(input: unknown, maxLen: number): string | null {
  if (typeof input !== 'string') return null;
  let s = input.trim();
  if (!s) return null;
  s = s.replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '').trim();
  s = s.replace(/(\+?\d[\d\s().-]{6,}\d)/g, '').trim();
  s = s.replace(/\s+/g, ' ').trim();
  if (s.length > maxLen) s = s.slice(0, maxLen).trim();
  return s || null;
}

function containsPii(input: string | null): boolean {
  if (!input) return false;
  if (/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(input)) return true;
  if (/(\+?\d[\d\s().-]{6,}\d)/.test(input)) return true;
  return false;
}

function looksPersonalTitle(input: string | null): boolean {
  if (!input) return false;
  return /\b(birthday|anniversary|dentist|doctor|therapy|appointment|1:1|one[-\s]?on[-\s]?one|meeting|sync|call|interview|school|pickup|drop[-\s]?off|flight|reservation|invoice|receipt|dinner|lunch|brunch|coffee|drinks?|date\s*night|hangout|hang\s*out|catch\s*up|catchup)\b/i.test(
    input,
  );
}

function looksPersonalLocation(input: string | null): boolean {
  if (!input) return false;
  return /\b(home|my place|house|apartment|apt\.?|unit\s+\d+)\b/i.test(input);
}

// Helper to parse dateString into ISO format (copied from get-event-metadata)
function parseDateString(dateStr: string): string | null {
  if (!dateStr) return null;
  console.log('Parsing dateString:', dateStr);

  // Hebrew month names mapping
  const hebrewMonths: { [key: string]: number } = {
    'ינואר': 1, 'פברואר': 2, 'מרץ': 3, 'מרס': 3, 'מארס': 3,
    'אפריל': 4, 'מאי': 5, 'יוני': 6, 'יולי': 7, 'אוגוסט': 8,
    'ספטמבר': 9, 'אוקטובר': 10, 'נובמבר': 11, 'דצמבר': 12,
    // With ב prefix
    'בינואר': 1, 'בפברואר': 2, 'במרץ': 3, 'במרס': 3, 'במארס': 3,
    'באפריל': 4, 'במאי': 5, 'ביוני': 6, 'ביולי': 7, 'באוגוסט': 8,
    'בספטמבר': 9, 'באוקטובר': 10, 'בנובמבר': 11, 'בדצמבר': 12
  };

  // Clean the string
  let cleanedStr = dateStr.replace(/יום\s+\S+[,\s]*/g, '').replace(/[|]/g, ' ').trim();
  
  // If it's a date range, extract the start date (before the dash)
  if (cleanedStr.includes(' - ')) {
    cleanedStr = cleanedStr.split(' - ')[0].trim();
  }

  // Try Hebrew month format: "24 באוקטובר 2025 בשעה 22:30" or "24 אוקטובר 2025 22:30"
  // Match Hebrew letters including ב if present - use Unicode Hebrew range
  const hebrewMonthPattern = /(\d{1,2})\s+([\u0590-\u05FF]+)\s+(\d{4})(?:\s+בשעה\s+)?(?:(\d{1,2}):(\d{2}))?/;
  const hebrewMatch = cleanedStr.match(hebrewMonthPattern);
  if (hebrewMatch) {
    const day = hebrewMatch[1].padStart(2, '0');
    const hebrewMonth = hebrewMatch[2]; // This will capture Hebrew letters including ב if present
    const year = hebrewMatch[3];
    // Try to find month number - check both with and without ב prefix
    let monthNum = hebrewMonths[hebrewMonth] || 
                   (hebrewMonth.startsWith('ב') ? hebrewMonths[hebrewMonth.substring(1)] : hebrewMonths['ב' + hebrewMonth]);
    
    if (monthNum) {
      const month = monthNum.toString().padStart(2, '0');
      let hours = '00';
      let minutes = '00';
      
      if (hebrewMatch[4] && hebrewMatch[5]) {
        hours = hebrewMatch[4].padStart(2, '0');
        minutes = hebrewMatch[5];
      } else {
        // Try to find time separately
        const timeMatch = cleanedStr.match(/(\d{1,2}):(\d{2})/);
        if (timeMatch) {
          hours = timeMatch[1].padStart(2, '0');
          minutes = timeMatch[2];
        }
      }
      
      try {
        const isoDate = `${year}-${month}-${day}T${hours}:${minutes}:00`;
        const parsedDate = new Date(isoDate);
        if (!isNaN(parsedDate.getTime())) {
          console.log('  Parsed Hebrew date as:', parsedDate.toISOString());
          return parsedDate.toISOString();
        }
      } catch (e) {
        console.log('  Failed to parse Hebrew date:', e);
      }
    }
  }

  // International month names mapping (deduped across languages)
  const monthNames: { [key: string]: number } = {};
  const addMonth = (name: string, value: number) => {
    if (!(name in monthNames)) {
      monthNames[name] = value;
    }
  };

  const monthTuples: Array<[string, number]> = [
    // English
    ['january', 1], ['february', 2], ['march', 3], ['april', 4], ['may', 5], ['june', 6],
    ['july', 7], ['august', 8], ['september', 9], ['october', 10], ['november', 11], ['december', 12],
    ['jan', 1], ['feb', 2], ['mar', 3], ['apr', 4], ['jun', 6],
    ['jul', 7], ['aug', 8], ['sep', 9], ['oct', 10], ['nov', 11], ['dec', 12],
    // French
    ['janvier', 1], ['février', 2], ['fevrier', 2], ['mars', 3], ['avril', 4], ['mai', 5], ['juin', 6],
    ['juillet', 7], ['août', 8], ['aout', 8], ['septembre', 9], ['octobre', 10], ['novembre', 11], ['décembre', 12],
    // German
    ['januar', 1], ['februar', 2], ['märz', 3], ['marz', 3], ['april', 4], ['mai', 5], ['juni', 6],
    ['juli', 7], ['august', 8], ['september', 9], ['oktober', 10], ['dezember', 12],
    // Spanish
    ['enero', 1], ['febrero', 2], ['marzo', 3], ['abril', 4], ['mayo', 5], ['junio', 6],
    ['julio', 7], ['agosto', 8], ['septiembre', 9], ['octubre', 10], ['noviembre', 11], ['diciembre', 12],
    // Italian
    ['gennaio', 1], ['febbraio', 2], ['aprile', 4], ['maggio', 5], ['giugno', 6],
    ['luglio', 7], ['settembre', 9], ['ottobre', 10], ['dicembre', 12],
    // Portuguese
    ['janeiro', 1], ['fevereiro', 2], ['março', 3], ['marco', 3], ['maio', 5], ['junho', 6],
    ['julho', 7], ['setembro', 9], ['outubro', 10], ['novembro', 11], ['dezembro', 12],
    // Russian (transliterated)
    ['yanvar', 1], ['fevral', 2], ['mart', 3], ['aprel', 4], ['may', 5], ['iyun', 6],
    ['iyul', 7], ['avgust', 8], ['sentyabr', 9], ['oktyabr', 10], ['noyabr', 11], ['dekabr', 12],
  ];

  monthTuples.forEach(([name, value]) => addMonth(name, value));
  
  // Try English month format: "October 13, 2025 9:30 PM" or "Oct 13, 2025 at 9:30 PM"
  // Also handles other languages: "31 octobre 2025 à 22h30", "31. Oktober 2025 um 22:30 Uhr", etc.
  const englishMonths = monthNames;
  
  // Try international month name formats
  // Patterns: "October 13, 2025 9:30 PM", "31 octobre 2025 à 22h30", "31. Oktober 2025 um 22:30 Uhr"
  // Match month names (with accents), day, year, and optional time
  // More flexible pattern to handle different languages and formats
  const internationalMonthPattern = /(\d{1,2})[\.\s]*([a-zàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿžščćđ]+)[\s,]+(\d{4})(?:\s*(?:à|at|um|a|las|om|kl|@)?\s*(\d{1,2})[h:\.](\d{2})(?:\s*(AM|PM|am|pm|Uhr|h)?))?/i;
  const internationalMatch = cleanedStr.match(internationalMonthPattern);
  
  if (internationalMatch) {
    const day = internationalMatch[1].padStart(2, '0');
    const monthName = internationalMatch[2].toLowerCase().replace(/[^a-zàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿžščćđ]/g, '');
    const year = internationalMatch[3];
    const monthNum = monthNames[monthName];
    
    console.log('International date pattern match:', { day, monthName, year, monthNum });
    
    if (monthNum) {
      const month = monthNum.toString().padStart(2, '0');
      let hours = '00';
      let minutes = '00';
      
      // Extract time - check if it was captured in the main pattern first
      if (internationalMatch[4] && internationalMatch[5]) {
        let hour24 = parseInt(internationalMatch[4]);
        const ampm = (internationalMatch[6] || '').toUpperCase();
        
        console.log('  Extracted time from pattern:', hour24, internationalMatch[5], ampm);
        
        // Convert to 24-hour format
        if (ampm === 'PM' && hour24 < 12) {
          hour24 += 12;
        } else if (ampm === 'AM' && hour24 === 12) {
          hour24 = 0;
        }
        
        hours = hour24.toString().padStart(2, '0');
        minutes = internationalMatch[5];
      } else {
        // Try to find time separately in the string - handle various formats
        // Patterns: "22:30", "22h30", "10:30 PM", "22.30", etc.
        const timePatterns = [
          /(\d{1,2}):(\d{2})\s*(AM|PM)/i,  // 10:30 PM
          /(\d{1,2})h(\d{2})/i,            // 22h30 (French/European)
          /(\d{1,2}):(\d{2})/i,            // 22:30 (24-hour)
          /(\d{1,2})\.(\d{2})/i            // 22.30 (European with dot)
        ];
        
        for (const pattern of timePatterns) {
          const timeMatch = cleanedStr.match(pattern);
          if (timeMatch) {
            let hour24 = parseInt(timeMatch[1]);
            const ampm = (timeMatch[3] || '').toUpperCase();
            
            console.log('  Found time separately:', hour24, timeMatch[2], ampm);
            
            if (ampm === 'PM' && hour24 < 12) {
              hour24 += 12;
            } else if (ampm === 'AM' && hour24 === 12) {
              hour24 = 0;
            }
            
            hours = hour24.toString().padStart(2, '0');
            minutes = timeMatch[2];
            break;
          }
        }
      }
      
      try {
        const isoDate = `${year}-${month}-${day}T${hours}:${minutes}:00`;
        const parsedDate = new Date(isoDate);
        if (!isNaN(parsedDate.getTime())) {
          console.log('  Parsed international date as:', parsedDate.toISOString());
          return parsedDate.toISOString();
        }
      } catch (e) {
        console.log('  Failed to parse international date:', e);
      }
    }
  }
  
  // Also try English-specific patterns for better matching (more restrictive but accurate)
  const englishMonthPattern = /(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})(?:,\s*|\s+)(\d{4})(?:\s+(?:at\s+)?(\d{1,2}):(\d{2})\s*(AM|PM))?/i;
  const englishMatch = cleanedStr.match(englishMonthPattern);
  if (englishMatch) {
    const monthName = englishMatch[1].toLowerCase();
    const day = englishMatch[2].padStart(2, '0');
    const year = englishMatch[3];
    const monthNum = englishMonths[monthName];
    
    if (monthNum) {
      const month = monthNum.toString().padStart(2, '0');
      let hours = '00';
      let minutes = '00';
      
      if (englishMatch[4] && englishMatch[5]) {
        let hour24 = parseInt(englishMatch[4]);
        const ampm = (englishMatch[6] || '').toUpperCase();
        
        if (ampm === 'PM' && hour24 < 12) {
          hour24 += 12;
        } else if (ampm === 'AM' && hour24 === 12) {
          hour24 = 0;
        }
        
        hours = hour24.toString().padStart(2, '0');
        minutes = englishMatch[5];
      } else {
        const timeMatch = cleanedStr.match(/(\d{1,2}):(\d{2})\s*(AM|PM)/i);
        if (timeMatch) {
          let hour24 = parseInt(timeMatch[1]);
          const ampm = (timeMatch[3] || '').toUpperCase();
          
          if (ampm === 'PM' && hour24 < 12) {
            hour24 += 12;
          } else if (ampm === 'AM' && hour24 === 12) {
            hour24 = 0;
          }
          
          hours = hour24.toString().padStart(2, '0');
          minutes = timeMatch[2];
        }
      }
      
      try {
        const isoDate = `${year}-${month}-${day}T${hours}:${minutes}:00`;
        const parsedDate = new Date(isoDate);
        if (!isNaN(parsedDate.getTime())) {
          console.log('  Parsed English date as:', parsedDate.toISOString());
          return parsedDate.toISOString();
        }
      } catch (e) {
        console.log('  Failed to parse English date:', e);
      }
    }
  }

  // Try to extract date and time pattern like '16.12 11:00' or '16/12 11:00'
  const dateTimeMatch = cleanedStr.match(/(\d{1,2})[\.\/](\d{1,2})\s+(\d{1,2}):(\d{2})/);
  if (dateTimeMatch) {
    let day = dateTimeMatch[1].padStart(2, '0');
    let month = dateTimeMatch[2].padStart(2, '0');
    let hours = dateTimeMatch[3].padStart(2, '0');
    let minutes = dateTimeMatch[4].padStart(2, '0');
    let year = null;

    // Try to find year in string
    const yearMatch = cleanedStr.match(/(\d{4})/);
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
  const dateMatch = cleanedStr.match(/(\d{1,2})[\.\/](\d{1,2})[\.\/](\d{2,4})/);
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
    const timeMatch = cleanedStr.match(/(\d{1,2}):(\d{2})/);
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

// Helper to convert Uint8Array to base64 without stack overflow
function uint8ArrayToBase64(bytes: Uint8Array): string {
  // Process in chunks to avoid "Maximum call stack size exceeded"
  const chunkSize = 0x8000; // 32KB chunks
  let result = '';
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    result += String.fromCharCode(...chunk);
  }
  return btoa(result);
}

// Helper to call Gemini API with vision support for images and PDFs
async function callGeminiVision(fileBytes: Uint8Array, mimeType: string, apiKey: string) {
  const visionModels = await resolveVisionModels(apiKey);
  const geminiUrls = visionModels.map(m => buildGeminiUrl(m, apiKey));
  
  // Convert bytes to base64 using chunked approach to handle large files
  const base64Data = uint8ArrayToBase64(fileBytes);
  
  const prompt = `
    You are an expert public-event parser. Extract ONLY public, joinable event information from this ticket or event document.
    Return ONLY a valid JSON object with the keys "title", "location", "dateISO", "dateString", and "isEventContent".
    
    - "isEventContent": BOOLEAN. Set to true ONLY if this is clearly a public event ticket/flyer/event document (a public event that other people can attend/join). Set to false for personal appointments, private meetings, calendar invites, receipts, invoices, and any content that includes personal user details.
    
    - "title": The full name of the event. Be concise. Set to "N/A" if not found.
      Example 1: "HalloQueen w/ The Electric Landladies at Tractor Tavern..." should be "HalloQueen w/ The Electric Landladies".
      Example 2: "מסיבת סוכות" should be "מסיבת סוכות".
    
    - "location": The venue or address. Keep it concise but complete. Set to null if not found.
      Example 1: "Tractor Tavern in Seattle, WA" should be "Tractor Tavern, Seattle, WA".
      Example 2: "אוזן, קינג ג'ורג' 48 תל אביב" should be "אוזן, קינג ג'ורג' 48 תל אביב".

    Never include PII in "title", "location", or "dateString" (no emails, phone numbers, attendee names, order numbers, confirmation codes). If the document contains PII or seems personal/private, set isEventContent=false and keep other fields minimal.
    
    - "dateISO": The event's start date and time as an ISO 8601 string WITHOUT timezone (e.g., "2025-10-31T22:30:00").
      - Parse dates in ANY language or format (English, Hebrew, Arabic, Spanish, French, German, Japanese, Chinese, etc.)
      - Parse dates in ANY regional format (DD/MM/YYYY, MM/DD/YYYY, YYYY-MM-DD, etc.)
      - Include the time if available, otherwise use 00:00:00
      - IMPORTANT: Return the time as it appears on the document in local time. Do NOT convert to UTC. Do NOT add "Z" or timezone offset.
      - The format should be: YYYY-MM-DDTHH:mm:ss (without Z or timezone)
      - Example: If the ticket shows "10:30 PM" in Tel Aviv, return "2025-10-31T22:30:00" (not "2025-10-31T19:30:00.000Z")
      - If the date cannot be determined, set to null
    
    - "dateString": The raw text for the event's date and time as it appears on the document (for display purposes). Set to null if not found.
      Example 1: "Friday, October 31, 2025 at 10:30 PM"
      Example 2: "שישי 31.10 | פתיחת דלתות 22:30"
      Example 3: "24 באוקטובר 2025 בשעה 22:30"
      Example 4: "31 octobre 2025 à 22h30"
      Example 5: "31. Oktober 2025 um 22:30 Uhr"

    Important: Always return isEventContent (true/false). If not a public event, return false and minimal other fields. If a public event, always try to return dateISO if a date is visible, even if time is missing (use 00:00:00). Only set dateISO to null if no date information is found at all.
  `;

  const body = {
    contents: [{
      parts: [
        { text: prompt },
        {
          inline_data: {
            mime_type: mimeType,
            data: base64Data
          }
        }
      ]
    }],
    generationConfig: {
      "responseMimeType": "application/json",
    }
  };

  for (let i = 0; i < geminiUrls.length; i++) {
    const modelName = visionModels[i];
    try {
      console.log(`Calling Gemini Vision (${modelName})...`);
      const res = await fetch(geminiUrls[i], {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (!res.ok) {
        const errorText = await res.text();
        console.warn(`${modelName} failed (${res.status}): ${errorText}`);
        continue;
      }

      const data = await res.json();
      return { parsed: JSON.parse(data.candidates[0].content.parts[0].text), model: modelName };
    } catch (error) {
      console.warn(`${modelName} error: ${error.message}, trying next...`);
    }
  }
  throw new Error(`Gemini Vision API failed: All ${visionModels.length} models exhausted`);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAtMs = Date.now();
  const functionName = "process-event-file";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;
  let userIdForLog: string | null = null;
  let aiUsed = false;
  let aiModel: string | null = null;

  const jsonResponse = (body: Record<string, unknown>, status = 200) => {
    httpStatus = status;
    success = status < 400;
    return new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  };

  try {
    if (req.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }

    const contentLength = req.headers.get('content-length');
    const hasBody = contentLength && Number(contentLength) > 0;

    let payload: any = {};
    if (hasBody) {
      const txt = await req.text();
      if (!txt) {
        return jsonResponse({ error: 'Empty body' }, 400);
      }
      try {
        payload = JSON.parse(txt);
      } catch (e: any) {
        console.error('Invalid JSON body', e.message);
        return jsonResponse({ error: 'Invalid JSON' }, 400);
      }
    } else {
      return jsonResponse({ error: 'Missing body' }, 400);
    }

    const filePath = payload?.filePath?.toString?.() ?? "";
    const bucketIdFromClient = payload?.bucketId?.toString?.() ?? "";
    const bucketId = "event-uploads";
    if (!filePath) {
      return jsonResponse({ error: 'Missing filePath' }, 400);
    }
    if (bucketIdFromClient && bucketIdFromClient !== bucketId) {
      return jsonResponse({ error: 'Invalid bucketId' }, 400);
    }

    if (!SUPABASE_URL || !ANON_KEY) {
      return jsonResponse({ error: 'Server is missing env' }, 500);
    }

    const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }

    const authed = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await authed.auth.getUser();
    if (userErr || !userData?.user?.id) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }

    const pathParts = filePath.split('/');
    const userIdInPath = pathParts[0];
    if (!userIdInPath) {
      return jsonResponse({ error: 'Invalid file path format' }, 400);
    }
    userIdForLog = userIdInPath;
    if (userIdInPath !== userData.user.id) {
      return jsonResponse({ error: 'Forbidden' }, 403);
    }

    let fileBytes: Uint8Array | null = null;
    try {
      const { data: fileData, error: downloadError } = await svc.storage
        .from(bucketId)
        .download(filePath);

      if (downloadError) {
        console.error('Storage download error:', downloadError.message);
        return jsonResponse({ error: `Failed to download file: ${downloadError.message}` }, 500);
      }

      if (!fileData) {
        return jsonResponse({ error: 'File data is null' }, 500);
      }

      fileBytes = new Uint8Array(await fileData.arrayBuffer());
    } finally {
      try {
        await svc.storage.from(bucketId).remove([filePath]);
      } catch (e: any) {
        console.error('Best-effort delete failed:', e?.message ?? e);
      }
    }
    
    // Determine MIME type from file extension
    const fileExtension = filePath.split('.').pop()?.toLowerCase() || '';
    let mimeType = 'application/octet-stream';
    switch (fileExtension) {
      case 'pdf':
        mimeType = 'application/pdf';
        break;
      case 'png':
        mimeType = 'image/png';
        break;
      case 'jpg':
      case 'jpeg':
        mimeType = 'image/jpeg';
        break;
    }

    console.log('File type:', mimeType, 'Size:', fileBytes?.length ?? 0, 'bytes');

    // Get API key
    const API_KEY = Deno.env.get('GOOGLE_AI_API_KEY');
    if (!API_KEY) {
      return jsonResponse({ error: 'API key not set in Supabase secrets' }, 500);
    }

    // Process with Gemini Vision API
    console.log('Sending file to Gemini Vision API...');
    if (!fileBytes) {
      return jsonResponse({ error: 'File bytes missing' }, 500);
    }
    const geminiResult = await callGeminiVision(fileBytes, mimeType, API_KEY);
    aiUsed = true;
    aiModel = geminiResult.model;
    const parsedData = geminiResult.parsed;
    console.log('Gemini returned:', parsedData);

    const sanitizedTitle = sanitizeEventText(parsedData?.title, 180);
    const sanitizedLocation = sanitizeEventText(parsedData?.location, 220);
    const sanitizedDateString = sanitizeEventText(parsedData?.dateString, 240);
    
    // Validate if content is event-related
    const eventValidation = isEventRelated(parsedData);
    if (!eventValidation.valid) {
      console.log('Content is not event-related. Reason:', eventValidation.reason);
      errorMessage = await getTranslation(eventValidation.reason || 'eventExtractionNotEventContent', 'en');
      return jsonResponse({ 
        error: errorMessage,
        errorKey: eventValidation.reason,
        isEventContent: false
      }, 400);
    }

    if (
      containsPii(sanitizedTitle) ||
      containsPii(sanitizedLocation) ||
      containsPii(sanitizedDateString) ||
      looksPersonalTitle(sanitizedTitle) ||
      looksPersonalLocation(sanitizedLocation)
    ) {
      errorMessage = await getTranslation('eventExtractionNotEventContent', 'en');
      return jsonResponse({ 
        error: errorMessage,
        errorKey: 'eventExtractionNotEventContent',
        isEventContent: false
      }, 400);
    }

    // Use dateISO from Gemini if available (handles international formats), otherwise fall back to parsing dateString
    let isoDate: string | null = null;
    
    if (parsedData.dateISO) {
      // Gemini provided ISO date - ensure it doesn't have timezone (local time)
      try {
        let dateStr = parsedData.dateISO.trim();
        
        // Check if dateISO has UTC timezone indicator (Z) - if so, Gemini converted to UTC incorrectly
        // In this case, we should parse dateString instead to get the actual local time
        if (dateStr.endsWith('Z') || dateStr.match(/[+-]\d{2}:?\d{2}$/)) {
          console.log('Gemini returned UTC timezone, parsing dateString instead to get local time');
          if (parsedData.dateString) {
            isoDate = parseDateString(parsedData.dateString);
          } else {
            // Remove timezone and use as-is (not ideal but better than nothing)
            dateStr = dateStr.replace(/Z$/, '').replace(/[+-]\d{2}:?\d{2}$/, '');
            dateStr = dateStr.replace(/\.\d{3}$/, '');
            if (dateStr.match(/T\d{2}:\d{2}$/)) {
              dateStr += ':00';
            }
            const testDate = new Date(dateStr);
            isoDate = !isNaN(testDate.getTime()) ? dateStr : null;
          }
        } else {
          // No timezone indicator - treat as local time
          // Remove milliseconds for consistency
          dateStr = dateStr.replace(/\.\d{3}$/, '');
          
          // Ensure it has seconds (ends with :ss format)
          if (dateStr.match(/T\d{2}:\d{2}$/)) {
            dateStr += ':00';
          }
          
          // Validate the date format
          const testDate = new Date(dateStr);
          if (!isNaN(testDate.getTime())) {
            isoDate = dateStr;
            console.log('Using ISO date from Gemini (local time):', isoDate);
          } else {
            console.log('Invalid ISO date from Gemini, falling back to parsing dateString');
            isoDate = parsedData.dateString ? parseDateString(parsedData.dateString) : null;
          }
        }
      } catch (e) {
        console.log('Error processing Gemini ISO date, falling back to parsing dateString:', e);
        isoDate = parsedData.dateString ? parseDateString(parsedData.dateString) : null;
      }
    } else if (parsedData.dateString) {
      // Fall back to our parsing function for international formats
      console.log('No dateISO from Gemini, parsing dateString:', parsedData.dateString);
      isoDate = parseDateString(parsedData.dateString);
    }
    
    // Return in the format expected by Dart client
    const result = {
      title: sanitizedTitle || 'Event from File',
      location: sanitizedLocation || null,
      dateString: sanitizedDateString || null,
      date: isoDate || null
    };

    console.log('Final result:', result);

    // Optionally save to database (if you want to track parsing results)
    try {
      await svc.from('event_parse_results').insert([{
        user_id: userIdInPath,
        file_path: filePath,
        parsed_data: result
      }]);
    } catch (dbError) {
      // Log but don't fail the request if DB insert fails
      console.error('DB insert error (non-fatal):', dbError);
    }

    return jsonResponse(result, 200);
  } catch (err: any) {
    console.error('Function error:', err);
    errorType = err instanceof Error ? err.name : "Error";
    errorMessage = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: errorMessage || 'internal_error' }, 500);
  } finally {
    const elapsedMs = Date.now() - startedAtMs;
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: elapsedMs,
      success,
      httpStatus,
      errorType,
      errorMessage,
      userId: userIdForLog,
      aiUsed,
      aiProvider: aiUsed ? "google_gemini" : null,
      aiModel,
      aiTask: aiUsed ? "event_file_parse" : null,
      meta: { method: req.method },
    });
  }
});
