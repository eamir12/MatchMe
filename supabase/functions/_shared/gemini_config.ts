// Central Gemini model config — single source of truth for all Edge Functions.
// Consumers: validate-primary-photo, validate-secondary-photo, process-event-file,
//   compare-verification-photos (vision), moderate-bio, get-event-metadata (text).
//
// SELF-HEALING: call sites must use `await resolveVisionModels(apiKey)` /
// `await resolveTextModels(apiKey)` instead of the static lists below. The
// resolvers ask Google's ListModels API for the live set of stable Flash models,
// sort newest-first, then APPEND the static chain — previous versions are always
// retained as fallbacks, so discovery can never leave us with zero models and a
// retired/yanked model can never break us. Any discovery failure silently falls
// back to the static chain (today's behaviour). Results are cached 6h per
// isolate; in-flight discovery is de-duplicated.
//
// Manual override (no code change) via Supabase secrets:
//   supabase secrets set GEMINI_PRIMARY_MODEL=gemini-3.8-flash \
//     GEMINI_SECONDARY_MODEL=gemini-3.7-flash \
//     GEMINI_FALLBACK_MODEL=gemini-3.6-flash \
//     GEMINI_TEXT_PRIMARY_MODEL=gemini-3.5-flash-lite \
//     GEMINI_TEXT_SECONDARY_MODEL=gemini-3.1-flash-lite
// Then redeploy the functions that import this file (or wait for next deploy).
//
// Model lifecycle (verified 2026-09-30, https://cloud.google.com/.../model-versions):
//   gemini-3.8-flash (GA 2026-09-02, no retirement announced) — newest stable
//   gemini-3.7-flash (GA 2026-08-13, no retirement announced)
//   gemini-3.6-flash (GA 2026-07-21, no retirement announced)
//   gemini-3.5-flash / gemini-3.5-flash-lite (2026-05/07, good until 2027)
//   gemini-3.1-flash-lite (2026-05-07, good until 2027-05-07)
//   gemini-2.5-flash / gemini-2.5-flash-lite — RETIRE 2026-10-20, do NOT use.
// Run tools/check_gemini_models.ps1 for a manual audit via the ListModels API.
const envPrimary = Deno.env.get("GEMINI_PRIMARY_MODEL");
const envSecondary = Deno.env.get("GEMINI_SECONDARY_MODEL");
const envFallback = Deno.env.get("GEMINI_FALLBACK_MODEL");
const envTextPrimary = Deno.env.get("GEMINI_TEXT_PRIMARY_MODEL");
const envTextSecondary = Deno.env.get("GEMINI_TEXT_SECONDARY_MODEL");

export const GEMINI_PRIMARY_MODEL = envPrimary || "gemini-3.8-flash";
export const GEMINI_SECONDARY_MODEL = envSecondary || "gemini-3.7-flash";
export const GEMINI_FALLBACK_MODEL = envFallback || "gemini-3.6-flash";
export const GEMINI_TEXT_PRIMARY_MODEL = envTextPrimary || "gemini-3.5-flash-lite";
export const GEMINI_TEXT_SECONDARY_MODEL = envTextSecondary || "gemini-3.1-flash-lite";

// Vision-capable models (multimodal): primary → secondary → tertiary fallback
export const VISION_MODELS = [GEMINI_PRIMARY_MODEL, GEMINI_SECONDARY_MODEL, GEMINI_FALLBACK_MODEL];
// Text-only models (higher RPM, cheaper): text-primary → text-secondary → tertiary fallback
export const TEXT_MODELS = [GEMINI_TEXT_PRIMARY_MODEL, GEMINI_TEXT_SECONDARY_MODEL, GEMINI_FALLBACK_MODEL];

