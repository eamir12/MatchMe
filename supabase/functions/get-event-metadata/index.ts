// supabase/functions/get-event-metadata/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { DOMParser } from "https://deno.land/x/deno_dom@v0.1.36-alpha/deno-dom-wasm.ts"
import { createClient } from "npm:@supabase/supabase-js@2.28.0";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { buildGeminiUrl, resolveTextModels } from "../_shared/gemini_config.ts";
import { consumeAiRateLimit, getClientIp } from "../_shared/ai_rate_limit.ts";

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const svc = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

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
    console.log(`Translation not found for key: ${key}, locale: ${locale}`, e instanceof Error ? e.message : e);
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

// Helper to get all visible text from the HTML body
function extractMainText(doc: any): string {
  try {
    doc.querySelectorAll('script, style, nav, footer, header').forEach((el: any) => el.remove());
    let text = doc.querySelector('body')?.textContent || "";
    return text.replace(/\s+/g, ' ').trim();
  } catch (e) {
    console.error("Error extracting text:", e instanceof Error ? e.message : e);
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
      console.log(`  Inferred year ${year} for date ${month}/${day} (current year: ${now.getFullYear()})`);
    }
    try {
      const isoDate = `${year}-${month}-${day}T${hours}:${minutes}:00`;
      let parsedDate = new Date(isoDate);
      if (!isNaN(parsedDate.getTime())) {
        // Check if the date is in the past - if so, add one year
        const now = new Date();
        if (parsedDate < now) {
          console.log('  Date is in the past, adding one year');
          parsedDate.setFullYear(parsedDate.getFullYear() + 1);
        }
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
      let parsedDate = new Date(isoDate);
      if (!isNaN(parsedDate.getTime())) {
        // Check if the date is in the past - if so, add one year
        const now = new Date();
        if (parsedDate < now) {
          console.log('  Date is in the past, adding one year');
          parsedDate.setFullYear(parsedDate.getFullYear() + 1);
        }
        console.log('  Parsed as:', parsedDate.toISOString());
        return parsedDate.toISOString();
      }
    } catch (e) {
      console.log('  Failed to parse:', e);
    }
  }
  return null;
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

function isBlockedEventUrl(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch (_) {
    return true;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return true;
  const host = u.hostname.toLowerCase();
  if (!host) return true;
  const blockedHosts = new Set([
    'calendar.google.com',
    'www.google.com',
    'outlook.live.com',
    'outlook.office.com',
    'outlook.office365.com',
    'teams.microsoft.com',
    'meet.google.com',
    'zoom.us',
    'www.zoom.us',
  ]);
  if (blockedHosts.has(host)) return true;
  if (host.endsWith('.zoom.us')) return true;
  return false;
}

function normalizeJoinabilityClassification(input: unknown): 'public' | 'private' | 'uncertain' {
  if (typeof input !== 'string') return 'uncertain';
  const value = input.trim().toLowerCase();
  if (value === 'public' || value === 'private' || value === 'uncertain') {
    return value;
  }
  return 'uncertain';
}

function normalizeConfidence(input: unknown): 'high' | 'medium' | 'low' {
  if (typeof input !== 'string') return 'low';
  const value = input.trim().toLowerCase();
  if (value === 'high' || value === 'medium' || value === 'low') {
    return value;
  }
  return 'low';
}

function buildJoinabilityLogSummary(eventData: Record<string, unknown>) {
  const title = sanitizeEventText(eventData['title'], 180);
  const location = sanitizeEventText(eventData['location'], 220);
  const description = sanitizeEventText(eventData['description'], 1200);
  const url = sanitizeEventText(eventData['url'], 600);
  return {
    provider: typeof eventData['provider'] === 'string' ? eventData['provider'] : null,
    appLocale: typeof eventData['appLocale'] === 'string' ? eventData['appLocale'] : null,
    hasTitle: !!title,
    titleLength: title?.length ?? 0,
    hasLocation: !!location,
    locationLength: location?.length ?? 0,
    hasDescription: !!description,
    descriptionLength: description?.length ?? 0,
    hasUrl: !!url,
    urlHost: typeof eventData['urlHost'] === 'string' ? eventData['urlHost'] : null,
    isAllDay: eventData['isAllDay'] === true,
    startTime: typeof eventData['startTime'] === 'string' ? eventData['startTime'] : null,
    endTime: typeof eventData['endTime'] === 'string' ? eventData['endTime'] : null,
    durationMinutes: typeof eventData['durationMinutes'] === 'number' ? eventData['durationMinutes'] : null,
  };
}

function buildJoinabilityEvidenceText(eventData: Record<string, unknown>): string {
  const rows = [
    `App locale: ${typeof eventData['appLocale'] === 'string' ? eventData['appLocale'] : 'unknown'}`,
    `Provider: ${typeof eventData['provider'] === 'string' ? eventData['provider'] : 'unknown'}`,
    `Title: ${sanitizeEventText(eventData['title'], 180) ?? 'N/A'}`,
    `Location: ${sanitizeEventText(eventData['location'], 220) ?? 'N/A'}`,
    `Description: ${sanitizeEventText(eventData['description'], 1200) ?? 'N/A'}`,
    `URL: ${sanitizeEventText(eventData['url'], 600) ?? 'N/A'}`,
    `URL host: ${sanitizeEventText(eventData['urlHost'], 120) ?? 'N/A'}`,
    `All day: ${eventData['isAllDay'] === true ? 'yes' : 'no'}`,
    `Start time: ${typeof eventData['startTime'] === 'string' ? eventData['startTime'] : 'N/A'}`,
    `End time: ${typeof eventData['endTime'] === 'string' ? eventData['endTime'] : 'N/A'}`,
    `Duration minutes: ${typeof eventData['durationMinutes'] === 'number' ? eventData['durationMinutes'] : 'N/A'}`,
  ];
  return rows.join('\n');
}

// Helper to call the Google AI API
async function callGemini(text: string, apiKey: string) {
  const textModels = await resolveTextModels(apiKey);
  const geminiUrls = textModels.map(m => buildGeminiUrl(m, apiKey));
  
  const prompt = `
    You are an expert public-event parser. Extract ONLY public, joinable event information from the given text.
    Return ONLY a valid JSON object with the keys "title", "location", "dateISO", "dateString", and "isEventContent".
    
    - "isEventContent": BOOLEAN. Set to true ONLY if this is clearly a public event page (a public event that other people can attend/join). Set to false for personal appointments, private meetings, calendar invites, receipts, invoices, and any content that includes personal user details.
    
    - "title": The full name of the event. Be concise. Set to "N/A" if not found.
      Example 1: "HalloQueen w/ The Electric Landladies at Tractor Tavern..." should be "HalloQueen w/ The Electric Landladies".
      Example 2: "מסיבת סוכות" should be "מסיבת סוכות".
    
    - "location": The venue or address. Keep it concise but complete. Set to null if not found.
      Example 1: "Tractor Tavern in Seattle, WA" should be "Tractor Tavern, Seattle, WA".
      Example 2: "אוזן, קינג ג'ורג' 48 תל אביב" should be "אוזן, קינג ג'ורג' 48 תל אביב".

    Never include PII in "title", "location", or "dateString" (no emails, phone numbers, attendee names, order numbers, confirmation codes). If the content contains PII or seems personal/private, set isEventContent=false and keep other fields minimal.
    
    - "dateISO": The event's start date and time as an ISO 8601 string WITHOUT timezone (e.g., "2025-10-31T22:30:00").
      - Parse dates in ANY language or format (English, Hebrew, Arabic, Spanish, French, German, Japanese, Chinese, etc.)
      - Parse dates in ANY regional format (DD/MM/YYYY, MM/DD/YYYY, YYYY-MM-DD, etc.)
      - Include the time if available, otherwise use 00:00:00
      - IMPORTANT: Return the time as it appears on the page in local time. Do NOT convert to UTC. Do NOT add "Z" or timezone offset.
      - The format should be: YYYY-MM-DDTHH:mm:ss (without Z or timezone)
      - Example: If the page shows "10:30 PM" in Tel Aviv, return "2025-10-31T22:30:00" (not "2025-10-31T19:30:00.000Z")
      - If the date cannot be determined, set to null
    
    - "dateString": The raw text for the event's date and time as it appears on the page (for display purposes). Set to null if not found.
      Example 1: "Friday, October 31, 2025 at 10:30 PM"
      Example 2: "שישי 31.10 | פתיחת דלתות 22:30"
      Example 3: "24 באוקטובר 2025 בשעה 22:30"
      Example 4: "31 octobre 2025 à 22h30"
      Example 5: "31. Oktober 2025 um 22:30 Uhr"

    Important: Always return isEventContent (true/false). If not a public event, return false and minimal other fields. If a public event, always try to return dateISO if a date is visible, even if time is missing (use 00:00:00). Only set dateISO to null if no date information is found at all.
    
    Text to parse: "${text}"
  `;

  const body = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      "responseMimeType": "application/json",
    }
  };

  for (let i = 0; i < geminiUrls.length; i++) {
    const modelName = textModels[i];
    try {
      console.log(`Calling Gemini (${modelName}) for event metadata...`);
      const res = await fetch(geminiUrls[i], {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (!res.ok) {
        console.warn(`${modelName} failed (${res.status}), trying next...`);
        continue;
      }
      const data = await res.json();
      return { parsed: JSON.parse(data.candidates[0].content.parts[0].text), model: modelName };
    } catch (error) {
      console.warn(`${modelName} error: ${error instanceof Error ? error.message : String(error)}, trying next...`);
    }
  }
  throw new Error(`Gemini API failed: All ${textModels.length} models exhausted`);
}

async function callGeminiForJoinability(eventData: Record<string, unknown>, apiKey: string) {
  const textModels = await resolveTextModels(apiKey);
  const geminiUrls = textModels.map(m => buildGeminiUrl(m, apiKey));
  const evidenceText = buildJoinabilityEvidenceText(eventData);

  const prompt = `
    You classify calendar events for a social app.
    Determine whether the event is:
    - "public": a real public event that other app users could reasonably attend or join
    - "private": a personal, internal, invitation-only, or otherwise non-joinable event
    - "uncertain": there is not enough evidence to safely decide

    Return ONLY valid JSON with these keys:
    {
      "classification": "public" | "private" | "uncertain",
      "confidence": "high" | "medium" | "low",
      "reason": string
    }

    Rules:
    - Work for ALL languages and writing systems.
    - Do not rely on English-only wording. The event may be written in English, Hebrew, Spanish, Arabic, French, German, Portuguese, Russian, Japanese, Chinese, or mixed languages.
    - Use every field provided: title, location, description, URL, provider, locale, all-day flag, start/end time, duration, and URL host.
    - Treat concerts, festivals, exhibitions, public classes, meetups, conferences, sports events, public parties, public screenings, and public ticketed events as "public".
    - Treat doctor visits, therapy, work meetings, internal team meetings, 1:1 calls, family plans, reminders, reservations, travel, private calendar holds, and personal errands as "private".
    - A physical venue alone does not guarantee a public event. Consider whether the title, description, link, timing, and other metadata indicate that other app users could realistically attend.
    - An event can still be public without a ticket URL if the metadata clearly describes a public gathering.
    - If metadata is incomplete or mixed, return "uncertain".
    - Prefer privacy: if the event might be private, do not classify it as public.
    - A generic calendar link, video meeting link, or lack of public context is not enough on its own to make the event public.
    - The "reason" must be short and must not include personal data.
    - Base the answer on the event itself, not on the app locale.

    Event metadata as JSON:
    ${JSON.stringify(eventData)}

    Event metadata as text:
    ${evidenceText}
  `;

  const body = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      "responseMimeType": "application/json",
    }
  };

  for (let i = 0; i < geminiUrls.length; i++) {
    const modelName = textModels[i];
    try {
      console.log(`Joinability: calling Gemini (${modelName})`, JSON.stringify(buildJoinabilityLogSummary(eventData)));
      const res = await fetch(geminiUrls[i], {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (!res.ok) {
        console.warn(`Joinability: ${modelName} failed (${res.status}), trying next...`);
        continue;
      }
      console.log(`Joinability: ${modelName} responded successfully`);
      const data = await res.json();
      return { parsed: JSON.parse(data.candidates[0].content.parts[0].text), model: modelName };
    } catch (error) {
      console.warn(`Joinability: ${modelName} error: ${error instanceof Error ? error.message : String(error)}, trying next...`);
    }
  }
  throw new Error(`Gemini Joinability API failed: All ${textModels.length} models exhausted`);
}

// --- Main Function ---
serve(async (req) => {
  console.log("--- get-event-metadata function invoked ---");
  
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  
  const requestId = crypto.randomUUID();
  const startedAtMs = Date.now();
  const functionName = "get-event-metadata";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;
  let aiUsed = false;
  let aiModel: string | null = null;
  let aiTask: string | null = null;

  const jsonResponse = (body: Record<string, unknown>, status = 200) => {
    httpStatus = status;
    success = status < 400;
    return new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  };

  try {
    const body = await req.json();
    const url =
      typeof body?.url === 'string'
        ? body.url.trim()
        : '';
    const eventValidation =
      body?.eventValidation && typeof body.eventValidation === 'object'
        ? body.eventValidation as Record<string, unknown>
        : null;

    // AI rate limiting (app_config ai.rate_limit.event_metadata.*). This
    // function has no user context, so the limit is per hashed client IP;
    // one unit covers the whole request (metadata or joinability).
    {
      const rateLimit = await consumeAiRateLimit(svc, {
        task: 'event_metadata',
        userId: null,
        ip: getClientIp(req),
      });
      if (!rateLimit.allowed) {
        return jsonResponse(
          { error: 'Too many requests. Please try again later.', retryAfterSeconds: rateLimit.retryAfterSeconds },
          429,
        );
      }
    }

    if (eventValidation != null) {
      const API_KEY = Deno.env.get('GOOGLE_AI_API_KEY');
      if (!API_KEY) throw new Error('API key not set in Supabase secrets');

      const payload = {
        title: sanitizeEventText(eventValidation['title'], 180),
        location: sanitizeEventText(eventValidation['location'], 220),
        description: sanitizeEventText(eventValidation['description'], 1200),
        url: sanitizeEventText(eventValidation['url'], 600),
        provider:
          typeof eventValidation['provider'] === 'string'
            ? eventValidation['provider']
            : null,
        appLocale:
          typeof eventValidation['appLocale'] === 'string'
            ? sanitizeEventText(eventValidation['appLocale'], 32)
            : null,
        isAllDay: eventValidation['isAllDay'] === true,
        startTime:
          typeof eventValidation['startTime'] === 'string'
            ? eventValidation['startTime']
            : null,
        endTime:
          typeof eventValidation['endTime'] === 'string'
            ? eventValidation['endTime']
            : null,
        durationMinutes:
          typeof eventValidation['durationMinutes'] === 'number' &&
          Number.isFinite(eventValidation['durationMinutes'])
            ? Math.max(0, Math.round(eventValidation['durationMinutes']))
            : null,
        urlHost:
          typeof eventValidation['urlHost'] === 'string'
            ? sanitizeEventText(eventValidation['urlHost'], 120)
            : null,
      };

      console.log("Joinability: request received", JSON.stringify(buildJoinabilityLogSummary(payload)));

      const geminiResult = await callGeminiForJoinability(payload, API_KEY);
      aiUsed = true;
      aiModel = geminiResult.model;
      aiTask = 'event_joinability';

      const parsed = geminiResult.parsed ?? {};
      const classification = normalizeJoinabilityClassification(parsed.classification);
      const confidence = normalizeConfidence(parsed.confidence);
      const reason = sanitizeEventText(parsed.reason, 240);
      console.log(
        "Joinability: classification result",
        JSON.stringify({
          classification,
          confidence,
          reason,
          model: aiModel,
        }),
      );
      return jsonResponse({
        classification,
        confidence,
        reason,
      });
    }

    if (!url) throw new Error('No URL provided');
    console.log("Parsing URL:", url);

    if (isBlockedEventUrl(url)) {
      errorMessage = await getTranslation('eventExtractionNotEventContent', 'en');
      return jsonResponse({ 
        error: errorMessage,
        errorKey: 'eventExtractionNotEventContent',
        isEventContent: false
      }, 400);
    }

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
      return jsonResponse({ title: title, location: null, dateString: null, date: null });
    }

    console.log("Sending text to Gemini for parsing...");
    const geminiResult = await callGemini(pageText.substring(0, 8000), API_KEY);
    aiUsed = true;
    aiModel = geminiResult.model;
    aiTask = 'event_metadata';
    const parsedData = geminiResult.parsed;
    console.log("Gemini returned:", parsedData);

    const sanitizedTitle = sanitizeEventText(parsedData?.title, 180);
    const sanitizedLocation = sanitizeEventText(parsedData?.location, 220);
    const sanitizedDateString = sanitizeEventText(parsedData?.dateString, 240);
    
    // Validate if content is event-related
    const eventContentValidation = isEventRelated(parsedData);
    if (!eventContentValidation.valid) {
      console.log('Content is not event-related. Reason:', eventContentValidation.reason);
      errorMessage = await getTranslation(eventContentValidation.reason || 'eventExtractionNotEventContent', 'en');
      return jsonResponse({ 
        error: errorMessage,
        errorKey: eventContentValidation.reason,
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
            // Check if the date is in the past - if so, add one year
            const now = new Date();
            if (testDate < now) {
              console.log('Gemini provided date is in the past, adding one year');
              testDate.setFullYear(testDate.getFullYear() + 1);
              dateStr = testDate.toISOString().split('T')[0] + 'T' + dateStr.split('T')[1];
            }
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
    
    const result = {
      title: sanitizedTitle,
      location: sanitizedLocation,
      dateString: sanitizedDateString || null,
      date: isoDate
    };
    
    console.log('Final result:', result);

    return jsonResponse(result);

  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    console.error("Function Error:", errMsg);
    errorType = e instanceof Error ? e.name : "Error";
    errorMessage = errMsg;
    return jsonResponse({ error: errMsg }, 500);
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
      aiUsed,
      aiProvider: aiUsed ? "google_gemini" : null,
      aiModel,
      aiTask,
      meta: { method: req.method },
    });
  }
})
