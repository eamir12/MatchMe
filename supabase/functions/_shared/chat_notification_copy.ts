// supabase/functions/_shared/chat_notification_copy.ts
//
// The one conversation content model that every platform reads. Computed once
// per chat event in push-message, then rendered by the FCM tray card, the APNs
// alert, the web notification, the WNS toast, and the card MatchMe draws itself
// on Android. Parity is enforced here rather than in four clients.
//
// Two rules the member set, encoded once here:
//
//  1. The unread total belongs in the TITLE ("3 messages from John S."), never
//     in the body. iOS has no per-conversation badge API and FCM offers no
//     grouping field, so the title is the only slot every platform has.
//  2. A collapsed card shows NO message text when the conversation holds more
//     than one unread message. A single line cannot say whether it is the
//     first, last or some middle message of the batch, so the card states what
//     opening the app will do instead: "3 unread - open to read". There is
//     deliberately no "New message" string anywhere in this file.
//
// Keep the plural fallback order in sync with getCountedTranslation in
// supabase/functions/cron-jobs/index.ts: the form of the user's language, then
// that language's base key, then English. A push must never ship the key.
//
// These sentences are mirrored in the app's own translation table as
// `pushMessagesTitle` / `pushOpenToReadBody` (English defaults in
// lib/providers/locale_provider.dart, the other languages in
// supabase/migrations/20262154000001_add_chat_notification_copy_translations.sql).
// Android needs them there because a card drawn without a payload cannot ask
// this module. Change a value here and change it there.

import { bidiIsolate, enforceTitleBody, truncateUtf8Bytes } from './notification_limits.ts';
import { pluralKeyFor } from './plural.ts';

/** Unread lines a card may reveal when its surface can expand. */
export const CHAT_PREVIEW_MAX_LINES = 5;

/**
 * Per-line budget. Five lines plus JSON overhead have to fit inside the FCM
 * data limit (NOTIF_LIMITS.fcmDataMaxBytes), so a line is capped far below the
 * 1500-byte budget a single-message card gets.
 */
export const CHAT_PREVIEW_LINE_MAX_BYTES = 240;

const _chatStrings: Record<string, Record<string, string>> = {
  en: {
    messagesTitle: '{count} messages from {name}',
    messagesTitle_one: '{count} message from {name}',
    openToReadBody: '{count} unread - open to read',
    openToReadBody_one: '1 unread - open to read',
  },
  he: {
    messagesTitle: '{count} הודעות מאת {name}',
    messagesTitle_one: 'הודעה מאת {name}',
    messagesTitle_two: 'שתי הודעות מאת {name}',
    openToReadBody: '{count} הודעות לא נקראו - פתח כדי לקרוא',
    openToReadBody_one: 'הודעה אחת לא נקראה - פתח כדי לקרוא',
    openToReadBody_two: 'שתי הודעות לא נקראו - פתח כדי לקרוא',
  },
  es: {
    messagesTitle: '{count} mensajes de {name}',
    messagesTitle_one: '{count} mensaje de {name}',
    openToReadBody: '{count} mensajes sin leer: abre para leer',
    openToReadBody_one: '1 mensaje sin leer: abre para leer',
  },
};

function chatTemplate(locale: string, key: string, count: number): string {
  const table = _chatStrings[locale] ?? _chatStrings['en'];
  const english = _chatStrings['en'];
  const variantKey = pluralKeyFor(locale, key, count);
  return table[variantKey]
    ?? table[key]
    ?? (variantKey !== key ? english[variantKey] : undefined)
    ?? english[key]
    ?? key;
}

function fill(template: string, subs: Record<string, string | number>): string {
  let out = template;
  for (const [token, value] of Object.entries(subs)) {
    out = out.split(`{${token}}`).join(String(value));
  }
  return out;
}

export type ChatPushContent = {
  /** "<N> message(s) from <masked sender>" - constant metadata, never content. */
  title: string;
  /** The single collapsed line for surfaces that cannot expand. */
  body: string;
  /** Oldest-first displayable lines, for surfaces that can expand. Empty when previews are off. */
  lines: string[];
  unreadCount: number;
  previewsEnabled: boolean;
};

/**
 * The copy and lines for one chat notification.
 *
 * [lines] is every displayable unread line of the conversation, oldest first,
 * as the server holds it (translated where the recipient gets a translation).
 * When previews are off the caller passes the lines it has and this function
 * drops them: the returned model carries no message content at all, so nothing
 * sensitive reaches a payload.
 */
export function buildChatPushContent(args: {
  locale: string;
  senderName: string;
  unreadCount: number;
  previewsEnabled: boolean;
  lines: string[];
}): ChatPushContent {
  const count = Math.max(1, Math.trunc(args.unreadCount));
  const title = fill(chatTemplate(args.locale, 'messagesTitle', count), {
    count,
    name: bidiIsolate(args.senderName),
  });
  const lines = (args.previewsEnabled ? args.lines : [])
    .map((line) => truncateUtf8Bytes(String(line).trim(), CHAT_PREVIEW_LINE_MAX_BYTES).text)
    .filter((line) => line.length > 0)
    .slice(-CHAT_PREVIEW_MAX_LINES);
  // Exactly one unread is unambiguous: that line can only be that message.
  const single = count === 1 && lines.length === 1 ? lines[0] : '';
  const body = single || fill(chatTemplate(args.locale, 'openToReadBody', count), { count });
  const enforced = enforceTitleBody(title, body);
  return {
    title: enforced.title,
    body: enforced.body,
    lines,
    unreadCount: count,
    previewsEnabled: args.previewsEnabled,
  };
}
