// Exterior landmark suggestions for the in-person meet-up flow, served from
// Google Places API (New) "Nearby Search".
//
// This exists so the Google API key never ships in a client build: the key is
// a project secret and only ever leaves this process. The client sends the same
// position it would have sent to Overpass — already coarsened to four decimal
// places (~11 m) before it leaves the device — and never stores the result.
//
// The response is deliberately NOT a passthrough. Google's `includedTypes`
// matching is fuzzy and its `primaryType` data is occasionally wrong, so every
// place must clear a curated type table before it is returned; otherwise a
// cannabis delivery service fills the "pharmacy" slot and a hair-tools shop
// fills the "mall" slot. See TYPE_TO_CATEGORY.
//
// A non-2xx response is a signal to the client: it falls back to the keyless
// OpenStreetMap path (Overpass mirrors, then vector tiles). Keep it that way.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { consumeAiRateLimit } from "../_shared/ai_rate_limit.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const GOOGLE_PLACES_API_KEY = Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "";

const FUNCTION_NAME = "place-suggestions";
const PLACES_ENDPOINT = "https://places.googleapis.com/v1/places:searchNearby";

// Pro SKU fields only. Adding an Enterprise field (regularOpeningHours, rating,
// …) would re-price the whole request at the Enterprise rate.
const FIELD_MASK = [
  "places.id",
  "places.displayName",
  "places.location",
  "places.types",
  "places.primaryType",
  "places.businessStatus",
].join(",");

const SEARCH_RADIUS_METERS = 2600; // The app's outer radius; a superset of the nearer passes.
const MAX_RESULTS = 20; // Google's cap for searchNearby.

// Every type we are willing to suggest, mapped to the app's own category
// vocabulary (lib/services/landmark_suggestion_service.dart `_categoryFor`).
// Only a place whose `primaryType` appears here is ever returned, so Google
// cannot smuggle an unrelated business into a slot. Notable omissions:
//   - `drugstore`: measured to return cannabis delivery services. Ask `pharmacy`.
//   - `market`: returned marketing agencies, lumber yards and boutiques.
//   - `transit_station`: measured to match bus stops, whose `primaryType` is
//     `bus_stop`. Including it filled half of a 20-result response with bus
//     stops — which the app excludes — crowding out every other category.
//     `train_station` / `subway_station` / `light_rail_station` / `bus_station`
//     cover the station intent without the stops.
const TYPE_TO_CATEGORY: Record<string, string> = {
  park: "park",
  plaza: "square",
  historical_landmark: "landmark",
  tourist_attraction: "attraction",
  museum: "attraction",
  supermarket: "supermarket",
  grocery_store: "supermarket",
  shopping_mall: "mall",
  department_store: "mall",
  gas_station: "fuel",
  pharmacy: "pharmacy",
  library: "library",
  city_hall: "library",
  train_station: "transit",
  subway_station: "transit",
  bus_station: "transit",
  light_rail_station: "transit",
};

const INCLUDED_TYPES = Object.keys(TYPE_TO_CATEGORY);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const svc =
  SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { persistSession: false },
      })
    : null;

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// MatchMe ships exactly three languages: en, es, he. Pass the locale through so
// Google gives native names ("קרפור סיטי") instead of transliterations.
function normalizeLocale(input: unknown): string {
  const value = typeof input === "string" ? input.trim().toLowerCase() : "";
  if (value.startsWith("he")) return "he";
  if (value.startsWith("es")) return "es";
  return "en";
}

