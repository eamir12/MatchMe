// supabase/functions/_shared/chat_notification_copy_test.ts
//
// Pins the two rules the conversation content model exists to enforce: the
// unread total lives in the title, and a collapsed card never quotes a message
// it cannot place in the batch.
import {
  buildChatPushContent,
  CHAT_PREVIEW_LINE_MAX_BYTES,
  CHAT_PREVIEW_MAX_LINES,
} from './chat_notification_copy.ts';
import { stripBidiControls, utf8Bytes } from './notification_limits.ts';

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(msg);
}

// Names are wrapped in bidi isolates so an RTL name cannot scramble an LTR
// sentence (and vice versa). Compare the text a member actually reads.
function visible(value: string): string {
  return stripBidiControls(value);
}

Deno.test('one unread is unambiguous, so its line is the body', () => {
  const c = buildChatPushContent({
    locale: 'en',
    senderName: 'John S.',
    unreadCount: 1,
    previewsEnabled: true,
    lines: ['Coffee tomorrow?'],
  });
  assert(visible(c.title) === '1 message from John S.', `title was ${c.title}`);
  assert(c.body === 'Coffee tomorrow?', `body was ${c.body}`);
});

Deno.test('several unread show no text and state the count', () => {
  const c = buildChatPushContent({
    locale: 'en',
    senderName: 'John S.',
    unreadCount: 3,
    previewsEnabled: true,
    lines: ['Coffee tomorrow?', 'I found that place', '9am works'],
  });
  assert(visible(c.title) === '3 messages from John S.', `title was ${c.title}`);
  assert(c.body === '3 unread - open to read', `body was ${c.body}`);
  // The lines still travel, oldest first, for a surface that can expand.
  assert(c.lines.join('|') === 'Coffee tomorrow?|I found that place|9am works', 'lines reordered');
});

Deno.test('previews off ships no message content at all', () => {
  const c = buildChatPushContent({
    locale: 'en',
    senderName: 'Maya R.',
    unreadCount: 1,
    previewsEnabled: false,
    lines: ['a secret'],
  });
  assert(c.lines.length === 0, 'lines must be dropped');
  assert(c.body === '1 unread - open to read', `body was ${c.body}`);
  assert(!c.title.includes('secret') && !c.body.includes('secret'), 'content leaked');
});

Deno.test('no canned preview promise survives in the copy', () => {
  for (const count of [1, 2, 3, 9]) {
    for (const previews of [true, false]) {
      const c = buildChatPushContent({
        locale: 'en',
        senderName: 'John S.',
        unreadCount: count,
        previewsEnabled: previews,
        lines: ['x'],
      });
      assert(!c.body.includes('New message'), `canned body for ${count}/${previews}`);
      assert(!c.body.includes('Turn previews on'), `canned instruction for ${count}`);
    }
  }
});

Deno.test('Hebrew uses the dual for two', () => {
  const two = buildChatPushContent({
    locale: 'he',
    senderName: 'יוסי כ.',
    unreadCount: 2,
    previewsEnabled: true,
    lines: [],
  });
  assert(visible(two.title) === 'שתי הודעות מאת יוסי כ.', `title was ${two.title}`);
  assert(two.body === 'שתי הודעות לא נקראו - פתח כדי לקרוא', `body was ${two.body}`);
  const one = buildChatPushContent({
    locale: 'he',
    senderName: 'יוסי כ.',
    unreadCount: 1,
    previewsEnabled: false,
    lines: [],
  });
  assert(one.body === 'הודעה אחת לא נקראה - פתח כדי לקרוא', `body was ${one.body}`);
});

Deno.test('Spanish carries the count in the noun form', () => {
  const one = buildChatPushContent({
    locale: 'es',
    senderName: 'Juan S.',
    unreadCount: 1,
    previewsEnabled: false,
    lines: [],
  });
  assert(visible(one.title) === '1 mensaje de Juan S.', `title was ${one.title}`);
  assert(one.body === '1 mensaje sin leer: abre para leer', `body was ${one.body}`);
});

Deno.test('an unknown locale falls back to English copy, never to a key', () => {
  const c = buildChatPushContent({
    locale: 'fr',
    senderName: 'John S.',
    unreadCount: 4,
    previewsEnabled: true,
    lines: [],
  });
  assert(visible(c.title) === '4 messages from John S.', `title was ${c.title}`);
  assert(!c.body.includes('messagesTitle') && !c.body.includes('openToReadBody'), 'key leaked');
});

Deno.test('lines are byte-capped and clamped to the preview window', () => {
  const long = 'א'.repeat(2000);
  const many = Array.from({ length: 9 }, (_, i) => `${i} ${long}`);
  const c = buildChatPushContent({
    locale: 'en',
    senderName: 'John S.',
    unreadCount: 9,
    previewsEnabled: true,
    lines: many,
  });
  assert(c.lines.length === CHAT_PREVIEW_MAX_LINES, `kept ${c.lines.length}`);
  for (const line of c.lines) {
    assert(utf8Bytes(line) <= CHAT_PREVIEW_LINE_MAX_BYTES, `line of ${utf8Bytes(line)} bytes`);
  }
  assert(c.lines[0].startsWith('4 '), 'must keep the newest window');
});

Deno.test('a zero or fractional count never renders "0 messages"', () => {
  const c = buildChatPushContent({
    locale: 'en',
    senderName: 'John S.',
    unreadCount: 0,
    previewsEnabled: true,
    lines: [],
  });
  assert(visible(c.title) === '1 message from John S.', `title was ${c.title}`);
  assert(c.unreadCount === 1, 'count must clamp to one');
});
