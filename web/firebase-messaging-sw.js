importScripts('https://www.gstatic.com/firebasejs/10.12.4/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.4/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyBgAlJsTeTTCZjdbCdZ9vPXjl-3mqJhEEw',
  authDomain: 'matchme-17775.firebaseapp.com',
  projectId: 'matchme-17775',
  storageBucket: 'matchme-17775.firebasestorage.app',
  messagingSenderId: '988596890235',
  appId: '1:988596890235:web:2d1abd734198ad34e5d0de',
});

const messaging = firebase.messaging();

// v6: + the server's card wins - a locally joined history no longer replaces
// the body of a chat card that collapsed because several messages are unread.
// v5: tags aligned with the server contract (admin_<id>, expiry _<threshold>)
// so a card delivered by FCM never doubles a locally-posted one.
// v4: + silent edit/delete retraction closes the stale grouped card.
// skipWaiting + claim so rebooted/offline browsers pick up the fix without
// waiting for the old worker to release its clients.
const SW_VERSION = 'v6-server-copy-card';
try {
  self.addEventListener('install', (event) => {
    try {
      self.skipWaiting();
    } catch (_) {}
  });
  self.addEventListener('activate', (event) => {
    event.waitUntil((async () => {
      try {
        await self.clients.claim();
      } catch (_) {}
    })());
  });
} catch (_) {}

const _chatMessageHistory = new Map(); // matchId -> [{ id: string, text: string }]
let _currentUserId = '';

function _pushMessageHistory(matchId, messageId, text) {
  const key = (matchId || '').toString().trim() || 'unknown_chat';
  const id = (messageId || '').toString().trim();
  const msgText = (text || '').toString();

  const list = _chatMessageHistory.get(key) || [];

  if (id) {
    const existingIndex = list.findIndex((m) => m && m.id === id);
    if (existingIndex >= 0) {
      list[existingIndex] = { id, text: msgText };
    } else {
      list.push({ id, text: msgText });
    }
  } else if (msgText) {
    const last = list.length > 0 ? list[list.length - 1] : null;
    if (!last || last.text !== msgText) {
      list.push({ id: '', text: msgText });
    }
  }

  while (list.length > 5) list.shift();

  _chatMessageHistory.set(key, list);
  return list;
}

self.addEventListener('message', (event) => {
  let data = (event && event.data) ? event.data : {};
  if (typeof data === 'string') {
    try {
      data = JSON.parse(data);
    } catch (_) {
      data = {};
    }
  }
  const type = (data && (data.type || data.kind)) ? String(data.type || data.kind).trim() : '';
  if (type === 'SET_USER_ID') {
    _currentUserId = String(data.userId || data.user_id || '').trim();
    return;
  }
  if (type === 'CLEAR_USER_ID') {
    _currentUserId = '';
    return;
  }
});