function toFiniteNumber(input: unknown): number | null {
  if (typeof input === "number" && Number.isFinite(input)) return input;
  if (typeof input === "string" && input.trim() !== "") {
    const parsed = Number(input);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function haversineMeters(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const earthRadius = 6371000;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * earthRadius * Math.asin(Math.min(1, Math.sqrt(a)));
}

// Google display names carry an operator suffix ("Cooper Park | City of
// Bozeman"). The part before the separator is the place itself.
function stripOperatorSuffix(name: string): string {
  const index = name.indexOf(" | ");
  return (index > 0 ? name.slice(0, index) : name).trim();
}

interface PlaceOut {
  label: string;
  category: string;
  latitude: number;
  longitude: number;
  distance_m: number;
  // Lets the client deep-link straight to this place's Google Maps card
  // (?query=…&query_place_id=…). Empty for the OSM fallback path.
  place_id: string;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  let userId: string | null = null;
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;
  let resultCount = 0;

  try {
    if (!GOOGLE_PLACES_API_KEY) {
      // 503, not 500: the client reads any non-2xx as "use the OSM path".
      httpStatus = 503;
      errorMessage = "GOOGLE_PLACES_API_KEY is not configured";
      return jsonResponse({ error: "places_unavailable" }, 503);
    }

    const body = await req.json().catch(() => ({}));
    const latitude = toFiniteNumber(body?.latitude);
    const longitude = toFiniteNumber(body?.longitude);
    const language = normalizeLocale(body?.language);

    if (
      latitude === null ||
      longitude === null ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180
    ) {
      httpStatus = 400;
      errorMessage = "invalid coordinates";
      return jsonResponse({ error: "invalid_coordinates" }, 400);
    }

    const authHeader = req.headers.get("authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) {
      httpStatus = 401;
      errorMessage = "unauthorized";
      return jsonResponse({ error: "unauthorized" }, 401);
    }
    userId = userData.user.id;

    // Billed lookup: gate it per user before spending anything.
    if (svc) {
      const rateLimit = await consumeAiRateLimit(svc, {
        task: "place_suggestions",
        userId,
        requestId,
      });
      if (!rateLimit.allowed) {
        httpStatus = 429;
        errorMessage = "rate limited";
        return jsonResponse(
          {
            error: "too_many_requests",
            retryAfterSeconds: rateLimit.retryAfterSeconds,
          },
          429,
        );
      }
    }

    let res: Response;
    try {
      res = await fetch(PLACES_ENDPOINT, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
          "X-Goog-FieldMask": FIELD_MASK,
        },
        body: JSON.stringify({
          includedTypes: INCLUDED_TYPES,
          maxResultCount: MAX_RESULTS,
          // The default POPULARITY ranking hides everything close to the pin.
          rankPreference: "DISTANCE",
          languageCode: language,
          locationRestriction: {
            circle: {
              center: { latitude, longitude },
              radius: SEARCH_RADIUS_METERS,
            },
          },
        }),
      });
    } catch (e) {
      httpStatus = 502;
      errorType = e instanceof Error ? e.name : "Error";
      errorMessage = e instanceof Error ? e.message : String(e);
      return jsonResponse({ error: "places_unreachable" }, 502);
    }

    if (!res.ok) {
      const detail = (await res.text().catch(() => "")).slice(0, 400);
      httpStatus = 502;
      errorType = "HttpError";
      errorMessage = `Places API ${res.status}: ${detail}`;
      console.error(`[${FUNCTION_NAME}] Places API failure ${res.status} ${detail}`);
      return jsonResponse({ error: "places_unreachable" }, 502);
    }

    const payload = await res.json().catch(() => ({}));
    const rawPlaces = Array.isArray(payload?.places) ? payload.places : [];

    const seen = new Set<string>();
    const places: PlaceOut[] = [];
    for (const raw of rawPlaces) {
      const primaryType =
        typeof raw?.primaryType === "string" ? raw.primaryType : "";
      const category = TYPE_TO_CATEGORY[primaryType];
      if (!category) continue;
      if (raw?.businessStatus === "CLOSED_PERMANENTLY") continue;

      // One response can repeat the same business; collapse by place id.
      const placeId = typeof raw?.id === "string" ? raw.id : "";
      if (placeId) {
        if (seen.has(placeId)) continue;
        seen.add(placeId);
      }

      const label = stripOperatorSuffix(
        typeof raw?.displayName?.text === "string" ? raw.displayName.text : "",
      );
      if (label.length < 2) continue;

      const plat = toFiniteNumber(raw?.location?.latitude);
      const plon = toFiniteNumber(raw?.location?.longitude);
      if (plat === null || plon === null) continue;

      places.push({
        label,
        category,
        latitude: plat,
        longitude: plon,
        distance_m: Math.round(haversineMeters(latitude, longitude, plat, plon)),
        place_id: placeId,
      });
    }

    places.sort((a, b) => a.distance_m - b.distance_m);
    resultCount = places.length;

    success = true;
    httpStatus = 200;
    return jsonResponse({ places });
  } catch (error) {
    errorType = error instanceof Error ? error.name : "Error";
    errorMessage = error instanceof Error ? error.message : String(error);
    httpStatus = 500;
    console.error(`[${FUNCTION_NAME}] Error:`, error);
    return jsonResponse({ error: "internal_error" }, 500);
  } finally {
    await logEdgeFunctionInvocation({
      requestId,
      functionName: FUNCTION_NAME,
      durationMs: Date.now() - startedAt,
      success,
      httpStatus,
      errorType,
      errorMessage,
      userId,
      aiUsed: false,
      meta: { provider: "google", results: resultCount },
    });
  }
});