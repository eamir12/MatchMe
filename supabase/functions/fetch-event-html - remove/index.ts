import { serve } from "https://deno.land/std@0.168.0/http/server.ts";



// Gemini API config
const GEMINI_API_KEY = "AIzaSyDPJnz4YYuST0TmYd35b3azIPPAEDPgmKI";
const GEMINI_URL_PRIMARY = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=${GEMINI_API_KEY}`;
const GEMINI_URL_BACKUP = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}`;

async function callGemini(body: any) {
  try {
    const res = await fetch(GEMINI_URL_PRIMARY, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`Primary API failed: ${res.status} ${await res.text()}`);
    return res;
  } catch (e) {
    console.log("Primary Gemini failed, trying backup...", e);
    return fetch(GEMINI_URL_BACKUP, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
  }
}


const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { url } = await req.json();

    if (!url || !url.startsWith('http')) {
      return new Response(
        JSON.stringify({ error: 'Invalid URL' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const response = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (compatible; EventParser/1.0)',
      },
    });

    if (!response.ok) {
      return new Response(
        JSON.stringify({ error: `Failed to fetch: ${response.status}` }),
        { status: response.status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const html = await response.text();
    const maxHtmlLength = 12000;
    const htmlSnippet = html.length > maxHtmlLength ? html.slice(0, maxHtmlLength) : html;

    // Regex to extract date/time patterns (DD/MM/YYYY, DD-MM-YYYY, YYYY-MM-DD, HH:MM)
    const dateRegex = /(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})|(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})/g;
    const timeRegex = /(\d{1,2}:\d{2})/g;
    const foundDates = htmlSnippet.match(dateRegex) || [];
    const foundTimes = htmlSnippet.match(timeRegex) || [];
    // If regex found a date and time, use them directly
    let extractedDateHint = null;
    let extractedTimeHint = null;
    if (foundDates && foundDates[0]) {
      const dateParts = foundDates[0].split(/[\/\-]/);
      if (dateParts.length === 3) {
        if (dateParts[2] && dateParts[2].length === 4) {
          extractedDateHint = `${dateParts[2]}-${dateParts[1].padStart(2, '0')}-${dateParts[0].padStart(2, '0')}`;
        } else if (dateParts[0] && dateParts[0].length === 4) {
          extractedDateHint = `${dateParts[0]}-${dateParts[1].padStart(2, '0')}-${dateParts[2].padStart(2, '0')}`;
        }
      }
    }
    if (foundTimes && foundTimes[0]) {
      extractedTimeHint = foundTimes[0].padStart(5, '0');
    }

    // If both date and time found, skip Gemini for those fields
    let extractedResult = { title: null, location: null, date: extractedDateHint, time: extractedTimeHint };

    // Only call Gemini for title/location if date/time found
    let geminiNeeded = !extractedDateHint || !extractedTimeHint;
    let geminiOutputText = "";
    if (geminiNeeded) {
      // Combine first found date and time for context
      let dateTimeHint = '';
      if (foundDates && foundDates[0] && foundTimes && foundTimes[0]) {
        dateTimeHint = `The event date and time mentioned in the page is: ${foundDates[0]} ${foundTimes[0]}.`;
      } else if (foundDates && foundDates[0]) {
        dateTimeHint = `The event date mentioned in the page is: ${foundDates[0]}.`;
      }
      const prompt = `${dateTimeHint}\nExtract the event title, location, date, and time from the following HTML. The page may be in Hebrew or English and may use Israeli date/time formats, including formats like DD/MM/YYYY HH:MM, DD-MM-YYYY, YYYY-MM-DD, and times with colons (e.g., 20:00). Look for a set of numbers with slashes, dashes, or a colon between them as the event start date and time. Return a JSON object with keys: title, location, date, time. If a field is missing, use null. If the date or time appears in Hebrew, Israeli, or non-standard formats, convert it to ISO format (YYYY-MM-DD for date, HH:MM for time). If multiple dates/times are present, select the one most likely to be the event start, and prefer future dates over past ones. If the event start date/time is explicitly mentioned, use that. Do not shift or adjust the date for timezone unless it is explicitly specified in the HTML. Use the exact numbers as shown in the date/time string.\n\nHTML:\n${htmlSnippet}`;
      // Call Gemini API
      const geminiResponse = await callGemini({
        contents: [
          { role: "user", parts: [{ text: prompt }] }
        ]
      });
      if (!geminiResponse.ok) {
        const errText = await geminiResponse.text();
        return new Response(
          JSON.stringify({ error: `Gemini API error: ${geminiResponse.status} - ${errText}` }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      const geminiResult = await geminiResponse.json();
      if (geminiResult.candidates && geminiResult.candidates.length > 0 && geminiResult.candidates[0].content && geminiResult.candidates[0].content.parts && geminiResult.candidates[0].content.parts.length > 0) {
        geminiOutputText = geminiResult.candidates[0].content.parts[0].text;
      } else {
        geminiOutputText = JSON.stringify(geminiResult);
      }
      // Try to extract JSON from the output
      try {
        const jsonMatch = geminiOutputText.match(/\{[\s\S]*?\}/);
        if (jsonMatch) {
          const geminiExtracted = JSON.parse(jsonMatch[0]);
          extractedResult.title = geminiExtracted.title || extractedResult.title;
          extractedResult.location = geminiExtracted.location || extractedResult.location;
          extractedResult.date = geminiExtracted.date || extractedResult.date;
          extractedResult.time = geminiExtracted.time || extractedResult.time;
        }
      } catch (e) {
        // fallback: leave as is
      }
    } else {
      // If regex found date/time, still call Gemini for title/location
      const prompt = `Extract the event title and location from the following HTML. The page may be in Hebrew or English. Return a JSON object with keys: title, location.\n\nHTML:\n${htmlSnippet}`;
      const geminiResponse = await callGemini({
        contents: [
          { role: "user", parts: [{ text: prompt }] }
        ]
      });
      if (!geminiResponse.ok) {
        const errText = await geminiResponse.text();
        return new Response(
          JSON.stringify({ error: `Gemini API error: ${geminiResponse.status} - ${errText}` }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      const geminiResult = await geminiResponse.json();
      if (geminiResult.candidates && geminiResult.candidates.length > 0 && geminiResult.candidates[0].content && geminiResult.candidates[0].content.parts && geminiResult.candidates[0].content.parts.length > 0) {
        geminiOutputText = geminiResult.candidates[0].content.parts[0].text;
      } else {
        geminiOutputText = JSON.stringify(geminiResult);
      }
      try {
        const jsonMatch = geminiOutputText.match(/\{[\s\S]*?\}/);
        if (jsonMatch) {
          const geminiExtracted = JSON.parse(jsonMatch[0]);
          extractedResult.title = geminiExtracted.title || extractedResult.title;
          extractedResult.location = geminiExtracted.location || extractedResult.location;
        }
      } catch (e) {
        // fallback: leave as is
      }
    }

    // Call Gemini API
    const geminiResponse = await callGemini({
      contents: [
        { role: "user", parts: [{ text: prompt }] }
      ]
    });

    if (!geminiResponse.ok) {
      const errText = await geminiResponse.text();
      return new Response(
        JSON.stringify({ error: `Gemini API error: ${geminiResponse.status} - ${errText}` }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const geminiResult = await geminiResponse.json();
    let outputText = "";
    if (geminiResult.candidates && geminiResult.candidates.length > 0 && geminiResult.candidates[0].content && geminiResult.candidates[0].content.parts && geminiResult.candidates[0].content.parts.length > 0) {
      outputText = geminiResult.candidates[0].content.parts[0].text;
    } else {
      outputText = JSON.stringify(geminiResult);
    }

    // Try to extract JSON from the output
    let extracted = { title: null, location: null, date: null, time: null };
    try {
      const jsonMatch = outputText.match(/\{[\s\S]*?\}/);
      if (jsonMatch) {
        extracted = JSON.parse(jsonMatch[0]);
      }
    } catch (e) {
      // fallback: leave as nulls
    }

    const finalOutput = {
      title: extractedResult.title || null,
      location: extractedResult.location || null,
      date: extractedResult.date || null,
      time: extractedResult.time || null,
      raw: (typeof geminiOutputText === 'string' ? geminiOutputText.slice(0, 500) : ''), // For raw field
    };

    return new Response(
      JSON.stringify(finalOutput),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );

  } catch (error) {
    return new Response(
      JSON.stringify({ error: (error as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});