messaging.onBackgroundMessage(async (payload) => {
  const data = (payload && payload.data) ? payload.data : {};
  const title = (payload && payload.notification && payload.notification.title)
    ? payload.notification.title
    : (data.notification_title || 'MatchMe');
  const body = (payload && payload.notification && payload.notification.body)
    ? payload.notification.body
    : (data.notification_body || '');
  const dataType = (data.type || data.kind || data.notification_type || data.notificationType || '').toString().trim();
  const isAdminBroadcast = dataType === 'admin_broadcast';

  try {
    const allClients = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    // Only skip if there is a FOCUSED client (app is active and handling it)
    const hasFocusedClient = allClients && allClients.some(client => client.focused);
    if (hasFocusedClient && !isAdminBroadcast) {
      return;
    }
  } catch (_) {}

  const matchId = (data.matchId || data.match_id || '').toString().trim();
  const messageId = (data.messageId || data.message_id || '').toString().trim();
  const senderId = (data.senderId || data.sender_id || '').toString().trim();
  const recipientId = (data.recipientId || data.recipient_id || '').toString().trim();
  const broadcastId = (data.broadcast_id || data.broadcastId || '').toString().trim();
  const rawKind = (data.kind || data.type || data.notification_type || '').toString().trim().toLowerCase();
  const isExpiry = rawKind === 'match_expiry' || rawKind === 'pinned_expiry';
  const isMatch = rawKind === 'match' || rawKind === 'new_match';
  const isMeetup = rawKind === 'meetup_signal' || rawKind === 'meetup_beacon' || rawKind === 'meetup_spot';
  // A wave or beacon replaces the sender's live row server-side, so its card
  // must replace the previous card too: keyed on who sent it, never on the row
  // id, which changes with every resend. Mirrors the cron-jobs collapse tag.
  const isLiveSignal = rawKind === 'meetup_signal' || rawKind === 'meetup_beacon';
  const isRetraction = rawKind === 'message_edited' || rawKind === 'message_deleted';
  // Retraction tick: close the stale grouped card instead of posting.
  // The next real message re-posts with correct text via its own tag.
  if (isRetraction) {
    try {
      const matchTag = (data.matchId || data.match_id || '').toString().trim();
      const tags = matchTag ? [`match_${matchTag}`] : [];
      for (const t of tags) {
        try {
          const existing = await self.registration.getNotifications({ tag: t });
          for (const n of (existing || [])) {
            try { n.close(); } catch (_) {}
          }
        } catch (_) {}
      }
      // Drop the retracted text from this worker's history so a rebuild
      // never resurrects it.
      if (matchTag && _chatMessageHistory.has(matchTag)) {
        _chatMessageHistory.delete(matchTag);
      }
    } catch (_) {}
    return;
  }
  // Distinct tags so chat history, match banners, and expiry warnings never
  // clobber each other when the browser is minimized/closed/offline.
  // Chat keeps `match_<id>` for 5-message history merging. All tags mirror
  // the server contract (push-message / cron-jobs collapseTag) so a server
  // webpush card and this worker's card replace each other, never stack.
  const expiryThreshold = (data.threshold_seconds ?? data.thresholdSeconds ?? '')
    .toString()
    .trim();
  const tag = isAdminBroadcast
    ? (broadcastId ? `admin_${broadcastId}` : 'admin_broadcast')
    : isExpiry
      ? `${rawKind}_${matchId || broadcastId || 'warn'}${expiryThreshold ? `_${expiryThreshold}` : ''}`
      : isMatch
        ? (matchId ? `new_match_${matchId}` : 'new_match')
        : isMeetup
          ? (isLiveSignal && matchId && senderId
              ? `${rawKind}_${matchId}_${senderId}`
              : `${rawKind}_${(data.meetup_signal_id || data.meetup_spot_id || matchId || 'event').toString().trim()}`)
          : (matchId ? `match_${matchId}` : (data.tag || data.collapseKey || data.collapse_key || '').toString().trim());

  if (_currentUserId) {
    if (recipientId && recipientId !== _currentUserId) {
      return;
    }
    if (senderId && senderId === _currentUserId) {
      return;
    }
  }

  const alreadyAggregated = data.aggregated_messages === 'true';
  // The worker still keeps a per-chat history, because its tag replaces its
  // own card and it needs to know whether this push opens a burst (ring) or
  // continues one (stay quiet). It no longer supplies the body: the card the
  // server built puts the unread total in the title and quotes nothing when
  // the conversation holds more than one unread message, and joining the
  // history here would show exactly the text that rule hides.
  // Meet-up tool cards are standalone events, not chat lines: keeping them out
  // of the per-chat history prevents them from merging into (or silencing)
  // conversation cards for the same match.
  const history = (isAdminBroadcast || alreadyAggregated || isMeetup)
    ? null
    : _pushMessageHistory(matchId, messageId, body);
  const mergedBody = history ? history.map((m) => (m && m.text) ? m.text : '').filter(Boolean).join('\n') : '';

  self.registration.showNotification(title, {
    body: body || mergedBody,
    icon: '/icons/Icon-192.png',
    badge: '/icons/Icon-192.png',
    data,
    tag: tag || undefined,
    renotify: false,
    silent: data.should_alert === 'false' || (history ? history.length > 1 : false),
  });
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const data = (event.notification && event.notification.data) ? event.notification.data : {};
  const route = (data.route || data.deep_link || data.deepLink || '').toString().trim();
  const matchId = (data.matchId || data.match_id || '').toString().trim();
  const actionUrl = (data.action_url || data.actionUrl || '').toString().trim();
  const targetUrl = actionUrl || route || (matchId ? `/chat/${matchId}` : '/');
  const isExternal = /^https?:\/\//i.test(targetUrl);

  event.waitUntil((async () => {
    const allClients = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (!isExternal) {
      for (const client of allClients) {
        if ('focus' in client) {
          await client.focus();
          try {
            client.postMessage({ type: 'NAVIGATE', url: targetUrl });
          } catch (_) {}
          return;
        }
      }
    }
    if (clients.openWindow) await clients.openWindow(targetUrl);
  })());
});
