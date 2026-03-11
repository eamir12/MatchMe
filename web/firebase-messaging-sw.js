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
  const title = (payload && payload.notification && payload.notification.title) ? payload.notification.title : 'MatchMe';
  const body = (payload && payload.notification && payload.notification.body) ? payload.notification.body : '';
  const data = (payload && payload.data) ? payload.data : {};
  const dataType = (data.type || data.notification_type || data.notificationType || '').toString().trim();
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
  const tag = isAdminBroadcast
    ? (broadcastId ? `admin_broadcast_${broadcastId}` : 'admin_broadcast')
    : (matchId ? `match_${matchId}` : (data.tag || data.collapseKey || data.collapse_key || '').toString().trim());

  if (_currentUserId) {
    if (recipientId && recipientId !== _currentUserId) {
      return;
    }
    if (senderId && senderId === _currentUserId) {
      return;
    }
  }

  const history = isAdminBroadcast ? null : _pushMessageHistory(matchId, messageId, body);
  const mergedBody = history ? history.map((m) => (m && m.text) ? m.text : '').filter(Boolean).join('\n') : '';

  self.registration.showNotification(title, {
    body: mergedBody || body,
    icon: '/icons/Icon-192.png',
    badge: '/icons/Icon-192.png',
    data,
    tag: tag || undefined,
    renotify: false,
    silent: history ? history.length > 1 : false,
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