export function buildGeminiUrl(model: string, apiKey: string): string {
  return `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
}

// ---------------------------------------------------------------------------
// Self-healing dynamic resolution (see header). Static lists above are the
// guaranteed fallback tail; discovery only ever PREPENDS newer live models.
// ---------------------------------------------------------------------------

const DISCOVERY_TTL_MS = 6 * 60 * 60 * 1000;
const DISCOVERY_TIMEOUT_MS = 10_000;
// Never auto-adopt these variants: previews, experiments, image/TTS/live-audio,
// cyber-restricted, embeddings, video-gen.
const EXCLUDED_MODEL_PATTERN =
  /preview|experimental|image|tts|live|audio|cyber|embedding|omni|veo/i;

interface _CacheEntry {
  models: string[];
  at: number;
}

let _visionCache: _CacheEntry | null = null;
let _textCache: _CacheEntry | null = null;
let _visionInflight: Promise<string[]> | null = null;
let _textInflight: Promise<string[]> | null = null;

function _parseFlashVersion(id: string): { major: number; minor: number; lite: boolean } | null {
  const m = id.match(/^gemini-(\d+)(?:\.(\d+))?-flash(-lite)?$/);
  if (!m) return null;
  return {
    major: Number(m[1]),
    minor: m[2] === undefined ? 0 : Number(m[2]),
    lite: !!m[3],
  };
}

function _isStableFlashCandidate(name: unknown, methods: unknown): boolean {
  if (typeof name !== "string") return false;
  const id = name.replace(/^models\//, "");
  if (!id.startsWith("gemini-") || !id.includes("flash")) return false;
  if (EXCLUDED_MODEL_PATTERN.test(id)) return false;
  if (!Array.isArray(methods) || !(methods as unknown[]).includes("generateContent")) return false;
  return _parseFlashVersion(id) !== null;
}

// Vision: newest first, full flash before lite at the same version (most capable).
function _sortVision(a: string, b: string): number {
  const pa = _parseFlashVersion(a)!;
  const pb = _parseFlashVersion(b)!;
  if (pa.major !== pb.major) return pb.major - pa.major;
  if (pa.minor !== pb.minor) return pb.minor - pa.minor;
  return Number(pa.lite) - Number(pb.lite);
}

// Text: newest first, lite before full (cheaper, higher RPM).
function _sortText(a: string, b: string): number {
  const pa = _parseFlashVersion(a)!;
  const pb = _parseFlashVersion(b)!;
  if (pa.major !== pb.major) return pb.major - pa.major;
  if (pa.minor !== pb.minor) return pb.minor - pa.minor;
  return Number(pb.lite) - Number(pa.lite);
}

async function _fetchLiveFlashModels(apiKey: string): Promise<string[]> {
  if (!apiKey) return [];
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DISCOVERY_TIMEOUT_MS);
  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models?key=${apiKey}&pageSize=100`,
      { signal: controller.signal },
    );
    if (!res.ok) {
      console.warn(`[gemini_config] ListModels HTTP ${res.status}, using static chain`);
      return [];
    }
    const data = await res.json();
    const models = Array.isArray(data?.models) ? data.models : [];
    return models
      .filter((m: { name?: unknown; supportedGenerationMethods?: unknown }) =>
        _isStableFlashCandidate(m?.name, m?.supportedGenerationMethods)
      )
      .map((m: { name: string }) => String(m.name).replace(/^models\//, ""));
  } catch (e) {
    console.warn(
      `[gemini_config] ListModels discovery failed (${e instanceof Error ? e.message : String(e)}), using static chain`,
    );
    return [];
  } finally {
    clearTimeout(timer);
  }
}

// Live models first in recency order, static chain merged in (deduped) and the
// whole chain re-sorted — previous versions are ALWAYS retained as fallbacks,
// in correct recency order. Anything unparseable is kept at the very end.
function _mergeWithStaticFallbacks(
  discovered: string[],
  staticChain: string[],
  sort: (a: string, b: string) => number,
): string[] {
  const seen = new Set<string>();
  const all: string[] = [];
  for (const m of [...discovered, ...staticChain]) {
    if (!seen.has(m)) {
      seen.add(m);
      all.push(m);
    }
  }
  const parseable = all.filter((m) => _parseFlashVersion(m) !== null);
  const other = all.filter((m) => _parseFlashVersion(m) === null);
  return [...parseable.sort(sort), ...other];
}

async function _resolve(apiKey: string, kind: "vision" | "text"): Promise<string[]> {
  const staticChain = kind === "vision" ? VISION_MODELS : TEXT_MODELS;
  const discovered = await _fetchLiveFlashModels(apiKey);
  if (discovered.length === 0) return [...staticChain];
  const sort = kind === "vision" ? _sortVision : _sortText;
  const models = _mergeWithStaticFallbacks(discovered, staticChain, sort);
  for (const s of staticChain) {
    if (!discovered.includes(s)) {
      console.warn(
        `[gemini_config] static ${kind} model ${s} not in live ListModels — may be retired; live models will be tried first`,
      );
    }
  }
  console.log(`[gemini_config] resolved ${kind} models: ${models.join(",")}`);
  return models;
}

function _cachedOrResolve(
  apiKey: string,
  kind: "vision" | "text",
): Promise<string[]> {
  const cache = kind === "vision" ? _visionCache : _textCache;
  if (cache && Date.now() - cache.at < DISCOVERY_TTL_MS) {
    return Promise.resolve(cache.models);
  }
  if (kind === "vision") {
    if (!_visionInflight) {
      _visionInflight = _resolve(apiKey, kind).then((models) => {
        _visionCache = { models, at: Date.now() };
        return models;
      }).finally(() => {
        _visionInflight = null;
      });
    }
    return _visionInflight;
  }
  if (!_textInflight) {
    _textInflight = _resolve(apiKey, kind).then((models) => {
      _textCache = { models, at: Date.now() };
      return models;
    }).finally(() => {
      _textInflight = null;
    });
  }
  return _textInflight;
}

/** Live vision chain: newest stable Flash first, static chain retained as tail. */
export function resolveVisionModels(apiKey: string): Promise<string[]> {
  return _cachedOrResolve(apiKey, "vision");
}

/** Live text chain: newest stable Flash-Lite first (cheap), static chain retained as tail. */
export function resolveTextModels(apiKey: string): Promise<string[]> {
  return _cachedOrResolve(apiKey, "text");
}
