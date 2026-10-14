// supabase/functions/_shared/notification_limits.ts
// Single source of truth for notification size / payload limits.
// Mirrors lib/utils/notification_limits.dart and
// supabase migration 20260916000000_add_notification_limits.sql.
// All truncation is byte-based (UTF-8), not char-based, because
// FCM/APNs enforce 4096 bytes and Hebrew/Arabic/emoji are multi-byte.

export const NOTIF_LIMITS = {
  // Admin-authored content (hard block in Admin UI + DB CHECK).
  adminTitleMaxChars: 60,
  adminTitleMaxBytes: 200,
  adminBodyMaxChars: 180,
  adminBodyMaxBytes: 1000,
  actionTextMaxChars: 30,
  actionUrlMaxChars: 2000,
  // Queue / FCM transport (auto-truncate, never drop silently).
  queueTitleMaxBytes: 500,
  queueBodyMaxBytes: 1500,
  fcmDataMaxBytes: 2000,
  fcmTotalMaxBytes: 3500, // headroom below FCM 4096
  // Auto-generated names.
  senderNameMaxChars: 20,
  // Fan-out guards.
  broadcastMaxDeliveries: 20000,
  targetUserIdsMax: 500,
  // Frequency guard: configurable server-side via app_config
  // notifications.admin_broadcast_max_per_day (default 10). Keep in sync.
  adminMaxPerUserPerDay: 10,
} as const;

export function utf8Bytes(value: string): number {
  return new TextEncoder().encode(value ?? '').length;
}

// Truncate on UTF-8 byte boundary, preserving surrogate pairs.
// Appends ellipsis only if there is room; never exceeds maxBytes.
export function truncateUtf8Bytes(input: string, maxBytes: number): { text: string; truncated: boolean } {
  const s = String(input ?? '');
  if (utf8Bytes(s) <= maxBytes) return { text: s, truncated: false };
  const enc = new TextEncoder();
  const ellipsis = '…';
  const ellipsisBytes = enc.encode(ellipsis).length;
  const budget = Math.max(0, maxBytes - ellipsisBytes);
  let low = 0;
  let high = s.length;
  // Binary search on UTF-16 index, then fix lone surrogates.
  while (low < high) {
    const mid = Math.floor((low + high + 1) / 2);
    if (enc.encode(s.slice(0, mid)).length <= budget) low = mid;
    else high = mid - 1;
  }
  let cut = low;
  // Avoid splitting a surrogate pair.
  while (cut > 0 && cut < s.length) {
    const c = s.charCodeAt(cut - 1);
    const n = s.charCodeAt(cut);
    if (c >= 0xd800 && c <= 0xdbff && n >= 0xdc00 && n <= 0xdfff) {
      cut -= 1;
      break;
    }
    break;
  }
  return { text: `${s.slice(0, cut)}${ellipsis}`, truncated: true };
}

export function firstTokenName(raw: string, maxChars = NOTIF_LIMITS.senderNameMaxChars): string {
  const t = String(raw ?? '').trim().split(/\s+/)[0] ?? '';
  if (!t) return 'Someone';
  return t.length > maxChars ? t.slice(0, maxChars) : t;
}

// Unicode bidi isolation: FSI (U+2068) picks the isolate direction from the
// first strong character of the content; PDI (U+2069) restores the surrounding
// direction. Wrap user-supplied names/labels before interpolating them into a
// notification template so an RTL name (e.g. Hebrew) inside an LTR English or
// Spanish sentence — or an LTR name inside an RTL Hebrew sentence — does not
// scramble the surrounding word order (neutral chars like parens/quotes no
// longer get their directionality from the embedded run).
export function bidiIsolate(value: string): string {
  const s = String(value ?? '');
  if (!s) return s;
  return `\u2068${s}\u2069`;
}

export function enforceTitleBody(
  title: string,
  body: string,
): { title: string; body: string; truncated: boolean } {
  const t = truncateUtf8Bytes(String(title ?? '').trim(), NOTIF_LIMITS.queueTitleMaxBytes);
  const b = truncateUtf8Bytes(String(body ?? '').trim(), NOTIF_LIMITS.queueBodyMaxBytes);
  return { title: t.text, body: b.text, truncated: t.truncated || b.truncated };
}

export function coerceFcmData(data: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!data || typeof data !== 'object') return out;
  for (const [k, v] of Object.entries(data as Record<string, unknown>)) {
    if (!k) continue;
    out[String(k)] = typeof v === 'string' ? v : JSON.stringify(v ?? '');
  }
  return out;
}

export function fcmPayloadBytes(title: string, body: string, data: Record<string, string>): number {
  return utf8Bytes(JSON.stringify({ title, body, data }));
}

// Returns true when admin input violates hard limits (should block save).
export function adminInputViolations(
  title: string,
  body: string,
  actionUrl?: string | null,
  actionText?: string | null,
): string[] {
  const issues: string[] = [];
  const t = String(title ?? '').trim();
  const b = String(body ?? '').trim();
  if (!t) issues.push('Title is required');
  if (!b) issues.push('Message is required');
  if (t.length > NOTIF_LIMITS.adminTitleMaxChars) {
    issues.push(`Title max ${NOTIF_LIMITS.adminTitleMaxChars} chars`);
  }
  if (utf8Bytes(t) > NOTIF_LIMITS.adminTitleMaxBytes) {
    issues.push(`Title max ${NOTIF_LIMITS.adminTitleMaxBytes} bytes`);
  }
  if (b.length > NOTIF_LIMITS.adminBodyMaxChars) {
    issues.push(`Message max ${NOTIF_LIMITS.adminBodyMaxChars} chars`);
  }
  if (utf8Bytes(b) > NOTIF_LIMITS.adminBodyMaxBytes) {
    issues.push(`Message max ${NOTIF_LIMITS.adminBodyMaxBytes} bytes`);
  }
  if (actionText != null && String(actionText).length > NOTIF_LIMITS.actionTextMaxChars) {
    issues.push(`Action text max ${NOTIF_LIMITS.actionTextMaxChars} chars`);
  }
  if (actionUrl != null && String(actionUrl).trim()) {
    const u = String(actionUrl).trim();
    if (u.length > NOTIF_LIMITS.actionUrlMaxChars) issues.push('Action URL too long');
    if (!/^https?:\/\/.+\..+/.test(u)) issues.push('Action URL must be http(s)');
  }
  const payload = fcmPayloadBytes(t, b, {});
  if (payload > NOTIF_LIMITS.fcmTotalMaxBytes) {
    issues.push(`Payload ~${payload} bytes exceeds ${NOTIF_LIMITS.fcmTotalMaxBytes} budget`);
  }
  return issues;
}
