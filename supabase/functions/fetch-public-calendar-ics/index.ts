import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const blockedHosts = new Set([
  'localhost',
  '127.0.0.1',
  '::1',
  '0.0.0.0',
]);

function normalizeUrl(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.toLowerCase().startsWith('webcal://')) {
    return `https://${trimmed.substring('webcal://'.length)}`;
  }
  return trimmed;
}

function isPrivateHost(hostname: string): boolean {
  const host = hostname.trim().toLowerCase();
  if (!host) return true;
  if (blockedHosts.has(host)) return true;
  if (host.endsWith('.local')) return true;
  if (host.endsWith('.internal')) return true;
  const ipv4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) {
    const a = Number(ipv4[1]);
    const b = Number(ipv4[2]);
    if (a === 10) return true;
    if (a === 127) return true;
    if (a === 0) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
  }
  return false;
}

function unfoldIcsLines(rawIcs: string): string[] {
  const base = rawIcs.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
  const unfolded: string[] = [];
  for (const line of base) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && unfolded.length > 0) {
      unfolded[unfolded.length - 1] += line.substring(1);
    } else {
      unfolded.push(line);
    }
  }
  return unfolded;
}

function parseDateValue(value: string): { iso: string | null; allDay: boolean } {
  const v = value.trim();
  if (!v) return { iso: null, allDay: false };
  if (/^\d{8}$/.test(v)) {
    const y = Number(v.substring(0, 4));
    const m = Number(v.substring(4, 6));
    const d = Number(v.substring(6, 8));
    const dt = new Date(Date.UTC(y, m - 1, d));
    return { iso: dt.toISOString(), allDay: true };
  }
  if (/^\d{8}T\d{6}Z$/.test(v)) {
    const y = Number(v.substring(0, 4));
    const m = Number(v.substring(4, 6));
    const d = Number(v.substring(6, 8));
    const hh = Number(v.substring(9, 11));
    const mm = Number(v.substring(11, 13));
    const ss = Number(v.substring(13, 15));
    const dt = new Date(Date.UTC(y, m - 1, d, hh, mm, ss));
    return { iso: dt.toISOString(), allDay: false };
  }
  if (/^\d{8}T\d{6}$/.test(v)) {
    const y = Number(v.substring(0, 4));
    const m = Number(v.substring(4, 6));
    const d = Number(v.substring(6, 8));
    const hh = Number(v.substring(9, 11));
    const mm = Number(v.substring(11, 13));
    const ss = Number(v.substring(13, 15));
    const dt = new Date(Date.UTC(y, m - 1, d, hh, mm, ss));
    return { iso: dt.toISOString(), allDay: false };
  }
  const parsed = new Date(v);
  if (Number.isNaN(parsed.getTime())) {
    return { iso: null, allDay: false };
  }
  return { iso: parsed.toISOString(), allDay: false };
}

function findFirstValue(lines: string[], key: string): string | null {
  const prefix = `${key}:`;
  const prefixWithParams = `${key};`;
  for (const line of lines) {
    if (line.startsWith(prefix)) return line.substring(prefix.length).trim();
    if (line.startsWith(prefixWithParams)) {
      const idx = line.indexOf(':');
      if (idx >= 0) return line.substring(idx + 1).trim();
    }
  }
  return null;
}

function parseIcs(ics: string): { calendarName: string; events: Array<Record<string, unknown>> } {
  const lines = unfoldIcsLines(ics);
  const calendarName = findFirstValue(lines, 'X-WR-CALNAME') ?? 'Apple Public Calendar';
  const events: Array<Record<string, unknown>> = [];
  let eventLines: string[] | null = null;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') {
      eventLines = [];
      continue;
    }
    if (line === 'END:VEVENT') {
      if (eventLines != null) {
        const uid = findFirstValue(eventLines, 'UID');
        const summary = findFirstValue(eventLines, 'SUMMARY') ?? 'Apple Calendar Event';
        const description = findFirstValue(eventLines, 'DESCRIPTION');
        const location = findFirstValue(eventLines, 'LOCATION');
        const url = findFirstValue(eventLines, 'URL');
        const organizer = findFirstValue(eventLines, 'ORGANIZER');
        const startRaw = findFirstValue(eventLines, 'DTSTART');
        const endRaw = findFirstValue(eventLines, 'DTEND');
        if (startRaw != null) {
          const startParsed = parseDateValue(startRaw);
          const endParsed = endRaw != null ? parseDateValue(endRaw) : { iso: null, allDay: startParsed.allDay };
          if (startParsed.iso != null) {
            const generatedId = uid?.trim().isNotEmpty == true
                ? uid!.trim()
                : `${summary}_${startParsed.iso}`;
            events.push({
              id: generatedId,
              title: summary,
              start: startParsed.iso,
              end: endParsed.iso,
              isAllDay: startParsed.allDay,
              description: description,
              location: location,
              url: url,
              organizer: organizer,
            });
          }
        }
      }
      eventLines = null;
      continue;
    }
    if (eventLines != null) {
      eventLines.push(line);
    }
  }
  return { calendarName, events };
}

function filterByRange(
  events: Array<Record<string, unknown>>,
  startIso?: string,
  endIso?: string,
): Array<Record<string, unknown>> {
  if (!startIso && !endIso) return events;
  const startMs = startIso ? Date.parse(startIso) : null;
  const endMs = endIso ? Date.parse(endIso) : null;
  return events.filter((e) => {
    const s = typeof e.start === 'string' ? Date.parse(e.start) : NaN;
    const ee = typeof e.end === 'string' ? Date.parse(e.end) : s;
    if (Number.isNaN(s)) return false;
    if (startMs != null && !Number.isNaN(startMs) && ee < startMs) return false;
    if (endMs != null && !Number.isNaN(endMs) && s > endMs) return false;
    return true;
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'method_not_allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
  try {
    const body = await req.json();
    const rawUrl = typeof body?.url === 'string' ? body.url : '';
    const normalized = normalizeUrl(rawUrl);
    if (!normalized) {
      return new Response(JSON.stringify({ error: 'calendarSyncApplePublicUrlRequired' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    const uri = new URL(normalized);
    if (uri.protocol !== 'http:' && uri.protocol !== 'https:') {
      return new Response(JSON.stringify({ error: 'calendarSyncApplePublicUrlInvalid' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    if (isPrivateHost(uri.hostname)) {
      return new Response(JSON.stringify({ error: 'calendarSyncApplePublicUrlInvalid' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    const timeout = Number(Deno.env.get('APPLE_ICS_TIMEOUT_MS') ?? '15000');
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeout);
    const fetchResponse = await fetch(uri.toString(), {
      method: 'GET',
      signal: ac.signal,
      headers: {
        'Accept': 'text/calendar,text/plain;q=0.9,*/*;q=0.8',
      },
    }).finally(() => clearTimeout(timer));
    if (!fetchResponse.ok) {
      return new Response(JSON.stringify({ error: 'calendarSyncApplePublicFetchFailed' }), {
        status: 502,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    const ics = await fetchResponse.text();
    if (!ics.includes('BEGIN:VCALENDAR')) {
      return new Response(JSON.stringify({ error: 'calendarSyncApplePublicFetchFailed' }), {
        status: 422,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    const parsed = parseIcs(ics);
    const filtered = filterByRange(
      parsed.events,
      typeof body?.startDate === 'string' ? body.startDate : undefined,
      typeof body?.endDate === 'string' ? body.endDate : undefined,
    );
    const limited = filtered.slice(0, 1000);
    return new Response(JSON.stringify({
      calendar: {
        id: uri.toString(),
        name: parsed.calendarName,
      },
      events: limited,
      source: uri.toString(),
      readOnly: true,
      count: limited.length,
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (_) {
    return new Response(JSON.stringify({ error: 'calendarSyncApplePublicFetchFailed' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
